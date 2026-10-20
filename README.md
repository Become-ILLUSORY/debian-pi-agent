# debian-pi-agent

Debian 13 (trixie) 容器镜像，内置 **Pi Agent**、**pi-remote-feishu 飞书桥接** 与 SSH，apt 走清华镜像。
默认以 **root** 运行，同时保留一个可选的 `dev` 用户。

> 从 [`debian-claude-code`](https://github.com/Become-ILLUSORY/debian-claude-code) 迁出：
> Claude Code → `@earendil-works/pi-coding-agent`，cc-connect → `pi-remote-feishu`。
> 飞书走 WebSocket 长连接，除 SSH 外不需要任何对外端口。

## 内容

| 组件 | 说明 |
| --- | --- |
| 基础镜像 | `debian:trixie-slim`，apt 用 `mirrors.tuna.tsinghua.edu.cn` |
| Node.js | v22.23.3（Debian 13 自带 20，不满足 Pi 的 `>=22.19`），从清华 `nodejs-release` 下载并校验 sha256 |
| Pi Agent | `@earendil-works/pi-coding-agent`（全局 `pi` 命令） |
| 飞书桥接 | `pi-remote-feishu`（全局 `pi-remote-feishu` 命令），并注册为 Pi 扩展 |
| SSH | openssh-server，密码/公钥运行时注入 |
| 其他 | git、git-lfs、gh、python3、curl、wget、jq、tree、unzip、ripgrep、fd、bat、vim、nano、tmux、zsh、htop、mosh、build-essential |

## 目录约定

| 路径 | 用途 |
| --- | --- |
| `/workspace` | **agent 工作目录**（`PI_WORKDIR` 可改），是挂载点，不是系统根 |
| `/root/.pi` | Pi 的配置/凭据/会话（`agent/`），默认挂载持久化 |
| `/root/.config/gh` | gh 登录态 |
| `/var/log/pi-remote-feishu` | 飞书桥接日志（同时输出到 `docker logs`） |

工作目录单独放 `/workspace` 而不是 `/root`：`~/.pi/agent/auth.json`、`models.json` 里有模型密钥，
让 agent 的工作目录和凭据目录重合等于把 key 直接摊给模型。所以文件放 `/workspace`、凭据留在 `~/.pi`，
两者用不同的挂载卷。要改：`.env` 里设 `PI_WORKDIR=/srv/pi` 之类即可。

## 快速开始

```bash
cp .env.example .env
# 1) 填中转站：PI_RELAY_BASE_URL / PI_RELAY_API_KEY（自动拉模型列表）
# 2) 填飞书：FEISHU_APP_ID / FEISHU_APP_SECRET
# 3) 改 SSH 密码：SSH_PASSWORD
docker compose up -d
docker logs -f pi-agent          # SSH / 模型 / 飞书桥接状态都在这里
```

没有 compose 插件时用 `./run.sh`（等价，`docker run` + `--env-file .env`）。

预构建镜像（GitHub Actions 出 `linux/amd64` + `linux/arm64`）：

```bash
docker pull ghcr.io/become-illusory/debian-pi-agent:latest
```

## 模型：中转站（推荐）

只要填了 `PI_RELAY_BASE_URL`，容器启动时会请求 `{BASE_URL}/models` 把整份模型列表写进
`~/.pi/agent/models.json`，并可按需写默认模型：

```ini
PI_RELAY_NAME=relay
PI_RELAY_BASE_URL=https://api.your-relay.com/v1
PI_RELAY_API_KEY=sk-xxxx
PI_RELAY_API=openai-completions     # 中转站绝大多数；Anthropic 协议中转用 anthropic-messages
PI_RELAY_DEFAULT_MODEL=gpt-5.1      # 可选，写进 settings.json 作为默认模型
PI_RELAY_MODEL_FILTER=gpt-*,claude-*  # 可选，只保留匹配项
```

- `apiKey` 在 `models.json` 里写成 `"$PI_RELAY_API_KEY"` 环境变量插值，密钥不落盘。
- 中转站没有 `/models` 接口时，用 `PI_RELAY_MODELS=gpt-5.1,claude-sonnet-4-5` 手写清单兜底。
- 手动重跑：`docker exec -it pi-agent python3 /usr/local/bin/relay-sync.py`。
- 想用官方直连：不填 `PI_RELAY_*`，直接填 `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` 等，Pi 原生识别。
- 想用订阅账号：`docker exec -it pi-agent pi` → `/login`，登录态存 `~/.pi/agent/auth.json`。

## 飞书机器人配置

1. [飞书开放平台](https://open.feishu.cn/app) → 创建**企业自建应用**，「添加应用能力」→ 开启 **机器人**。
2. 「权限管理」至少开通：`im:message`、`im:message:send_as_bot`、`im:resource`。
3. 「事件订阅」→ 订阅方式选 **使用长连接接收事件**，添加事件：
   - `im.message.receive_v1`（收消息）
   - `card.action.trigger`（卡片回传交互，`/models`、`/sessions` 的按钮靠它）
4. 「版本管理与发布」→ 创建版本并发布（企业内需管理员审核）。
5. 「凭证与基础信息」拿 **App ID / App Secret** → 填 `.env` → `docker compose up -d`。

之后私聊机器人，或在群里 @机器人 说话。配置由环境变量生成到 `~/.pi/agent/feishu.json`
（已存在则只合并、保留手工修改；`FEISHU_CONFIG_FORCE=1` 强制重写）。

## 飞书命令

| 命令 | 说明 |
| --- | --- |
| `/help` | 帮助 |
| `/sessions` | 查看 / 切换 / 删除会话 |
| `/models` | 选模型与思考等级 |
| `/new` | 新建 Pi 会话 |
| `/stop` | 停止当前生成 |
| `/reset` | 重置会话映射 |
| `/status` | 连接 / 队列 / 模型状态 |

模型调用 `send_file_to_chat` 可把生成的文件发回当前聊天（受输出目录白名单与大小上限限制）。

## 使用

```bash
ssh root@localhost -p 2222      # 密码取 .env 的 SSH_PASSWORD
pi                              # Pi TUI：选模型（/model）、开会话、装包
docker exec -it -u dev pi-agent bash   # 需要非 root 时
```

## 环境变量

### 模型

| 变量 | 说明 |
| --- | --- |
| `PI_RELAY_BASE_URL` / `PI_RELAY_API_KEY` | 中转站地址与密钥，填了就自动同步模型列表 |
| `PI_RELAY_NAME` / `PI_RELAY_API` | provider id（默认 `relay`）/ `openai-completions`、`openai-responses`、`anthropic-messages` |
| `PI_RELAY_SYNC` | `0` 关闭自动拉取，只用 `PI_RELAY_MODELS` |
| `PI_RELAY_MODELS` / `PI_RELAY_MODEL_FILTER` | 手写清单 / 过滤（支持 `*`） |
| `PI_RELAY_DEFAULT_MODEL` | 默认模型 id，写进 `settings.json` |
| `PI_RELAY_CONTEXT_WINDOW` / `PI_RELAY_MAX_TOKENS` | 模型元数据，默认 128000 / 16384 |
| `PI_RELAY_VISION` | `1` 表示模型支持图片输入 |
| `PI_RELAY_COST_*` | 计价（USD/百万 token），只影响用量估算 |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` / `DEEPSEEK_API_KEY` / `OPENROUTER_API_KEY` | 官方直连凭据 |

### 飞书

| 变量 | 说明 |
| --- | --- |
| `FEISHU_ENABLED` | `auto`（默认，有 appId/appSecret 才启动）\| `1` 强制 \| `0` 关闭 |
| `FEISHU_APP_ID` / `FEISHU_APP_SECRET` | 飞书应用凭证 |
| `FEISHU_BOT_NAME` | 机器人显示名，默认 `Pi Agent` |
| `FEISHU_CONFIG` | 自定义配置路径；留空则生成 `~/.pi/agent/feishu.json` |
| `FEISHU_CONFIG_FORCE` | `1` 用环境变量整体重写配置 |
| `FEISHU_GROUP_SCOPE` | `shared-chat`（整群共享，默认）\| `per-user`（群内按人隔离） |
| `FEISHU_REQUIRE_MENTION` | 群聊是否必须 @机器人，默认 `1` |
| `FEISHU_DM_ENABLED` / `FEISHU_GROUP_ENABLED` | 是否响应私聊 / 群聊，默认都开 |
| `FEISHU_ALLOW_USERS` / `FEISHU_ALLOW_CHATS` | 白名单（open_id / chat_id），留空不限制 |
| `FEISHU_RENDERING_MODE` | `stream-card`（默认）\| `markdown` \| `text` |
| `FEISHU_LOG_LEVEL` / `FEISHU_DEBUG_EVENTS` | 日志级别 / 打印事件摘要 |
| `FEISHU_MAX_UPLOAD_MB` | 回传文件大小上限，默认 20 |
| `FEISHU_RESTART_LIMIT` | 桥接连续异常退出的重启次数，默认 5（15s→300s 退避） |

### SSH / 运行

| 变量 | 说明 |
| --- | --- |
| `SSH_PASSWORD` | root 的 SSH 密码；留空则不设密码 |
| `DEV_PASSWORD` | 可选，`dev` 用户密码（容器默认仍用 root） |
| `SSH_AUTHORIZED_KEYS` | 公钥内容，写入 root 与 dev 的 `authorized_keys` |
| `SSH_PERMIT_ROOT_LOGIN` / `SSH_PASSWORD_AUTH` | 覆盖 sshd 配置，默认 `yes` |
| `PI_WORKDIR` | agent 工作目录，默认 `/workspace` |
| `DATA_DIR` | 宿主数据目录，默认 `./data` |

## 从源码构建

```bash
./build.sh
# 或
docker build -t debian-pi-agent:latest .
```

| 构建参数 | 默认值 |
| --- | --- |
| `DEBIAN_VERSION` | `trixie-slim` |
| `NODE_VERSION` | `22.23.3` |
| `PI_VERSION` | `latest` |
| `PI_REMOTE_FEISHU_VERSION` | `latest` |
| `PI_FEISHU_EXTENSION` | `1` |
| `DEV_UID` / `DEV_GID` | `1000` / `1000` |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` |

基础镜像没有 CA 证书，先用 `http` 装 `ca-certificates` 再切回 `https`，否则 `apt-get update` 会整段被忽略。

`pi install npm:pi-remote-feishu` 装出的 `~/.pi`（约 200MB，含扩展依赖）会挪到 `/opt/pi-seed`；
首启发现挂载卷是空的就自动复制回去，不用联网重装。

## 数据持久化

compose 映射到 `./data/`：`workspace/` → `/workspace`、`ssh/` → `/etc/ssh/keys`（主机密钥）、
`pi/` → `/root/.pi`（登录态、会话、飞书会话映射 `feishu/sessions.json`）、`gh/` → `/root/.config/gh`。
`/var/log` 用命名卷 `pi-log`。

## 排障

```bash
docker logs pi-agent                                    # 启动摘要 + 桥接日志
docker exec -it pi-agent pi-remote-feishu doctor --cwd /workspace
docker exec -it pi-agent pi --list-models               # 看 relay 是否同步到
docker exec -it pi-agent pi-remote-feishu send-test --chat-id oc_xxx --text hello
```

- `Missing Feishu appId`：凭证没传进容器，或 `FEISHU_ENABLED=0`。
- `could not resolve bot identity ... 400`：凭证错 / 应用未发布 / 机器人能力没开。
- 收不到消息：事件订阅没选「长连接」或没订阅 `im.message.receive_v1`。
- 卡片按钮无反应：没订阅 `card.action.trigger`，或改权限后没重新发布版本。
- 模型报未配置：看 `docker exec pi-agent pi --list-models`，空的话检查 `PI_RELAY_*` 或 API key。

## 与上游的关系

桥接本体是第三方包 [pi-remote-feishu](https://pi.dev/packages/pi-remote-feishu)（MIT），
它用自己的 Pi SDK（当前 0.83.0）在进程内驱动会话；镜像里的 `pi` 命令独立安装（默认 `latest`）。
两者会话格式版本一致（`SESSION_VERSION=3`）；若上游改版出现会话不兼容，
用 `--build-arg PI_VERSION=0.83.0` 把全局 `pi` 固定到同版本。

Pi 文档：<https://pi.dev/docs> · 包列表：<https://pi.dev/packages>
