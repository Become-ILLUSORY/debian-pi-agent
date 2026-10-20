# syntax=docker/dockerfile:1

ARG DEBIAN_VERSION=trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
FROM debian:${DEBIAN_VERSION}

# 全局 ARG 必须在 FROM 之后重新声明，才能在构建阶段里使用
ARG DEBIAN_VERSION
ARG DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
ARG NODE_VERSION=22.23.3
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG PI_VERSION=latest
ARG PI_REMOTE_FEISHU_VERSION=latest
ARG PI_STRICT_LOCK=0
ARG PI_FEISHU_EXTENSION=0
ARG TARGETARCH
ARG DEV_UID=1000
ARG DEV_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    PI_SKIP_VERSION_CHECK=1

# 换成清华源（trixie 使用 deb822 格式的 debian.sources）
# 镜像里还没有 CA 证书，先用 http 拉一次装好 ca-certificates，再切回 https
RUN set -eux; \
    src=/etc/apt/sources.list.d/debian.sources; \
    sed -i -E "s#https?://(deb|security)\.debian\.org#http://${DEBIAN_MIRROR#*://}#g" "$src"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    sed -i -E "s#http://${DEBIAN_MIRROR#*://}#${DEBIAN_MIRROR}#g" "$src"; \
    apt-get update; \
    rm -rf /var/lib/apt/lists/*; \
    cat "$src"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash-completion ca-certificates curl wget gnupg \
        git git-lfs gh \
        openssh-server openssh-client mosh \
        tini gosu sudo \
        python3 python3-venv python3-pip \
        jq tree less unzip zip xz-utils file tar gzip \
        ripgrep fd-find bat htop procps iproute2 bind9-dnsutils \
        vim nano tmux zsh bash tzdata \
        build-essential; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Node.js（Debian 13 自带 20，Pi 要求 >= 22.19）
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="${DEBIAN_MIRROR}/nodejs-release/v${NODE_VERSION}"; \
    tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSL --retry 3 --connect-timeout 20 "$base/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
    curl -fsSL --retry 3 --connect-timeout 20 "$base/$tarball" -o "/tmp/$tarball"; \
    (cd /tmp && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -); \
    tar -xJf "/tmp/$tarball" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "/tmp/$tarball" /tmp/SHASUMS256.txt; \
    node -v; npm -v

# Pi Agent + 飞书桥接 CLI
# - 默认（PI_STRICT_LOCK=0）：按 .env 里的版本装，写 latest 就跟着升
# - 严格复现（PI_STRICT_LOCK=1）：用仓库里的 npm/package-lock.json 做 npm ci，依赖树逐层锁定
# 两种方式装进同一个目录，装完都把「实际装配清单」写进 /etc/pi-image-manifest.json
COPY npm/package.json npm/package-lock.json /opt/pi-deps/
RUN set -eux; \
    cd /opt/pi-deps; \
    if [ "${PI_STRICT_LOCK}" = "1" ]; then \
        npm ci --omit=dev --no-audit --no-fund; \
    else \
        npm install --omit=dev --no-audit --no-fund --no-save \
            "@earendil-works/pi-coding-agent@${PI_VERSION}" \
            "pi-remote-feishu@${PI_REMOTE_FEISHU_VERSION}"; \
    fi; \
    ln -sf /opt/pi-deps/node_modules/.bin/pi /usr/local/bin/pi; \
    ln -sf /opt/pi-deps/node_modules/.bin/pi-remote-feishu /usr/local/bin/pi-remote-feishu; \
    pi --version; \
    pi-remote-feishu help >/dev/null; \
    npm cache clean --force

# 构建输入 + 实际装配清单：镜像里随时核对这套环境是怎么来的
RUN set -eux; \
    cd /opt/pi-deps; \
    pi_ver="$(node -p "require('/opt/pi-deps/node_modules/@earendil-works/pi-coding-agent/package.json').version")"; \
    feishu_ver="$(node -p "require('/opt/pi-deps/node_modules/pi-remote-feishu/package.json').version")"; \
    deps_hash="$(npm ls --all --json 2>/dev/null | sha256sum | cut -c1-16)"; \
    npm ls --all 2>/dev/null > /etc/pi-deps-tree.txt || true; \
    printf '{\n  "base": "%s",\n  "node": "%s",\n  "piRequested": "%s",\n  "feishuRequested": "%s",\n  "pi": "%s",\n  "feishuBridge": "%s",\n  "strictLock": %s,\n  "depsHash": "%s",\n  "feishuExtension": %s\n}\n' \
        "${DEBIAN_VERSION}" "${NODE_VERSION}" "${PI_VERSION}" "${PI_REMOTE_FEISHU_VERSION}" \
        "$pi_ver" "$feishu_ver" "${PI_STRICT_LOCK}" "$deps_hash" "${PI_FEISHU_EXTENSION}" \
        > /etc/pi-image-manifest.json; \
    cat /etc/pi-image-manifest.json

# 可选（默认关）：把飞书桥接注册为 Pi 扩展（TUI 里的 /feishu 命令）。
# serve 模式自带 send_file_to_chat，不装扩展也能用；打开后装好的 ~/.pi 移到 /opt/pi-seed，
# 首次启动由 entrypoint 复制进（可能为空的）挂载卷 ~/.pi。
RUN set -eux; \
    if [ "${PI_FEISHU_EXTENSION}" = "1" ]; then \
        mkdir -p /root/.pi/agent; \
        pi install "npm:pi-remote-feishu@${PI_REMOTE_FEISHU_VERSION}" >/dev/null 2>&1; \
        mv /root/.pi /opt/pi-seed; \
    else \
        mkdir -p /opt/pi-seed/agent; \
    fi; \
    mkdir -p /root/.pi; \
    du -sh /opt/pi-seed || true

# 目录 + 备用普通用户（默认仍以 root 运行，dev 只是需要时切过去用）
RUN set -eux; \
    if ! getent group "${DEV_GID}" >/dev/null; then groupadd -g "${DEV_GID}" dev; fi; \
    if ! getent passwd "${DEV_UID}" >/dev/null; then \
        useradd -m -u "${DEV_UID}" -g "$(getent group "${DEV_GID}" | cut -d: -f1)" -s /bin/bash dev; \
    fi; \
    dev_user="$(getent passwd "${DEV_UID}" | cut -d: -f1)"; \
    echo "${dev_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-dev; \
    chmod 0440 /etc/sudoers.d/90-dev; \
    mkdir -p /workspace /run/sshd /etc/ssh/keys /root/.pi/agent /var/log/pi-remote-feishu; \
    chown "root:$(getent group "${DEV_GID}" | cut -d: -f1)" /workspace; \
    chmod 775 /workspace; \
    chmod 700 /root

# sshd：容器内允许 root 密码登录，宿主密钥目录可挂载持久化
COPY sshd-container.conf /etc/ssh/sshd_config.d/00-container.conf
# 去掉镜像内烘焙的默认主机密钥，改为启动时在 /etc/ssh/keys 生成（可挂载持久化）
RUN set -eux; \
    chmod 600 /etc/ssh/sshd_config.d/00-container.conf; \
    sed -i 's|^HostKey /etc/ssh/ssh_host_|#&|' /etc/ssh/sshd_config; \
    rm -f /etc/ssh/ssh_host_*

COPY feishu-config.py /usr/local/bin/feishu-config.py
COPY relay-sync.py /usr/local/bin/relay-sync.py
COPY feishu-check.sh /usr/local/bin/feishu-check
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/feishu-config.py /usr/local/bin/relay-sync.py \
        /usr/local/bin/feishu-check /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["sleep", "infinity"]
