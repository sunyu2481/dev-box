# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在本仓库中处理代码时提供项目指引。

## 项目概览

本仓库定义了 `dev-box`，这是一个发布到 GitHub Container Registry 的多架构开发容器镜像。仓库刻意保持精简：`Dockerfile` 是镜像内容的事实来源，`.github/workflows/docker.yml` 负责构建和发布镜像。

## 常用命令

- 为当前平台在本地构建镜像：
  ```bash
  docker build -t dev-box:local .
  ```
- 使用显式工具链版本构建镜像：
  ```bash
  docker build \
    --build-arg NODE_VERSION=24.16.0 \
    --build-arg PNPM_VERSION=11.5.0 \
    --build-arg GO_VERSION=1.26.3 \
    --build-arg MAVEN_VERSION=3.9.16 \
    --build-arg GRADLE_VERSION=9.5.1 \
    -t dev-box:local .
  ```
- 在已构建镜像中启动交互式 shell：
  ```bash
  docker run --rm -it dev-box:local bash
  ```
- 使用默认 Docker Compose 文件启动已发布镜像：
  ```bash
  docker compose up -d
  docker compose exec dev-box bash
  docker compose down
  ```
- 在镜像内验证主要工具链：
  ```bash
  docker run --rm dev-box:local bash -lc 'node --version && pnpm --version && playwright --version && command -v chrome-devtools-mcp && python --version && uv --version && go version && java -version && mvn --version && gradle --version && gh --version'
  ```
- 验证浏览器客户端链路（镜像不预装浏览器二进制，故只验证客户端与远程 CDP 连通性）：
  ```bash
  # 需与 chromium-manager 同网；先取一个实例，再验证 Playwright 能连上
  docker run --rm --network agentnet dev-box:local bash -lc '
    CDP=$(curl -s -X POST http://chromium-manager:10102/agent/acquire \
      -H "Content-Type: application/json" -d "{\"name\":\"HK-01\"}" | jq -r .data.cdpUrl)
    node -e "require(\"playwright\").chromium.connectOverCDP(\"$CDP\").then(b=>b.close()).then(()=>console.log(\"CDP OK\"))"'
  ```
- 构建与 CI 相同的平台但不推送镜像：
  ```bash
  docker buildx build --platform linux/amd64,linux/arm64 -t dev-box:local .
  ```

## 测试和 lint

本仓库没有配置语言特定的测试套件或 linter。修改 `Dockerfile` 后，优先使用 `docker build -t dev-box:local .` 作为主要验证方式；如果修改了浏览器相关层，再运行上文的 CDP 连通性检查（镜像已无本地浏览器，`playwright screenshot` 之类的本地启动命令不再适用）。本仓库没有单测试命令。

## 架构说明

