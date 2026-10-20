#!/usr/bin/env bash
# 没有 docker compose 插件时的启动脚本：docker run 起容器
set -euo pipefail

cd "$(dirname "$0")"

[ -f .env ] && set -a && . ./.env && set +a

IMAGE_NAME="${IMAGE_NAME:-debian-pi-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-pi-agent}"
DATA_DIR="${DATA_DIR:-./data}"
case "$DATA_DIR" in
    /*) DATA_ABS="$DATA_DIR" ;;
    *)  DATA_ABS="$(pwd)/${DATA_DIR#./}" ;;
esac

mkdir -p "$DATA_DIR"/workspace "$DATA_DIR"/ssh "$DATA_DIR"/pi "$DATA_DIR"/gh

ENV_ARGS=()
[ -f .env ] && ENV_ARGS=(--env-file .env)

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --restart unless-stopped \
    -t \
    -p "${SSH_PORT:-2222}:22" \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    -v "${DATA_ABS}/workspace:/workspace" \
    -v "${DATA_ABS}/ssh:/etc/ssh/keys" \
    -v "${DATA_ABS}/pi:/root/.pi" \
    -v "${DATA_ABS}/gh:/root/.config/gh" \
    "${IMAGE_NAME}:${IMAGE_TAG}"

echo "容器已启动：$CONTAINER_NAME"
echo "SSH：ssh root@localhost -p ${SSH_PORT:-2222}"
echo "Pi 日志：docker exec -it $CONTAINER_NAME tail -f /var/log/pi-remote-feishu/feishu.log"
