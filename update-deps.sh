#!/usr/bin/env bash
# 更新镜像依赖锁文件（npm/package-lock.json），并把版本同步写进 .env
# 用法：./update-deps.sh [pi版本] [飞书桥接版本]
set -euo pipefail

cd "$(dirname "$0")"

PI_VER="${1:-}"
FEISHU_VER="${2:-}"

if [ -z "$PI_VER" ] || [ -z "$FEISHU_VER" ]; then
    echo "用法：$0 <pi版本> <飞书桥接版本>" >&2
    echo "示例：$0 1.3.0 0.1.6" >&2
    exit 1
fi

cd npm
npm install --package-lock-only --no-audit --no-fund \
    "@earendil-works/pi-coding-agent@${PI_VER}" \
    "pi-remote-feishu@${FEISHU_VER}" >/dev/null
cd ..

echo "锁文件已更新：pi=${PI_VER} feishu=${FEISHU_VER}"

if [ -f .env ]; then
    sed -i -E "s/^PI_VERSION=.*/PI_VERSION=${PI_VER}/; s/^PI_REMOTE_FEISHU_VERSION=.*/PI_REMOTE_FEISHU_VERSION=${FEISHU_VER}/" .env
    echo ".env 已同步这两个版本号"
else
    echo "提示：.env 不存在，记得把 PI_VERSION=${PI_VER} / PI_REMOTE_FEISHU_VERSION=${FEISHU_VER} 加进去"
fi

echo "下一步：docker compose build && docker compose up -d"
