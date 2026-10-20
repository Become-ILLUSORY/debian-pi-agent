#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

: "${SSH_PASSWORD:=}"
: "${DEV_PASSWORD:=}"
: "${DEV_USER:=dev}"
: "${SSH_PERMIT_ROOT_LOGIN:=yes}"
: "${SSH_PASSWORD_AUTH:=yes}"
: "${PI_WORKDIR:=/workspace}"
: "${FEISHU_ENABLED:=1}"
: "${FEISHU_CONFIG:=}"
: "${FEISHU_GROUP_SCOPE:=shared-chat}"
: "${FEISHU_LOG_LEVEL:=info}"
: "${FEISHU_DEBUG_EVENTS:=0}"
: "${FEISHU_CONFIG_FORCE:=0}"
: "${FEISHU_RESTART_LIMIT:=0}"   # 0 = 不限次数（退避封顶 300s）
: "${FEISHU_PREFLIGHT:=0}"   # 1 = 启动前额外自检，仅告警不阻止启动

# ---------- SSH ----------
mkdir -p /run/sshd /etc/ssh/keys /root/.ssh
chmod 700 /root/.ssh /etc/ssh/keys

gen_key() {
    local type=$1 path=$2
    [ -s "$path" ] || ssh-keygen -q -t "$type" -N '' -f "$path" -C "root@$(hostname)"
}

gen_key ed25519 /etc/ssh/keys/ssh_host_ed25519_key
gen_key rsa /etc/ssh/keys/ssh_host_rsa_key
chmod 600 /etc/ssh/keys/ssh_host_*_key
chmod 644 /etc/ssh/keys/ssh_host_*.pub

if [ -n "$SSH_PASSWORD" ]; then
    echo "root:${SSH_PASSWORD}" | chpasswd
    log "root 密码已设置"
fi

if [ -n "$DEV_PASSWORD" ]; then
    echo "${DEV_USER}:${DEV_PASSWORD}" | chpasswd
    log "${DEV_USER} 密码已设置（默认仍以 root 运行，按需 docker exec -it -u ${DEV_USER} 切过去）"
fi

# 支持 SSH_AUTHORIZED_KEYS 环境变量（多行）或 /etc/ssh/authorized_keys 挂载文件
if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$SSH_AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
if [ -s /etc/ssh/authorized_keys ]; then
    install -m 600 /etc/ssh/authorized_keys /root/.ssh/authorized_keys
    if id "$DEV_USER" >/dev/null 2>&1; then
        install -d -m 700 -o "$DEV_USER" -g "$(id -gn "$DEV_USER")" "/home/${DEV_USER}/.ssh"
        install -m 600 -o "$DEV_USER" -g "$(id -gn "$DEV_USER")" /etc/ssh/authorized_keys "/home/${DEV_USER}/.ssh/authorized_keys"
    fi
fi

sed -i -E "s/^PermitRootLogin .*/PermitRootLogin ${SSH_PERMIT_ROOT_LOGIN}/" /etc/ssh/sshd_config.d/00-container.conf
sed -i -E "s/^PasswordAuthentication .*/PasswordAuthentication ${SSH_PASSWORD_AUTH}/" /etc/ssh/sshd_config.d/00-container.conf
/usr/sbin/sshd -t
mkdir -p /run/sshd
/usr/sbin/sshd -e
log "sshd 已启动 (22)"

# ---------- Pi 配置目录 ----------
# 挂载的 $HOME/.pi 为空（新卷）时，用镜像里烘焙的种子填充：
# 其中包含 pi-remote-feishu 扩展与 npm 缓存的包，避免首启再联网安装。
if [ ! -f /root/.pi/agent/settings.json ] && [ -f /opt/pi-seed/agent/settings.json ]; then
    log "初始化 /root/.pi（从镜像种子复制）"
    mkdir -p /root/.pi
    cp -a /opt/pi-seed/. /root/.pi/
fi

