#!/usr/bin/env bash
set -e

HOST="$1"
DIR="$2"

# Сохраним в локальной переменной путь к файлу docker-compose (или выйдем, если нет)
COMPOSE_FILE_DIR=$(ssh "$HOST" "
  if [[ -f \"$DIR/docker-compose.yml\" ]]; then
   echo $DIR/docker-compose.yml
  elif [[ -f \"$DIR/docker-compose.yaml\" ]]; then
   echo $DIR/docker-compose.yaml
  else
    exit 1
  fi
") || {
  echo "Ни одного docker-compose.yml(.yaml) в $DIR на $HOST не нашлось."
  exit 1
}

COMPOSE_FILE=$(ssh "$HOST" "cat \"$COMPOSE_FILE_DIR\"") || {
  echo "Не удалось считать файл $COMPOSE_FILE_DIR с $HOST" >&2
  exit 1
}
echo "Нашли docker-compose"
  # 2. Находим сервис, в котором монтится текущая папка через относительный путь "./"
  #    Теперь проверяем, что volume строка начинается с "./"
  #    (например, "./:/app" или "./какая-то-папка:/app")
SERVICE=$(
  echo "$COMPOSE_FILE" \
    | yq -r '
.services
| to_entries[]
| select(.value.volumes[]? | test("^\\./:"))
| .key
' - \
    | head -n1
)
  # Пояснение регулярки:
  #  - test("^\\./") ловит все volume-поля, которые начинаются с "./"
  #    (например, "./:/app" или "./src:/app/src")
  #  - Перед этим мы отбрасываем (через select(... | not)), если кто-то
  #    почему-то начал с "../" — чтобы не цеплять “родительские” папки,
  #    если тебе не нужно. Если в твоём yml такое не встречается, можно убрать первую строчку с not.

  if [[ -z "$SERVICE" ]]; then
    echo "Не нашёл сервис, который монтит папку через './'. Запускаю обычный nvim."
    exec /usr/bin/nvim 
  fi

  echo "Найден сервис: '$SERVICE'"

  # 3. Извлекаем контейнерное имя (container_name) из этого сервиса
  CTN=$(
  echo "$COMPOSE_FILE" \
    | yq -r ".services.\"$SERVICE\".container_name" -
  )

  if [[ "$CTN" == "null" || -z "$CTN" ]]; then
    echo "В docker-compose.yml нет поля container_name для сервиса '$SERVICE'."
    echo "Запускаю системный nvim."
    exec /usr/bin/nvim 
  fi

  echo "Будем юзать container_name: '$CTN'"

  # Настраиваем docker context
  docker context create remote-server --docker "host=ssh:"$HOST"" || true
  docker context use remote-server
  EXIT_CMD="docker context default"

  # Проверяем, поднят ли сервис на удалёнке
  if ssh "$HOST" "docker compose -f \"$COMPOSE_FILE_DIR\" ps \"$SERVICE\" 2>/dev/null | grep -q \"Up\""; then
     echo "Сервис '$SERVICE' уже поднят на $HOST."
  else
     echo "Сервис '$SERVICE' не запущен на $HOST — запускаю 'docker compose up -d'..."
     ssh "$HOST" "docker compose -f \"$COMPOSE_FILE_DIR\" up -d"

     # Ждём, пока контейнер не станет 'Up'
     until ssh "$HOST" "docker compose -f \"$COMPOSE_FILE_DIR\" ps \"$SERVICE\" 2>/dev/null | grep -q \"Up\""; do
       sleep 1
     done
       echo "Сервис '$SERVICE' поднят."
  fi

  # 5. Делаем ./devctn.sh с полученным container_name
  if [[ -x "$HOME/Scripts/devctn.sh" ]]; then
     ~/Scripts/devctn_remote.sh "$CTN"
  else
    echo "devctn.sh не найден или не имеет права на исполнение."
    echo "Запускаю системный nvim."
    $EXIT_CMD
    exec /usr/bin/nvim 
  fi

  IDG=$(ssh $HOST "id -g")
  IDU=$(ssh $HOST "id -u")
  WD=$(docker inspect --format='{{.Config.WorkingDir}}' "$CTN")

  # rm nvim.sock
  docker exec -d "$CTN" nvim --headless --listen "$WD"/nvim.sock
  docker exec "$CTN" chown "$IDU":"$IDG" ./nvim.sock
  docker exec "$CTN" chmod 660 ./nvim.sock

  docker context use default
#  ssh -f -N -L /tmp/local-nvim.sock:home/tiramisu-cake/app/nvim.sock "$HOST"
#  nvim --server /tmp/local-nvim.sock --remote-ui
