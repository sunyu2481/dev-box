# dev-box

`dev-box` 是一个多架构开发容器镜像，通过 GitHub Actions 构建并发布到 GitHub Container Registry（GHCR）。

## 功能特性

- 基于 Ubuntu 24.04
- Node.js（构建时自动取最新 LTS）/ pnpm
- Python / uv
- Go 1.26
- Java 21 / Maven 3.9 / Gradle 9
- Git / Git LFS / GitHub CLI (`gh`)
- 浏览器自动化客户端：Playwright 库与 `chrome-devtools-mcp`（**不含浏览器二进制**，浏览器由 ChromiumManager 容器经 CDP 提供，见下文）
- 支持 CJK、emoji 和常见网页渲染场景的浏览器字体
- 常用开发工具
- 内置 OpenSSH 服务，支持外部直接 SSH 连入容器（仅公钥认证）
- AI CLI 工具：
  - Claude Code
  - OpenAI Codex CLI
  - Hermes agent gateway（预装 Telegram adapter；镜像仅保留 gateway 运行时，不含桌面/TUI/Web UI 与浏览器工具链）

> 镜像**不预装 Docker CLI / Buildx / Compose**。如需在容器内操作宿主机 Docker，请自行安装客户端并挂载 `/var/run/docker.sock`。

## 镜像

```bash
docker pull ghcr.io/sunyu2481/dev-box:latest
```

## 发布与刷新预装工具

GitHub Actions 会在推送到 `main`、推送 `v*` 标签或手动触发 workflow 时构建并推送镜像。workflow 默认使用 Docker layer cache，因此未修改 `Dockerfile` 时，手动触发可能会快速命中缓存，不会重新安装 Claude Code、Codex、Playwright、chrome-devtools-mcp 这类默认安装 latest 的工具。

手动运行 workflow 时：

- 只想刷新 Codex 等未固定版本的全局 CLI，勾选 `refresh_volatile_tools`。
- 需要完整绕过所有 Docker 构建缓存，勾选 `no_cache`。

## 使用方式

### 使用 Docker Compose 启动

仓库提供了默认的 `docker-compose.yml`，会直接使用 `ghcr.io/sunyu2481/dev-box:latest`，并做以下挂载：

- `./workspace` 挂载到容器内的 `/workspace`
- `./.vscode` 挂载到容器内的 `/home/vscode`，用于保留 shell 配置、工具缓存、Maven/Gradle/Go 缓存等用户数据

启动容器：

```bash
docker compose up -d
```

容器启动时会在后台尝试启动 Hermes gateway；如果启动失败，会最多尝试 3 次，之后容器仍保持运行。Hermes gateway 已预装 `python-telegram-bot`，可加载 Telegram adapter。

进入容器：

```bash
docker compose exec dev-box bash
```

停止并删除容器：

```bash
docker compose down
```

`docker compose down` 不会删除绑定挂载目录，因此 `./workspace` 和 `./.vscode` 下的数据会保留下来。

### 使用 docker run 启动

也可以直接启动交互式 shell：

```bash
docker run --rm -it ghcr.io/sunyu2481/dev-box:latest bash
```

### 通过 SSH 连入容器

镜像内置 OpenSSH 服务，出于安全考虑**只启用公钥认证**，密码与 root 登录均已禁用。

容器 sshd 默认只绑定到宿主机 `127.0.0.1:2222`，**不暴露公网**。推荐经宿主机 SSH 跳转连入：公网只需开放宿主机自身的 22 端口，一个端口同时满足连宿主机和连容器两种需求。

sshd 仅在检测到已授权公钥时才启动。公钥可通过以下任一方式提供（任选其一）：

- **环境变量**：启动时设置 `SSH_PUBLIC_KEY`；
- **挂载公钥文件**：把 `id_ed25519.pub` 等公钥文件放到宿主机 `./.vscode/.ssh/`（对应容器内 `~/.ssh`），启动时会自动合并该目录下所有 `*.pub`；
- **挂载 authorized_keys**：直接编辑/挂载 `./.vscode/.ssh/authorized_keys`。

方式一，使用 Docker Compose 注入环境变量：

```bash
SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d
```

方式二，把公钥文件丢进挂载目录（无需环境变量）：