- `Dockerfile` 基于 `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`，并使用 `TARGETPLATFORM`、`TARGETOS` 和 `TARGETARCH` 支持多架构构建。
- 工具版本由 Docker build args 控制：`PNPM_VERSION`、`GO_VERSION`、`MAVEN_VERSION` 和 `GRADLE_VERSION`。更新版本时优先修改这些默认值，不要在其他位置硬编码版本。`NODE_VERSION` 语义特殊：Node.js 构建时**自动从 `nodejs.org/dist/index.json` 取最新 LTS 版本**安装，`NODE_VERSION` 仅作为无法访问该 index 时的 fallback，建议保持为当前已知最新 LTS（回退命中历史坏区间版本会导致构建失败，见下文）。
- 系统包会安装常用开发工具、Python、Java 21、Git LFS、浏览器字体以及网络/调试工具。
- GitHub CLI（`gh`）通过 GitHub CLI 官方 apt 源安装。
- OpenSSH 服务（`openssh-server`）随镜像安装，配置文件为 `/etc/ssh/sshd_config_devbox`（独立配置，仅公钥认证、禁用密码与 root 登录、`UsePAM yes`）。`UsePAM yes` 是必需的：vscode 账户密码字段被锁定（`!`），若 `UsePAM no` 则 sshd 会因"账户锁定"拒绝包括公钥在内的所有认证。镜像构建时删除 apt 固化生成的 `/etc/ssh/ssh_host_*`；host key 在容器首次启动时由 `start-with-gateway` 生成并持久化到 `/home/vscode/.ssh/host_keys`。公钥可通过环境变量 `SSH_PUBLIC_KEY`、挂载到 `~/.ssh` 下的任意 `*.pub` 文件、或直接放置 `~/.ssh/authorized_keys` 三种方式提供，启动脚本会去重合并到 vscode 用户的 `authorized_keys`；无授权公钥时不启动 sshd。sshd 由 vscode 用户经 `sudo` 以 root 启动。
- `sshd_config_devbox` 含抗爆破限流，**按单人使用调优**：`AllowUsers vscode`、`LoginGraceTime 15`、`MaxAuthTries 3`、`MaxStartups 4:100:10`、`PerSourceMaxStartups 4`、`PerSourceNetBlockSize 32:128`、`MaxSessions 4`。这些参数限制未认证（pre-auth）sshd 子进程的并发数与存活时长——端口暴露公网时扫描器会持续发起连接，每条连接对应一个子进程。两处下限不要再收紧：`MaxAuthTries` 降到 2 会在客户端本地私钥较多时误伤（ssh-agent 逐个试密钥，正确的可能排在第 3 位之后）；`PerSourceMaxStartups` 低于 4 会误伤 VS Code Remote-SSH 等并发建连的工具。若改为多人共享出口 IP（NAT）使用，需放宽 `PerSourceMaxStartups` 与 `MaxStartups`。当前基础镜像的 OpenSSH 为 9.6p1，尚不支持 9.8+ 的 `PerSourcePenalties`；升级基础镜像后可考虑增补。
- **PID 1 必须能回收孤儿进程**：镜像 `ENTRYPOINT` 为 `/usr/bin/tini -s -g --`（`tini` 由 apt 安装）。sshd 的 pre-auth 子进程遭遇扫描时会被 reparent 到 PID 1，若 PID 1 不调用 `wait()`（如历史实现里作为 PID 1 的 `sleep infinity`），这些进程退出后会永久堆积为僵尸（`Z` 状态）直至耗尽 PID。`-s` 启用 `PR_SET_CHILD_SUBREAPER`，使 tini 即便被 `docker run --init` / compose `init: true` 包装成非 PID 1 也仍能收养孤儿；`-g` 让信号投递到整个进程组。不要移除该 `ENTRYPOINT`，也不要在运行时用 `--entrypoint` 直接覆盖为启动脚本本身。
- **统一日志汇聚**：`start-with-gateway` 把各子系统输出汇聚到自身 stdout，每行加 `<ISO8601 时间戳> [来源]` 前缀（`[init]` / `[sshd]` / `[gateway]`），因此 `docker logs` 一处看全并可按标签过滤。关键实现约束：
  - sshd 必须以 `-D -e` 启动。缺 `-D` 会自我 daemonize 并把 stdio 重定向到 `/dev/null`；缺 `-e` 则日志写向 syslog，而容器内无 syslog 守护进程接收。任缺其一，SSH 日志完全消失（这是此前爆破无从发现的直接原因）。
  - 配合 `sshd_config_devbox` 的 `LogLevel VERBOSE`：`INFO` 不记录公钥指纹，`VERBOSE` 才输出 `Failed publickey ... SHA256:xxx`。
  - 服务用进程替换 `> >(tag_stream ...)` 而非管道 `| tag_stream`。管道下 `$!` 指向 `tag_stream` 而非服务本身，服务崩溃后只要仍有子进程持有写端，`kill -0` 就会把已死服务误判为健康。同理 `sshd -t` 自检不能接管道，否则退出码被 `tag_stream` 的 0 掩盖。
  - gateway 用 `stdbuf -oL -eL` 强制行缓冲（Python 进程 stdout 非 tty 时默认块缓冲，日志会延迟数 KB 才出现），并加 `-v` 把级别提到 INFO。gateway 自有文件日志在 `$HERMES_HOME/logs/`，内容与 stderr 重叠，故不 tail 进 stdout 以免双份记录。
