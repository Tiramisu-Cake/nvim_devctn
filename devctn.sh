#!/usr/bin/env bash
set -e

SECONDS=0

if [ -z "$1" ]; then
  echo "Использование: devctn <container_name>"
  exit 1
fi

CTN="$1"

FLAG="/root/.nvim_setup_done"
# получаем WORKDIR из конфига контейнера
WD=$(docker inspect --format='{{.Config.WorkingDir}}' "$CTN")
# если в Dockerfile не указан WORKDIR, то WD будет пустым — на всякий случай подставим /
[ -z "$WD" ] && WD=/

ensure_git() {
    docker exec "$CTN" mkdir -p /root/.ssh
    docker cp ~/.gitconfig "$CTN":/root/.gitconfig
    docker cp ~/.ssh/id_github "$CTN":/root/.ssh/id_github
    docker exec -it "$CTN" git config --global --add safe.directory "$WD" 
}

if docker exec "$CTN" test -f "$FLAG"; then
  echo "Nvim was installed before, running nvim..."
  ensure_git
  docker exec -it "$CTN" nvim
  exit 0
fi

# Скачиваем и ставим Neovim без FUSE
docker exec "$CTN" bash -lc "\
  set -e; \
  mkdir -p /opt \
"
docker cp ~/Scripts/nvim.appimage "${CTN}":/opt/nvim.appimage

docker exec "$CTN" bash -lc "\
  [ \$(stat -c%s /opt/nvim.appimage) -gt 10000000 ] || exit 1; \
  chmod u+x /opt/nvim.appimage; \
  /opt/nvim.appimage --appimage-extract; \
  mv squashfs-root /opt/nvim; \
  ln -sf /opt/nvim/usr/bin/nvim /usr/local/bin/nvim \
"

# Ставим Pyright
docker cp ~/Scripts/pyright_wheels "$CTN":/tmp/pyright_wheels
docker exec "$CTN" bash -lc "\
  pip install --no-index --find-links=/tmp/pyright_wheels 'pyright[nodejs]'
"
# 4) Копируем конфиг и плагины 
docker exec "$CTN" mkdir -p /root/.config
docker cp ~/.config/nvim "${CTN}":/root/.config/nvim
tar -C ~/.local/share/nvim -c lazy site/pack 2>/dev/null \
  | docker exec -i "$CTN" bash -lc "\
     mkdir -p /root/.local/share/nvim && \
     tar -C /root/.local/share/nvim -x && \
     chown -R root:root /root/.local/share/nvim \
     "
echo "Configuration copied"
ensure_git
docker exec "$CTN" touch "$FLAG"
echo
echo "Nvim installed in $SECONDS seconds"

IDG=$(id -g)
IDU=$(id -u)

# rm nvim.sock
docker exec -d "$CTN" nvim --headless --listen "$WD"/nvim.sock
docker exec "$CTN" chown "$IDU":"$IDG" ./nvim.sock
docker exec "$CTN" chmod 660 ./nvim.sock

nvim --server ./nvim.sock --remote-ui
