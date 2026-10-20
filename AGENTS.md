# AGENTS.md — 给 AI / 自动化改这个仓库时读

> 本文件是机器可读的仓库说明书。人看的文档在 [README.md](README.md)。
> 改动本仓库前先读完「不变量」和「坑」两节，它们记录的都是踩过的真实故障。

## 一句话定位

把 Debian 13 容器做成一台「Pi Agent 常驻机」：容器内跑 SSH + Pi TUI + 飞书桥接，
人通过飞书（主要）或 SSH（备用）远程开会话、跑任务、审批工具调用。

镜像：`ghcr.io/become-illusory/debian-pi-agent`（amd64 + arm64，CI 自动构建）。

## 目录结构

| 文件 | 作用 | 改动风险 |
| --- | --- | --- |
| `Dockerfile` | 镜像构建：Debian 换源 → Node → Pi/桥接依赖 → dev 用户 → sshd | 高 |
| `entrypoint.sh` | 容器入口：SSH、seed 恢复、中转站同步、飞书桥接守护、启动摘要 | 高 |
| `feishu-config.py` | 环境变量 → `~/.pi/agent/feishu.json`（合并式，保留手工修改） | 中 |
| `relay-sync.py` | 环境变量 → 拉 `{BASE_URL}/models` → `~/.pi/agent/models.json` | 中 |
| `feishu-check.sh` | 凭证/机器人身份/进程/日志 一屏自检，装在镜像里为 `feishu-check` | 低 |
| `docker-compose.yml` | 运行编排；**所有环境变量必须在这里透传** | 高 |
| `run.sh` | 无 compose 时的等价启动（`docker run --env-file .env`） | 中 |
| `build.sh` | 本地构建，读 `.env` 当唯一输入，打完打印装配清单 | 中 |
| `update-deps.sh` | 严格锁模式下升级依赖：更新 `npm/package-lock.json` + 回写 `.env` | 低 |
| `npm/package.json` + `package-lock.json` | 严格锁模式（`PI_STRICT_LOCK=1`）的依赖树 | 中 |
| `.env.example` | **唯一配置入口**的样例，与 README/compose 必须同步 | 高 |
| `sshd-container.conf` | sshd 容器策略 + 主机密钥路径 | 低 |

## 常用命令

```bash
cp .env.example .env && $EDITOR .env      # 填中转站 + 飞书凭证
docker compose up -d                      # 构建并启动
docker logs -f pi-agent                   # 启动摘要 + 桥接日志（tee 自文件）
docker exec -it pi-agent feishu-check     # 一屏自检
docker exec -it pi-agent pi               # TUI
docker run --rm --entrypoint cat debian-pi-agent:latest /etc/pi-image-manifest.json

./build.sh                                # 本地构建（读 .env，打版本别名 tag，打印清单）
./update-deps.sh 1.4.0 0.1.7              # 严格锁模式下升级版本（会同步 .env）
```

## 不变量（改了就是 bug）

1. **`.env` 是唯一输入**。同一个 `.env` 重建必须得到同一套环境；任何新增旋钮都要进 `.env.example` + compose + README。
2. **飞书桥接默认常开**（`FEISHU_ENABLED=1`），且**任何自检都不得阻止它启动**——这是用户异地控制与审批的唯一通道。失败只能重试（退避 15s→300s，`FEISHU_RESTART_LIMIT=0` 表示不限次数）。
3. **工作目录 `/workspace` 与凭据目录 `~/.pi` 必须分离**。`auth.json` / `models.json` 里有 API key，不能让 agent 的工作目录覆盖它。
4. **容器默认 root**；`dev` 用户只在 `DEV_PASSWORD` 非空时启用，不参与默认流程。
5. **依赖版本双模式**：`PI_STRICT_LOCK=0` 按 `.env` 版本装（默认，易升级）；`=1` 用 `npm/package-lock.json` 做 `npm ci`。两者安装目录相同（`/opt/pi-deps`）。
6. **镜像必须自带装配清单** `/etc/pi-image-manifest.json`（含 `pi`/`feishuBridge`/`strictLock`/`depsHash`）与 `/etc/pi-deps-tree.txt`（归一化 `包名@版本` 列表）。
7. 飞书配置文件查找顺序：`<PI_WORKDIR>/.pi/feishu.json` → `~/.pi/agent/feishu.json`。环境变量生成的写后者。