# ---------- 本次镜像的装配清单 ----------
if [ -f /etc/pi-image-manifest.json ]; then
    log "镜像组件：$(python3 -c 'import json;d=json.load(open("/etc/pi-image-manifest.json"));print("pi %s · feishu %s · node %s · strict-lock=%s · deps %s" % (d["pi"], d["feishuBridge"], d["node"], d["strictLock"], d["depsHash"]))' 2>/dev/null || echo "见 /etc/pi-image-manifest.json")"
fi

case "$PI_WORKDIR" in
    /|/root|/home|/etc|/usr|/var|/bin|/sbin|/lib|/boot|/dev|/proc|/sys)
        log "警告：PI_WORKDIR=${PI_WORKDIR} 是系统/凭据目录，agent 会读写敏感文件；建议保持默认 /workspace"
        ;;
esac
mkdir -p "$PI_WORKDIR"

# ---------- 中转站模型 ----------
if [ -n "${PI_RELAY_BASE_URL:-}" ]; then
    if python3 /usr/local/bin/relay-sync.py; then
        :
    else
        log "中转站模型同步失败（不影响启动），可 docker exec -it <容器> python3 /usr/local/bin/relay-sync.py 手动重试"
    fi
fi

# ---------- Pi 模型凭据体检 ----------
has_model_creds() {
    for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY DEEPSEEK_API_KEY \
        OPENROUTER_API_KEY XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY ZAI_API_KEY \
        MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY CEREBRAS_API_KEY; do
        if [ -n "${!var:-}" ]; then
            log "检测到模型凭据：${var}"
            return 0
        fi
    done
    if [ -n "${PI_RELAY_BASE_URL:-}" ] && [ -n "${PI_RELAY_API_KEY:-}" ]; then
        log "使用中转站模型：${PI_RELAY_BASE_URL}（provider=${PI_RELAY_NAME:-relay}）"
        return 0
    fi
    if [ -s /root/.pi/agent/auth.json ]; then
        log "检测到已登录的模型账号：/root/.pi/agent/auth.json"
        return 0
    fi
    if grep -q '"defaultModel"' /root/.pi/agent/settings.json 2>/dev/null; then
        log "检测到默认模型：$(grep -o '"defaultModel"[^,}]*' /root/.pi/agent/settings.json | head -1)"
        return 0
    fi
    log "警告：还没有模型凭据。飞书/终端里发消息会失败，二选一："
    log "  a) 在 .env 里填 ANTHROPIC_API_KEY / OPENAI_API_KEY / ... 后重启容器"
    log "  b) docker exec -it <容器> pi → /login 登录订阅账号，Ctrl+S 存默认模型"
    return 1
}
has_model_creds || true

# ---------- pi-remote-feishu ----------
have_feishu_creds() {
    if [ -n "${FEISHU_APP_ID:-}" ] && [ -n "${FEISHU_APP_SECRET:-}" ]; then
        return 0
    fi
    return 1
}

should_start_feishu() {
    case "$FEISHU_ENABLED" in
        0|false|no|off|"") return 1 ;;
        1|true|yes|on) return 0 ;;
        auto) have_feishu_creds ;;
        *)
            log "FEISHU_ENABLED=${FEISHU_ENABLED} 无法识别，按 auto 处理"
            have_feishu_creds ;;
    esac
}

