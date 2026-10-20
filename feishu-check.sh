#!/usr/bin/env bash
# 飞书桥接快速自检：凭证有效性 / 机器人身份 / 进程 / 最近日志
# 用法：feishu-check [--json]
set -uo pipefail

json_mode=0
[ "${1:-}" = "--json" ] && json_mode=1

cfg=/root/.pi/agent/feishu.json
app_id="${FEISHU_APP_ID:-}"
app_secret="${FEISHU_APP_SECRET:-}"

if [ -z "$app_id" ] || [ -z "$app_secret" ]; then
    if [ -f "$cfg" ]; then
        app_id="${app_id:-$(python3 -c "import json;print(json.load(open('$cfg')).get('appId',''))" 2>/dev/null)}"
        app_secret="${app_secret:-$(python3 -c "import json;print(json.load(open('$cfg')).get('appSecret',''))" 2>/dev/null)}"
    fi
fi

mask() { local s=$1; [ ${#s} -le 8 ] && echo "***" || echo "${s:0:6}…${s: -4}"; }

result=2
msg_cred="未配置"
if [ -n "$app_id" ] && [ -n "$app_secret" ]; then
    resp=$(curl -sS -m 15 -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
        -H 'Content-Type: application/json' \
        -d "{\"app_id\":\"${app_id}\",\"app_secret\":\"${app_secret}\"}" 2>/dev/null)
    code=$(printf '%s' "$resp" | jq -r '.code // empty' 2>/dev/null)
    token=$(printf '%s' "$resp" | jq -r '.tenant_access_token // empty' 2>/dev/null)
    if [ "$code" = "0" ] && [ -n "$token" ]; then
        bot=$(curl -sS -m 15 "https://open.feishu.cn/open-apis/bot/v3/info" -H "Authorization: Bearer ${token}" 2>/dev/null)
        bot_name=$(printf '%s' "$bot" | jq -r '.bot.app_name // empty' 2>/dev/null)
        bot_open=$(printf '%s' "$bot" | jq -r '.bot.open_id // empty' 2>/dev/null)
        result=0
        if [ -n "$bot_name" ]; then
            msg_cred="有效（机器人：${bot_name}${bot_open:+ / ${bot_open}}）"
        else
            msg_cred="凭证有效，但拿不到机器人信息：$(printf '%s' "$bot" | jq -r '.msg // "未知错误"' 2>/dev/null)"
            result=1
        fi
    else
        if [ -z "$code" ]; then
            msg_cred="检查失败（网络或响应异常）"
            result=2
        else
            msg_cred="无效（code=${code}：$(printf '%s' "$resp" | jq -r '.msg // empty' 2>/dev/null)）"
            result=1
        fi
    fi
fi

proc="未运行"
pid=$(pgrep -f "pi-remote-feishu serve" 2>/dev/null | head -1)
[ -n "$pid" ] && proc="运行中（pid ${pid}）"

log=/var/log/pi-remote-feishu/feishu.log
if [ "$json_mode" = "1" ]; then
    jq -n --arg appId "$(mask "$app_id")" --arg cred "$msg_cred" --arg proc "$proc" \
        '{appId:$appId, credentials:$cred, process:$proc}'
    exit $result
fi

echo "应用 App ID : $(mask "$app_id")"
echo "凭证状态    : ${msg_cred}"
echo "桥接进程    : ${proc}"
echo "配置文件    : $([ -f "$cfg" ] && echo "$cfg" || echo "（无，走环境变量）")"
if [ -f "$log" ]; then
    echo "最近日志    :"
    grep -vE "^\s+(at |Symbol\(|[a-zA-Z]+: \[)|^\s{4,}" "$log" 2>/dev/null | tail -n 8 | sed 's/^/  /'
fi
exit $result