## 环境变量 → 消费方

| 变量组 | 谁读 | 说明 |
| --- | --- | --- |
| `PI_RELAY_*` | `relay-sync.py` | `BASE_URL`/`API_KEY` 触发同步；`apiKey` 写 `$PI_RELAY_API_KEY` 插值，**密钥不落盘** |
| `FEISHU_APP_*`、`FEISHU_ENABLED` | `entrypoint.sh` | 决定桥接是否启动；`auto` = 有凭证才起 |
| `FEISHU_POLICY/渲染/文件` 类 | `feishu-config.py` → `~/.pi/agent/feishu.json` | 只覆盖显式设置过的变量 |
| `SSH_*`、`DEV_*` | `entrypoint.sh` | 密码、公钥、sshd 策略 |
| `PI_WORKDIR`、`PI_VERSION` 等 | `entrypoint.sh` / `build.sh` / `Dockerfile` | 工作目录、组件版本 |

新增一个环境变量必须同步 5 处：消费脚本 → `docker-compose.yml`（`environment`）→ `.env.example` → `README.md` 变量表 → 本文件。

## 坑（以下每条都真实踩过）

- **Dockerfile**：`FROM` 之前声明的 `ARG` 在构建阶段不可见，必须 `FROM` 之后重新 `ARG 名字`；否则 `set -u` 下报 `parameter not set`，CI 才暴露。
- **Dockerfile**：`RUN` 续行里不能写 `# 注释`，续行会被拼进 shell 命令。注释放指令上方。
- **Dockerfile**：`printf` 里要真实换行就写 `"\n"`（`"\\n"` 会输出字面反斜杠）。
- **entrypoint**：`set -e` 下 `var=$(命令)` 若命令非零会直接退出；要写 `var=$(cmd) || rc=$?`。
- **entrypoint**：桥接日志必须 `| tee -a 文件`，只写文件的话 `docker logs` 看不到任何排障信息。
- **entrypoint**：判断桥接存活用 `pgrep -f "pi-remote-feishu serve"`（镜像装了 procps）。
- **entrypoint**：`FEISHU_ENABLED` 默认是 `1` 不是 `auto`；区分「没凭证」与「主动关闭」两种日志。
- **python 脚本**：读环境变量要区分「未设置」与「空字符串」（例如 `PI_RELAY_EXCLUDE=` 表示关闭过滤），用 `os.environ.get()` 判 `None`。
- **compose**：`${VAR:-默认}` 把空值也当未设置；要允许「空值有意义」就用 `${VAR-默认}`（见 `PI_RELAY_EXCLUDE`）。
- **镜像体积**：`PI_FEISHU_EXTENSION=1` 会在 `~/.pi/agent/npm` 额外装一份飞书包（约 +210 MB 磁盘，不占内存）。默认 0；`serve` 模式不需要它。

## 没有 docker 时怎么验证（本仓库开发常用）

```bash
# 拉某架构镜像并按层解包成 rootfs
skopeo copy --override-arch arm64 docker://ghcr.io/become-illusory/debian-pi-agent:latest oci:/tmp/o
# 逐层 tar -xf 到 /tmp/root，然后 chroot /tmp/root /bin/bash

# 注意：chroot 里 mknod 无效（无 /dev/urandom），sshd/ssh-keygen 必须 stub 掉再测其余流程
# 测试范围仍可覆盖：seed 恢复、relay 同步、飞书配置生成、桥接启动、日志 tee、启动摘要
```

本地单元级验证（纯 bash/python，不需要 docker）：

```bash
bash -n entrypoint.sh run.sh build.sh update-deps.sh
python3 -m py_compile feishu-config.py relay-sync.py
# 中转站链路：起一个本地假 /v1/models + /chat/completions，用 pi --print 打一发
# 依赖哈希：npm ls --all --json 归一化成 name@version 再 sha256（同架构可跨机器比对）
```

## 提交约定

- commit message 用中文，前缀 `feat:` / `fix:` / `docs:` / `polish:` / `chore:`。
- 提交者固定 `Become-ILLUSORY <becomeillusory@gmail.com>`。
- 只改文档也要保证 CI 绿；Dockerfile 每次改动都会触发双架构重建（约 1–13 分钟，视缓存）。
- 不要把 `.env`、`data/`、日志提交进仓库（见 `.gitignore` / `.dockerignore`）。
