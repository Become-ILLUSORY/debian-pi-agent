#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# 让 .env 成为唯一输入：构建参数也从这里来
[ -f .env ] && set -a && . ./.env && set +a

IMAGE_NAME="${IMAGE_NAME:-debian-pi-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

if ! docker info >/dev/null 2>&1; then
    echo "无法连接 docker 守护进程。" >&2
    echo "如果是权限问题：注销重登，或执行 newgrp docker 后重新运行本脚本。" >&2
    exit 1
fi

docker build \
    --build-arg "DEBIAN_VERSION=${DEBIAN_VERSION:-trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f}" \
    --build-arg "NODE_VERSION=${NODE_VERSION:-22.23.3}" \
    --build-arg "DEV_UID=${DEV_UID:-$(id -u)}" \
    --build-arg "DEV_GID=${DEV_GID:-$(id -g)}" \
    --build-arg "PI_VERSION=${PI_VERSION:-latest}" \
    --build-arg "PI_REMOTE_FEISHU_VERSION=${PI_REMOTE_FEISHU_VERSION:-latest}" \
    --build-arg "PI_FEISHU_EXTENSION=${PI_FEISHU_EXTENSION:-0}" \
    --build-arg "PI_STRICT_LOCK=${PI_STRICT_LOCK:-0}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    "$@" \
    .

# 精确版本时额外打一个版本别名 tag，方便回滚
if [ "${PI_VERSION:-latest}" != "latest" ] && [ "${PI_REMOTE_FEISHU_VERSION:-latest}" != "latest" ]; then
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${IMAGE_NAME}:${PI_VERSION}-${PI_REMOTE_FEISHU_VERSION}"
    echo "版本别名：${IMAGE_NAME}:${PI_VERSION}-${PI_REMOTE_FEISHU_VERSION}"
fi

echo "构建完成：${IMAGE_NAME}:${IMAGE_TAG}"
echo "本次装配清单："
docker run --rm --entrypoint cat "${IMAGE_NAME}:${IMAGE_TAG}" /etc/pi-image-manifest.json 2>/dev/null || true
echo "启动：docker compose up -d"
