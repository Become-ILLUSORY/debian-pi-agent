# debian-pi-agent

Debian 13 (trixie) 容器镜像，内置 **Pi Agent**、**pi-remote-feishu 飞书桥接** 与 SSH，apt 走清华镜像。
默认以 **root** 运行，同时保留一个可选的 `dev` 用户。

> 飞书是主要的远程控制通道（异地开会话、审批工具调用），走 WebSocket 长连接，除 SSH 外不需要任何对外端口。
> 桥接进程有守护：异常退出按 15s→300s 退避重启，默认不限次数。
> 早期 Claude Code + cc-connect 版本见 [`debian-claude-code`](https://github.com/Become-ILLUSORY/debian-claude-code)，已停止更新。

## 内容

| 组件 | 说明 |
| --- | --- |
| 基础镜像 | `debian:trixie-slim`，apt 用 `mirrors.tuna.tsinghua.edu.cn` |
| Node.js | v22.23.3（Debian 13 自带 20，不满足 Pi 的 `>=22.19`），从清华 `nodejs-release` 下载并校验 sha256 |
| Pi Agent | 全局 `pi` 命令（TUI、包管理、模型选择） |
| 飞书桥接 | `pi-remote-feishu`（全局 `pi-remote-feishu` 命令）；可选注册为 Pi 扩展（默认关，见下） |
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
# 2) 填飞书：FEISHU_APP_ID / FEISHU_APP_SECRET（异地控制通道，默认开）
# 3) 改 SSH 密码：SSH_PASSWORD
docker compose up -d
docker logs -f pi-agent          # SSH / 模型 / 飞书桥接状态都在这里
```

正常启动大致长这样：

```
[entrypoint] root 密码已设置
[entrypoint] sshd 已启动 (22)
[relay] 从 https://api.your-relay.com/v1/models 拉到 86 个模型
[relay] 已写入 /root/.pi/agent/models.json（provider=relay, 72 个模型, api=openai-completions）
[relay] 默认模型：relay/gpt-5.1
[entrypoint] 飞书凭证校验：有效（机器人：Pi Agent / ou_xxx）
[entrypoint] pi-remote-feishu 已启动（日志同时输出到 docker logs 与容器内 /var/log/pi-remote-feishu/feishu.log）
[entrypoint] ----- 启动摘要 -----
```

没有 compose 插件时用 `./run.sh`（等价，`docker run` + `--env-file .env`）。

预构建镜像（GitHub Actions 出 `linux/amd64` + `linux/arm64`）：

```bash
docker pull ghcr.io/become-illusory/debian-pi-agent:latest
```

## 示例 docker-compose.yml

不想用仓库自带的构建版，直接拉预构建镜像的话，复制下面这份就够：

```yaml
services:
  pi:
    image: ghcr.io/become-illusory/debian-pi-agent:latest
    container_name: pi-agent
    hostname: pi-agent
    restart: unless-stopped
    tty: true
    stdin_open: true
    ports:
      - "2222:22"                    # 宿主 2222 → 容器 22（SSH）
    env_file:
      - .env                         # 所有配置都放这里，样例见 .env.example
    environment:
      TZ: Asia/Shanghai              # 其余变量不必重复写，.env 里都覆盖了
    volumes:
      - ./data/workspace:/workspace        # agent 工作目录
      - ./data/pi:/root/.pi                # 登录态/模型/会话（务必持久化）
      - ./data/ssh:/etc/ssh/keys           # SSH 主机密钥
      - ./data/gh:/root/.config/gh         # gh 登录态
    working_dir: /workspace
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
```

```bash
mkdir -p data/{workspace,pi,ssh,gh}
cp .env.example .env && $EDITOR .env     # 至少填 PI_RELAY_BASE_URL/API_KEY、FEISHU_APP_ID/SECRET、SSH_PASSWORD
docker compose up -d
docker logs -f pi-agent                  # 看到「飞书桥接已启动」就成了
```

几点说明：

- **不需要写 `command`**，镜像入口已经带好 SSH、模型同步、飞书守护和启动摘要。
- **`.env` 就是全部配置**：要改模型、换飞书包版本、调桥接策略都改它，改完 `docker compose up -d` 重建容器即可生效。
- 想自己构建（改镜像、试新版本）：把上面的 `image:` 换成 `build:` 段，然后 `docker compose up -d --build`：

```yaml
    build:
      context: .
      args:
        PI_VERSION: ${PI_VERSION:-latest}
        PI_REMOTE_FEISHU_VERSION: ${PI_REMOTE_FEISHU_VERSION:-latest}
        PI_STRICT_LOCK: ${PI_STRICT_LOCK:-0}
```

  仓库根目录那份 `docker-compose.yml` 就是这种写法，可直接用。
- 端口只映射 SSH 一个；飞书走 WebSocket 长连接，不需要任何入站端口。
- 数据全在 `./data/`，删容器不影响登录态和会话；`data/pi` 里是 `auth.json`/`models.json`，注意权限别外泄。

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

查找顺序是 `<工作目录>/.pi/feishu.json` → `~/.pi/agent/feishu.json`：想用完全手写的配置，
挂一个文件到 `/workspace/.pi/feishu.json` 即可，它优先级最高。

查找顺序是 `<工作目录>/.pi/feishu.json` → `~/.pi/agent/feishu.json`：想用完全手写的配置，
挂一个文件到 `/workspace/.pi/feishu.json` 即可，它优先级最高。

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
| `PI_RELAY_MODELS` / `PI_RELAY_MODEL_FILTER` | 手写清单 / 只保留匹配项（支持 `*`） |
| `PI_RELAY_EXCLUDE` | 排除项，默认滤掉 embedding / tts / rerank / 画图模型；设空字符串关闭 |
| `PI_RELAY_DEFAULT_MODEL` | 默认模型 id，写进 `settings.json` |
| `PI_RELAY_CONTEXT_WINDOW` / `PI_RELAY_MAX_TOKENS` | 模型元数据，默认 128000 / 16384 |
| `PI_RELAY_VISION` | `1` 表示模型支持图片输入 |
| `PI_RELAY_COST_*` | 计价（USD/百万 token），只影响用量估算 |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` / `DEEPSEEK_API_KEY` / `OPENROUTER_API_KEY` | 官方直连凭据 |

### 飞书

| 变量 | 说明 |
| --- | --- |
| `FEISHU_ENABLED` | `1`（默认启用）\| `auto`（有凭证才启动）\| `0` 关闭 |
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
| `FEISHU_ALLOWED_OUTPUT_DIRS` | `send_file_to_chat` 允许的目录（逗号分隔），默认只有工作目录 |
| `FEISHU_IDLE_TTL_MIN` | 会话空闲回收时间（分钟），默认 30 |
| `FEISHU_SHOW_TOOL_EVENTS` / `FEISHU_SHOW_THINKING` | 是否显示工具事件 / 思考内容（`quote`/`plain`/`hide`） |
| `FEISHU_RESTART_LIMIT` | 连续异常退出的重启上限，`0`（默认）不限次数，退避 15s→300s 封顶 |
| `FEISHU_PREFLIGHT` | `1` 时启动前额外自检凭证，只打日志、不阻止启动（默认为 `0`） |

### SSH / 运行

| 变量 | 说明 |
| --- | --- |
| `SSH_PASSWORD` | root 的 SSH 密码；留空则不设密码 |
| `DEV_PASSWORD` | 可选，`dev` 用户密码（容器默认仍用 root） |
| `SSH_AUTHORIZED_KEYS` | 公钥内容，写入 root 与 dev 的 `authorized_keys` |
| `SSH_PERMIT_ROOT_LOGIN` / `SSH_PASSWORD_AUTH` | 覆盖 sshd 配置，默认 `yes` |
| `SSH_PORT` | compose/run.sh 里宿主映射端口，默认 `2222` |
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
| `DEBIAN_MIRROR` | `https://mirrors.tuna.tsinghua.edu.cn` |
| `NODE_VERSION` | `22.23.3` |
| `PI_VERSION` | `latest` |
| `PI_REMOTE_FEISHU_VERSION` | `latest` |
| `PI_STRICT_LOCK` | `0` 按 `.env` 版本装 / `1` 用仓库里的 `package-lock.json` 严格锁定 |
| `PI_FEISHU_EXTENSION` | `0`（设为 `1` 才把飞书包注册成 Pi 扩展，供 TUI 用） |
| `DEV_UID` / `DEV_GID` | `1000` / `1000` |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` |

基础镜像没有 CA 证书，先用 `http` 装 `ca-certificates` 再切回 `https`，否则 `apt-get update` 会整段被忽略。

默认不注册 Pi 扩展：`serve` 模式自己就带 `send_file_to_chat` 工具，扩展只是给 TUI 多一个 `/feishu` 命令。
需要时用 `--build-arg PI_FEISHU_EXTENSION=1` 打开；打开后装好的 `~/.pi`（约 200MB）会挪到 `/opt/pi-seed`，
首启发现挂载卷为空就自动复制回去。

## 可复现性与升级

`.env` 是唯一输入：构建参数、运行时配置全在里面，同一份 `.env` 换台机器重建就是同一套环境。

两个旋钮，按需要切换：

| 模式 | `.env` 怎么设 | 升级方式 | 适合 |
| --- | --- | --- | --- |
| 跟随最新（默认） | `PI_VERSION=latest` | 改都不用改，`./build.sh` 就是最新 | 想用新功能 |
| 版本钉死 | `PI_VERSION=1.3.0`、`PI_REMOTE_FEISHU_VERSION=0.1.6` | 改成新版本号再 build | 要能回滚 |
| 严格锁定 | 上面钉死 + `PI_STRICT_LOCK=1` | `./update-deps.sh 1.4.0 0.1.7` | 依赖树逐层固定，团队/CI 一致 |

基础镜像默认钉在 `debian:trixie-slim@sha256:a29215f6…`；想跟随 apt 侧更新，把 `.env` 里 `@sha256:` 后面那段删掉即可。

**这套镜像到底装了什么**，随时可查（启动日志第一屏也会打印）：

```bash
docker run --rm --entrypoint cat debian-pi-agent:latest /etc/pi-image-manifest.json
# {"base":"trixie-slim@sha256:a29215…","node":"22.23.3","piRequested":"latest",
#  "pi":"1.3.0","feishuBridge":"0.1.6","strictLock":0,"depsHash":"7e473d9773c3c21e"}
```

`depsHash` 是整棵依赖树的哈希（归一化成 `包名@版本` 列表后取 sha256，与路径无关）：
**同架构**下两台机器构建哈希一样，就说明装的东西完全一致（arm64 与 amd64 会不同，因为原生可选依赖不一样）。
完整依赖清单在镜像内 `/etc/pi-deps-tree.txt`，可直接 diff。用精确版本构建时，`./build.sh` 还会额外打个
`debian-pi-agent:1.3.0-0.1.6` 的别名 tag，回滚就 `docker compose` 里改 `IMAGE_TAG`。

运行期还有一处会随时间变的：中转站的模型列表。要连这个也固定，写死清单即可：

```ini
PI_RELAY_SYNC=0
PI_RELAY_MODELS=gpt-5.1,claude-sonnet-4-5
```

## 数据持久化

compose 映射到 `./data/`：`workspace/` → `/workspace`、`ssh/` → `/etc/ssh/keys`（主机密钥）、
`pi/` → `/root/.pi`（登录态、会话、飞书会话映射 `feishu/sessions.json`）、`gh/` → `/root/.config/gh`。
`/var/log` 用命名卷 `pi-log`。

## 排障

```bash
docker logs pi-agent                                    # 启动摘要 + 桥接日志
docker exec -it pi-agent feishu-check                   # 凭证/机器人/进程/日志 一屏自检
docker exec -it pi-agent pi-remote-feishu doctor --cwd /workspace
docker exec -it pi-agent pi --list-models               # 看 relay 是否同步到
docker exec -it pi-agent pi-remote-feishu send-test --chat-id oc_xxx --text hello
```

- `Missing Feishu appId`：凭证没传进容器，或 `FEISHU_ENABLED=0`。
- `could not resolve bot identity ... 400`：凭证错 / 应用未发布 / 机器人能力没开。
- 收不到消息：事件订阅没选「长连接」或没订阅 `im.message.receive_v1`；先看 `docker logs pi-agent` 里桥接是否在重启。
- 卡片按钮无反应：没订阅 `card.action.trigger`，或改权限后没重新发布版本。
- 模型报未配置：看 `docker exec pi-agent pi --list-models`，空的话检查 `PI_RELAY_*` 或 API key。

## 给 AI / 自动化看的说明

仓库根目录的 [AGENTS.md](AGENTS.md) 是机器可读版：结构、不变量、环境变量消费方、踩过的坑、无 docker 时的验证方法。