if should_start_feishu; then
    if [ -z "${FEISHU_APP_ID:-}" ] || [ -z "${FEISHU_APP_SECRET:-}" ]; then
        log "未设置 FEISHU_APP_ID / FEISHU_APP_SECRET，飞书桥接无法启动"
    else
        config_path="$FEISHU_CONFIG"
        if [ -z "$config_path" ]; then
            # 由环境变量生成/合并 ~/.pi/agent/feishu.json，并让桥接自动发现
            force_args=()
            [ "$FEISHU_CONFIG_FORCE" = "1" ] && force_args=(--force)
            if ! python3 /usr/local/bin/feishu-config.py --out /root/.pi/agent/feishu.json "${force_args[@]}"; then
                log "生成飞书配置失败，继续用环境变量启动"
            fi
        elif [ ! -f "$config_path" ]; then
            log "FEISHU_CONFIG=$config_path 不存在，改用环境变量启动"
            config_path=""
        fi

        # 可选自检：只打日志，永远不阻止桥接启动（这是异地控制通道，失败也要让它自己重试）
        if [ "$FEISHU_PREFLIGHT" = "1" ]; then
            check_rc=0
            check_out=$(feishu-check 2>&1) || check_rc=$?
            case "$check_rc" in
                0) log "飞书凭证校验：$(printf '%s' "$check_out" | sed -n 's/^凭证状态 *: //p')" ;;
                1) log "警告：飞书凭证自检失败（仍然启动桥接，持续重试）："
                   printf '%s\n' "$check_out" | sed 's/^/    /' ;;
                *) log "飞书凭证自检未能完成（网络问题？），照常启动桥接" ;;
            esac
        fi

        mkdir -p /var/log/pi-remote-feishu
        logfile=/var/log/pi-remote-feishu/feishu.log
        touch "$logfile"

        argv=(serve --cwd "$PI_WORKDIR" --log-level "$FEISHU_LOG_LEVEL" --group-scope "$FEISHU_GROUP_SCOPE")
        [ -n "$config_path" ] && argv+=(--config "$config_path")
        [ "$FEISHU_DEBUG_EVENTS" = "1" ] && argv+=(--debug-events)

        log "启动 pi-remote-feishu（workspace=${PI_WORKDIR}, group-scope=${FEISHU_GROUP_SCOPE}）"
        # 守护：异常退出按 15s→300s 退避重启；运行满 2 分钟重置计数；
        # FEISHU_RESTART_LIMIT=0（默认）表示不限次数
        (
            set +e
            attempt=0
            while :; do
                started=$(date +%s)
                pi-remote-feishu "${argv[@]}" 2>&1
                code=$?
                ran=$(( $(date +%s) - started ))
                [ "$ran" -ge 120 ] && attempt=0
                attempt=$((attempt + 1))
                if [ "$FEISHU_RESTART_LIMIT" != "0" ] && [ "$attempt" -ge "$FEISHU_RESTART_LIMIT" ]; then
                    log "pi-remote-feishu 连续异常退出 ${attempt} 次（最后退出码 ${code}），已停止重启；改好配置后重启容器即可"
                    exit 0
                fi
                delay=$((attempt * 15))
                [ "$delay" -gt 300 ] && delay=300
                log "pi-remote-feishu 退出（code=${code}，运行 ${ran}s），${delay}s 后重启"
                sleep "$delay"
            done
        ) 2>&1 | tee -a "$logfile" &
        sleep 6
        if pgrep -f "pi-remote-feishu serve" >/dev/null 2>&1; then
            log "pi-remote-feishu 已启动（日志同时输出到 docker logs 与容器内 ${logfile}）"
        else
            log "pi-remote-feishu 首次启动未保持运行，守护进程会继续重试，见上方日志"
        fi
    fi
else
    if [ "$FEISHU_ENABLED" = "auto" ]; then
        log "飞书桥接未启动：FEISHU_ENABLED=auto 但缺少 FEISHU_APP_ID / FEISHU_APP_SECRET"
    else
        log "飞书桥接已关闭（FEISHU_ENABLED=${FEISHU_ENABLED}）；这是异地控制通道，非必要不建议关"
    fi
fi

# ---------- 启动摘要 ----------
log "-------------------------------------------"
log "SSH  : ssh root@<宿主> -p ${SSH_PORT_HINT:-${SSH_PORT:-2222}}"
log "工作区: ${PI_WORKDIR}   Pi TUI: docker exec -it <容器> pi"
if pgrep -f "pi-remote-feishu serve" >/dev/null 2>&1; then
    log "飞书  : 桥接运行中，直接在飞书里发消息"
    log "排障  : docker exec -it <容器> feishu-check"
else
    log "飞书  : 未运行（docker exec -it <容器> feishu-check 看原因）"
fi
log "-------------------------------------------"

exec "$@"