- 脚本末尾不再是 `exec sleep infinity`，而是周期健康汇报循环（间隔由 `HEALTH_REPORT_INTERVAL` 控制，秒；`0` 关闭）。仅在异常时输出：sshd/gateway 进程消失、僵尸进程数变化、SSH 认证失败增量。认证失败计数由 `tag_stream_sshd` 累计到 `$TMPDIR/.devbox-sshd-authfail`（用文件而非变量，因为该函数运行在进程替换的子 shell 中，变量无法回传）；计数模式已去重，只匹配 `Invalid user` / `not allowed because` / `Failed publickey`，避免同一次失败连接的多行日志重复计数。此处不能用 `exec`：虽然进程替换的 FD 会被继承（日志不断流），但 shell 被替换掉后就没有进程做汇报了。
- 镜像不预装 Docker CLI / Buildx / Compose；如需在容器内操作宿主机 Docker，请自行安装客户端并挂载 socket。
- 默认 `docker-compose.yml` 使用已发布镜像 `ghcr.io/sunyu2481/dev-box:latest`，挂载当前目录到 `/workspace`，用绑定挂载持久化 `/home/vscode`。默认 `CMD` 为 `/usr/local/bin/start-with-gateway`（依次启动 sshd 与 Hermes gateway，最后进入健康汇报循环常驻），由上述 tini `ENTRYPOINT` 拉起，不要在 Compose 中覆盖二者。Compose 的 SSH 端口映射为 `${DEVBOX_SSH_BIND:-127.0.0.1}:${DEVBOX_SSH_PORT:-2222}:22`——**默认只绑宿主机 loopback，不暴露公网**，推荐经宿主机 SSH 跳转（`ssh -J` / `ProxyJump`）连入容器，这样公网只需开放宿主机自身的 22 端口。要直接暴露需显式设 `DEVBOX_SSH_BIND=0.0.0.0`。改动此默认绑定地址等于扩大公网暴露面，需先确认。Compose 同时透传 `SSH_PUBLIC_KEY` 环境变量。
- Maven 和 Gradle 从官方二进制发行包安装到 `/opt/maven` 和 `/opt/gradle`。
- Node.js 和 Go 从上游发布归档安装，并通过 `TARGETARCH` 做架构映射。如果增加架构支持，需要同步更新这些 `case` 映射。Node.js 安装层会先查 `nodejs.org/dist/index.json` 取最新 LTS 版本号，查不到则回退到 `NODE_VERSION` 构建参数（见架构说明第一条）。历史上 Hermes `install.sh` 会因 Node 自带 npm 落入 11.10–11.16 坏区间（无法 honor 某些 `.npmrc` 选项）而改自装 Node 并用 `ln -sf` 覆盖 `/usr/local/bin/{node,npm,npx}`，随后镜像清理删除 `${HERMES_HOME}/node` 导致这些符号链接变成死链、后续 `npm install -g` 报 `npm: command not found`。自动取最新 LTS 且 fallback 亦避开坏区间即可规避此问题。
- `uv` 通过 Astral 安装脚本安装，并与 `uvx` 一起复制到 `/usr/local/bin`。
- 全局 AI CLI 中，Claude Code 和 OpenAI Codex CLI 通过 npm 包参数安装。
- Hermes 通过官方 `install.sh`（`--skip-setup --skip-browser --non-interactive`）安装到 `/usr/local/lib/hermes-agent`，并额外 `uv pip install python-telegram-bot`。安装后删除 gateway 非必需内容（`node_modules`、`apps`/`website`/`web`/`ui-tui`/`tests`/`.git` 等），仅保留 Python venv 与 editable 源码树供 `hermes gateway` 使用。
- **镜像不预装浏览器二进制**，浏览器由独立的 ChromiumManager 容器提供，agent 与脚本经其 CDP 网关（默认 `10102`，同 Docker 网络内可达，不 publish 到宿主机）连接远程实例。镜像内只保留客户端：`playwright` npm 包（供 `chromium.connectOverCDP()`）与 `chrome-devtools-mcp`（Claude Code / Codex 的浏览器 MCP，`--browser-url` 指向 CDP 地址）。相关约束：
  - 安装层执行的是 `playwright install-deps chromium` 而非 `playwright install --with-deps chromium`——**只装运行期系统库（libgtk-3/libnss3 等，数十 MB），不下载浏览器**。保留这些库是为了让"确需本地浏览器时"退化成一条免 sudo 的 `playwright install chromium`；删掉它们会省不了多少体积，却让现装必须 root + 联网 apt。
  - `PLAYWRIGHT_BROWSERS_PATH` 指向 `/home/vscode/.cache/ms-playwright`（原为 `/ms-playwright`）。改到 home 下是为了让现装的浏览器落进 compose 的绑定挂载，重建容器不必重装。
  - `chrome-devtools-mcp` 依赖全部 bundled，安装不会触发浏览器下载；不要为它补 `puppeteer`（那个包会拉浏览器）。
  - profile ID 由 ChromiumManager 创建时生成，**无法预置进镜像**，因此 MCP 只能在运行期取得实例后注册，不要试图在 Dockerfile 里写死 `--browser-url`。
  - 两类场景 CDP 替代不了，属已知取舍：`playwright test`（走 Playwright server 协议而非 CDP，`connectOptions` 接不进来）与 `playwright screenshot`/`codegen` 等只能启动本地浏览器的 CLI 子命令。这两类需先 `playwright install chromium` 现装。
  - 远程浏览器的 `localhost` 是 ChromiumManager 容器自身。让它访问 dev-box 里的开发服务器时，服务须监听 `0.0.0.0`，URL 用 `http://dev-box:<port>`。
- 最终镜像以 `vscode` 用户运行，`WORKDIR` 为 `/workspace`；`/home/vscode` 下的缓存和工具目录（含供现装浏览器用的 `.cache/ms-playwright`）会预先创建并归属给 `vscode`。镜像已不再创建顶层 `/ms-playwright`。
- `.github/workflows/docker.yml` 使用 QEMU 和 Docker Buildx，在推送到 `main`、推送 `v*` tag 以及手动触发 `workflow_dispatch` 时，将 `linux/amd64` 和 `linux/arm64` 镜像发布到 GHCR。
- Docker metadata tag 包括默认分支的 `latest`、分支引用、tag 引用和 `sha-*` tag。

## 变更指引

- 修改已安装工具时，如果影响用户可见的镜像内容，需要同步更新 `README.md`。
- 进行版本升级时，更新对应的 Dockerfile `ARG` 默认值，并通过重新构建验证。
- 修改发布 workflow 前，先检查 `docker/metadata-action` 对分支、tag 和 SHA 构建的 tag 与 label 影响。