```bash
mkdir -p ./.vscode/.ssh
cp ~/.ssh/id_ed25519.pub ./.vscode/.ssh/
docker compose up -d
```

#### 经宿主机跳转连入（推荐，只需开放一个公网端口）

在**客户端**（你的笔记本）执行，`-J` 让 SSH 先连宿主机、再从宿主机连容器：

```bash
ssh -J <宿主机用户>@<宿主机地址> -p 2222 vscode@127.0.0.1
```

`127.0.0.1` 是在宿主机视角解析的，即宿主机上映射到容器的 loopback 端口。

写进客户端 `~/.ssh/config` 后可直接 `ssh dev-box`：

```
Host myhost
    HostName <宿主机地址>
    User <宿主机用户>

Host dev-box
    HostName 127.0.0.1
    Port 2222
    User vscode
    ProxyJump myhost
    # 127.0.0.1:2222 是个很容易撞车的 known_hosts 键（任何本地端口转发都可能占用）。
    # HostKeyAlias 让该容器的 host key 单独记账，避免与其他主机相互报指纹变更。
    HostKeyAlias dev-box-container
```

跳转要求宿主机 sshd 开启 `AllowTcpForwarding yes`（OpenSSH 默认已开启）。这样公网暴露面只有宿主机 22 端口一个，容器 sshd 完全不对外可见。

> 网络较卡时，可在客户端 `~/.ssh/config` 中为上述 Host 加 `ControlMaster auto`、`ControlPersist 10m` 复用连接，省掉每次重连的握手开销。

#### 直接暴露容器端口（可选，不推荐）

确需绕过跳转时，显式覆盖绑定地址：

```bash
DEVBOX_SSH_BIND=0.0.0.0 SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d
```

`docker run` 同理（注意 `-p` 左侧的绑定地址）：

```bash
docker run -d \
  -p 127.0.0.1:2222:22 \
  -e SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  ghcr.io/sunyu2481/dev-box:latest
```

host key 持久化在容器内 `/home/vscode/.ssh/host_keys` 下，借助命名卷/绑定挂载保留，重建容器后 SSH 指纹保持不变，不会触发客户端的 `REMOTE HOST IDENTIFICATION HAS CHANGED` 警告。

> SSH 服务以 root 权限通过 `vscode` 用户的 `sudo` 启动；将端口暴露到公网前，请确认注入的是受信任的公钥。

### 浏览器：接入 ChromiumManager

