#!/usr/bin/env bash
set -e

SECONDS=0

if [ -z "$1" ]; then
  echo "Использование: devctn <container_name>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTN="$1"
CTN_HOME=$(docker exec "$CTN" bash -lc 'echo $HOME')
FLAG="$CTN_HOME/.nvim_setup_done"
# получаем WORKDIR из конфига контейнера
WD=$(docker inspect --format='{{.Config.WorkingDir}}' "$CTN")
# если в Dockerfile не указан WORKDIR, то WD будет пустым — на всякий случай подставим /
[ -z "$WD" ] && WD=/

ensure_git() {
    docker exec "$CTN" mkdir -p "$CTN_HOME"/.ssh
    docker cp ~/.gitconfig "$CTN":"$CTN_HOME"/.gitconfig
    docker cp ~/.ssh/id_cakegithub "$CTN":"$CTN_HOME"/.ssh/id_github
    docker exec "$CTN" git config --global --add safe.directory "$WD" 
    docker exec -i "$CTN" bash <<'EOF'
    cat > ~/.ssh/config <<EOC
    Host github.com
    IdentityFile ~/.ssh/id_github
    IdentitiesOnly yes
EOC
EOF

    if docker exec "$CTN" bash -c 'command -v pre-commit >/dev/null'; then
        echo "Pre-commit нашёлся, ставлю хуки..."
        docker exec "$CTN" bash -c "cd $WD && pre-commit install"
    else
        echo "Pre-commit не установлен — хуки не ставлю."
    fi
}

ensure_autochown_config() {
    CONFIG_FILE="$CTN_HOME/.config/nvim/lua/autochown.lua"
    INIT_FILE="$CTN_HOME/.config/nvim/init.lua"
    if docker exec "$CTN" test -f "$CONFIG_FILE"; then
        return 0
    fi
    if docker exec "$CTN" grep -q 'require("autochown")' "$INIT"; then
        return 0
    fi

    docker exec "$CTN" mkdir -p "$(dirname "$CONFIG_FILE")"
    docker cp "$SCRIPT_DIR"/autochown.lua "${CTN}":"$CONFIG_FILE"
    docker exec "$CTN" bash -c "echo 'require(\"autochown\")' >> '$INIT_FILE'"
    echo "» Snippet для chown добавлен в контейнере"
}
  
start_nvim() {
    ensure_git
    ensure_autochown_config
    IDG=$(id -g)
    IDU=$(id -u)
    docker exec -d \
        -e HOST_UID="$IDU" \
        -e HOST_GID="$IDG" \
        "$CTN" nvim --headless --listen "$WD"/nvim.sock
    docker exec "$CTN" chown "$IDU":"$IDG" ./nvim.sock
    docker exec "$CTN" chmod 660 ./nvim.sock
    docker exec -it "$CTN" nvim
    exit 0
}

if docker exec "$CTN" test -f "$FLAG"; then
    echo "Nvim was installed before, running nvim..."
    start_nvim
fi

# Скачиваем и ставим Neovim без FUSE
docker exec "$CTN" bash -lc "\
  set -e; \
  mkdir -p /opt \
"
docker cp "$SCRIPT_DIR"/nvim.appimage "${CTN}":/opt/nvim.appimage

docker exec "$CTN" bash -lc "\
  [ \$(stat -c%s /opt/nvim.appimage) -gt 10000000 ] || exit 1; \
  chmod u+x /opt/nvim.appimage; \
  /opt/nvim.appimage --appimage-extract; \
  mv squashfs-root /opt/nvim; \
  ln -sf /opt/nvim/usr/bin/nvim /usr/local/bin/nvim \
"

# Ставим Pyright
docker cp "$SCRIPT_DIR"/pyright_wheels "$CTN":/tmp/pyright_wheels
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
     chown -R root:root /root/.local/share/nvim"
echo "Configuration copied"
ensure_git
docker exec "$CTN" touch "$FLAG"
echo
echo "Nvim installed in $SECONDS seconds"

start_nvim
