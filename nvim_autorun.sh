#!/usr/bin/env bash
set -e

# Сохраняем все аргументы (файлы, флаги)
ARGS=("$@")

# 1. Проверяем наличие docker-compose-файла
if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
  # Определяем, какой файл у нас
  if [[ -f "docker-compose.yml" ]]; then
    COMPOSE_FILE="docker-compose.yml"
  else
    COMPOSE_FILE="docker-compose.yaml"
  fi

  # 2. Находим сервис, в котором монтится текущая папка через относительный путь "./"
  #    Теперь проверяем, что volume строка начинается с "./"
  #    (например, "./:/app" или "./какая-то-папка:/app")
SERVICE=$(
  yq -r '.services
        | to_entries[]
        | select(.value.volumes[]? | test("^\\./:"))
        | .key' \
    "$COMPOSE_FILE" \
  | head -n1
)  # Пояснение регулярки:
  #  - test("^\\./") ловит все volume-поля, которые начинаются с "./"
  #    (например, "./:/app" или "./src:/app/src")
  #  - Перед этим мы отбрасываем (через select(... | not)), если кто-то
  #    почему-то начал с "../" — чтобы не цеплять “родительские” папки,
  #    если тебе не нужно. Если в твоём yml такое не встречается, можно убрать первую строчку с not.

  if [[ -z "$SERVICE" ]]; then
    echo "Не нашёл сервис, который монтит папку через './'. Запускаю обычный nvim."
    exec /usr/bin/nvim "${ARGS[@]}"
  fi

  echo "Найден сервис: '$SERVICE'"

  # 3. Извлекаем контейнерное имя (container_name) из этого сервиса
  CONTAINER_NAME=$(yq -r ".services.\"$SERVICE\".container_name" "$COMPOSE_FILE")

  if [[ "$CONTAINER_NAME" == "null" || -z "$CONTAINER_NAME" ]]; then
    echo "В docker-compose.yml нет поля container_name для сервиса '$SERVICE'."
    echo "Запускаю системный nvim."
    exec /usr/bin/nvim "${ARGS[@]}"
  fi

  echo "Будем юзать container_name: '$CONTAINER_NAME'"

  # 4. Проверяем, поднят ли сервис
  if docker compose ps "$SERVICE" 2>/dev/null | grep -q "Up"; then
    echo "Сервис '$SERVICE' уже поднят."
  else
    echo "Сервис '$SERVICE' не запущен — запускаю 'docker-compose up -d'..."
    docker compose up -d

    # Ждём, пока контейнер не станет 'Up'
    until docker compose ps "$SERVICE" 2>/dev/null | grep -q "Up"; do
      sleep 1
    done

    echo "Сервис '$SERVICE' поднят."
  fi

  # 5. Делаем ./devctn.sh с полученным container_name
  if [[ -x "$HOME/Scripts/nvim_devctn/devctn.sh" ]]; then
    exec ~/Scripts/devctn.sh "$CONTAINER_NAME"
  else
    echo "devctn.sh не найден или не имеет права на исполнение."
    echo "Запускаю системный nvim."
    exec /usr/bin/nvim "${ARGS[@]}"
  fi

else
  # 6. Если нет docker-compose — просто штатный nvim
  exec /usr/bin/nvim "${ARGS[@]}"
fi