镜像**不预装浏览器二进制**。浏览器由独立的 [ChromiumManager](https://github.com/sunyu2481/chromium-manager) 容器提供，dev-box 里的 agent（Claude Code、Codex）与脚本经其 CDP 网关连接远程实例。这样做的收益：镜像少约 1 GB，且拿到的是带指纹伪装、代理与持久化 Cookie 的有头浏览器，比本地 headless Chromium 更接近真实环境。

镜像内保留的是纯客户端：`playwright` npm 包（供 `connectOverCDP`）与 `chrome-devtools-mcp`（供 agent 用 MCP 操作浏览器）。

#### 前置：两个容器同网

ChromiumManager 的 agent 面默认监听 `10102`，**不要** publish 到宿主机（默认无鉴权），只需同网可达。组网步骤见 `docker-compose.yml` 末尾的 networks 注释。若 ChromiumManager 设了 `AGENT_TOKEN`，dev-box 侧同步设 `CHROMIUM_MANAGER_TOKEN`。

> `CHROMIUM_MANAGER_URL` 由 compose 注入容器 ENV，但容器 ENV 只被 PID 1 的后代继承——**SSH 登入的会话不在这条链上**（sshd 经 `sudo` 启动，sudoers 的 `env_reset` 会清掉自定义变量）。启动脚本因此把这些变量写入 `/etc/environment`，靠 sshd 的 `UsePAM yes` + `pam_env` 注入 SSH 会话。若你在 SSH 会话里发现该变量为空（表现为 `curl` 返回 HTTP 000），先确认容器是否为新版镜像。

#### 取得一个浏览器实例

先在 ChromiumManager 的 Web UI（`https://<host>:3001`）里建好 profile，然后按名字取用——未运行会自动拉起并等 CDP 就绪：

```bash
curl -s -X POST "$CHROMIUM_MANAGER_URL/agent/acquire" \
  ${CHROMIUM_MANAGER_TOKEN:+-H "Authorization: Bearer $CHROMIUM_MANAGER_TOKEN"} \
  -H 'Content-Type: application/json' \
  -d '{"name":"HK-01"}'
# {"code":200,"data":{"id":"Xk3mP9qR","cdpUrl":"http://chromium-manager:10102/cdp/Xk3mP9qR","started":true}}
```

响应里的 `cdpUrl` 就是下面各处要用的地址。`GET /agent/browsers` 可列出全部 profile 与其运行状态。

#### 给 Claude Code / Codex 用（MCP）

profile ID 由 ChromiumManager 在创建时生成，无法预置进镜像，因此 MCP 需在取得实例后注册。

**必须用 `--wsEndpoint`，不能用 `--browser-url`。** `chrome-devtools-mcp` 内部以 `new URL('/json/version', browserURL)` 推导端点，第一个参数是绝对路径，会替换掉 base 的整个 path——`/cdp/<id>` 前缀被丢弃，请求打到网关根路径直接 404。这是 puppeteer 的固有行为，任何带路径前缀的 CDP 网关都受影响。`--wsEndpoint` 跳过这段拼接，而 ChromiumManager 的 `/json/version` 已把 `webSocketDebuggerUrl` 重写为带前缀的形式，可直接取用：

```bash
CDP=http://chromium-manager:10102/cdp/Xk3mP9qR
WS=$(curl -s "$CDP/json/version" | jq -r .webSocketDebuggerUrl)

# Claude Code（--scope user 让全部项目可用）
claude mcp add --scope user chrome -- chrome-devtools-mcp --wsEndpoint "$WS"

# Codex
codex mcp add chrome -- chrome-devtools-mcp --wsEndpoint "$WS"
```

ws 地址含浏览器会话 ID（`/devtools/browser/<uuid>`），**浏览器重启后会变**，需重新取值并重新注册；profile ID 本身则是稳定的。

#### 给脚本用（Playwright）

```js
const { chromium } = require('playwright')
const browser = await chromium.connectOverCDP('http://chromium-manager:10102/cdp/Xk3mP9qR')
const page = await browser.contexts()[0].newPage()   // contexts()[0] 带完整 Cookie 与指纹
await page.goto('https://example.com')
```

用完后释放（`{"stop":true}` 会一并关闭浏览器）：

```bash
curl -s -X POST "$CHROMIUM_MANAGER_URL/agent/release" \
  -H 'Content-Type: application/json' -d '{"id":"Xk3mP9qR"}'
```

#### 陷阱：localhost 不再是同一台机器

远程浏览器跑在 ChromiumManager 容器里，它的 `localhost` 是它自己。让它打开 dev-box 里起的开发服务器时：

- 开发服务器必须监听 `0.0.0.0`，而非默认的 `127.0.0.1`（Vite 用 `--host`）
- URL 用 `http://dev-box:3000`，而非 `http://localhost:3000`

#### 仍需要本地浏览器时

`playwright test` 走的是 Playwright 自己的 server 协议而非 CDP，`connectOverCDP` 接不进去；`playwright screenshot` / `codegen` 等 CLI 子命令也只会启动本地浏览器。这类场景现装即可（系统依赖库已随镜像装好，无需 sudo）：

```bash
playwright install chromium
```

装到 `$PLAYWRIGHT_BROWSERS_PATH`（`/home/vscode/.cache/ms-playwright`），位于持久化的 home 下，重建容器不必重装。

### 日志

容器内所有子系统的日志统一汇聚到主进程 stdout，因此 `docker logs` 一处即可看全。每行带时间戳与来源标签：

```
2026-07-27T11:36:02+0800 [init]    初始化完成，容器进入常驻状态
2026-07-27T11:36:02+0800 [sshd]    Invalid user baduser from 203.0.113.9 port 56542
2026-07-27T11:36:05+0800 [gateway] ...
```

| 标签 | 来源 |
| --- | --- |
| `[init]` | 启动脚本自身：各服务启停、健康告警 |
| `[sshd]` | OpenSSH 服务：连接、认证成功/失败、来源 IP 与公钥指纹 |
| `[gateway]` | Hermes gateway |

查看方式：

```bash
docker compose logs -f                       # 全部
docker compose logs -f | grep '\[sshd\]'      # 只看 SSH
docker compose logs | grep -E 'Invalid user|Failed publickey'   # 只看认证失败
```

实现上有两点是必需的，改动前请留意：

- sshd 以 `-D -e` 启动。不带 `-D` 会自我 daemonize 并把 stdio 重定向到 `/dev/null`；不带 `-e` 则日志写向 syslog，而容器内没有 syslog 守护进程接收 —— 两者任缺其一，SSH 日志都会**完全消失**，这正是此前爆破无从发现的原因。
- `LogLevel VERBOSE`（`sshd_config_devbox`）。`INFO` 不记录公钥指纹，`VERBOSE` 才会输出 `Failed publickey for ... SHA256:xxx`，足以识别攻击源。`DEBUG` 过于嘈杂，不建议。

#### 健康汇报

启动脚本常驻后每 5 分钟检查一次，仅在有异常时输出，正常情况下静默：

```
2026-07-27T11:45:42+0800 [init] SSH 认证失败 37 次（最近 300s，累计 37 次）；若非本人操作则为爆破尝试，详见 [sshd] 日志中的来源 IP
2026-07-27T11:50:42+0800 [init] 警告：检测到 12 个僵尸进程（正常应为 0，说明 PID 1 未回收子进程）
2026-07-27T11:55:42+0800 [init] 警告：sshd 进程已退出，SSH 将无法连入
```

汇报间隔由 `HEALTH_REPORT_INTERVAL` 控制（秒，设为 `0` 关闭）：

```yaml
environment:
  - HEALTH_REPORT_INTERVAL=60
```

### 抗爆破与僵尸进程回收

SSH 端口一旦对公网开放，就会被扫描器持续爆破。密码认证已禁用，攻击无法得手，但每条未认证连接都会派生一个 sshd 子进程，因此镜像做了两层处理：

- **限流**（`sshd_config_devbox`，按单人使用调优）：`LoginGraceTime 15` 缩短挂起连接存活时间，`MaxAuthTries 3` 限制单连接认证次数，`MaxStartups 4:100:10` 未认证连接超过 4 条后即 100% 拒绝新连接、硬上限 10 条，`PerSourceMaxStartups 4` 限制单一来源 IP，`MaxSessions 4` 限制单连接内的复用会话数，`AllowUsers vscode` 让其他用户名在进入 PAM 前即被拒绝。
- **进程回收**：镜像 `ENTRYPOINT` 为 `tini -s -g --`，作为 PID 1 回收孤儿进程。这是必需的 —— 被 reparent 到 PID 1 的 sshd pre-auth 子进程退出后，若 PID 1 不调用 `wait()` 就会堆积成僵尸进程（`Z` 状态）直至耗尽 PID。历史实现曾让不调用 `wait()` 的 `sleep infinity` 充当 PID 1，正是僵尸堆积的成因；现在启动脚本以健康汇报循环常驻，且回收职责统一交给 tini。`-s` 让 tini 即便被 `docker run --init` 包装成非 PID 1 也仍能收养孤儿。

> 上述限流值面向单人使用。若多人共享同一出口 IP（NAT），`PerSourceMaxStartups 4` 与 `MaxStartups` 可能误伤，需相应放宽。

排查僵尸进程堆积：

```bash
# 查看 PID 1 是否为 tini（应输出 tini，而非 sleep）
docker compose exec dev-box ps -o comm= -p 1
# 统计僵尸进程
docker compose exec dev-box bash -lc "ps -eo stat= | grep -c '^Z'"
```

僵尸进程无法单独 kill，只能由父进程回收。若在旧版镜像上已经堆积，重建容器即可清除：

```bash
docker compose up -d --force-recreate
```

当前基础镜像的 OpenSSH 为 9.6p1，尚不支持 9.8+ 的 `PerSourcePenalties`（自动封禁反复失败的来源）。限流只能减轻爆破影响、不能阻止爆破，因此优先使用上文的跳转方案，不要把容器端口直接开到公网。
