# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在本仓库中处理代码时提供项目指引。

## 项目概览

本仓库定义了 `dev-box`，这是一个发布到 GitHub Container Registry 的多架构开发容器镜像。仓库刻意保持精简：`Dockerfile` 是镜像内容的事实来源，`.github/workflows/docker.yml` 负责构建和发布镜像。

## 常用命令

- 推送代码后，通过 GitHub Workflow 构建并发布镜像：
  ```bash
  gh workflow run docker.yml --ref main
  gh run list --workflow docker.yml --limit 5
  ```
- 完整刷新系统补丁与工具链：
  ```bash
  gh workflow run docker.yml --ref main -f no_cache=true
  ```
- 在已构建镜像中启动交互式 shell：
  ```bash
  docker run --rm -it ghcr.io/sunyu2481/dev-box:latest bash
  ```
- 使用默认 Docker Compose 文件启动已发布镜像：
  ```bash
  docker compose up -d
  docker compose exec --user vscode dev-box bash
  docker compose down
  ```
- 在镜像内验证主要工具链：
  ```bash
  docker run --rm ghcr.io/sunyu2481/dev-box:latest bash -lc 'node --version && pnpm --version && agy --version && cc-connect --version && playwright --version && command -v chrome-devtools-mcp && python --version && uv --version && go version && java -version && mvn --version && gradle --version && gh --version && docker --version'
  ```
- 验证浏览器客户端链路（镜像不预装浏览器二进制，故只验证客户端与远程 CDP 连通性）：
  ```bash
  # 需与 chromium-manager 同网；先取一个实例，再验证 Playwright 能连上。
  # HK-01 需替换为实际 profile 名（`GET /agent/browsers` 可列出，名字不存在则返回 404）
  docker run --rm --network agentnet ghcr.io/sunyu2481/dev-box:latest bash -lc '
    CDP=$(curl -s -X POST http://chromium-manager:10102/agent/acquire \
      -H "Content-Type: application/json" -d "{\"name\":\"HK-01\"}" | jq -r .data.cdpUrl)
    node -e "require(\"playwright\").chromium.connectOverCDP(\"$CDP\").then(b=>b.close()).then(()=>console.log(\"CDP OK\"))"'
  ```

## 测试和 lint

**禁止在本地构建 Docker 镜像验证。所有镜像构建、构建验证与发布统一通过 GitHub Workflow 执行。镜像仅预装 Docker 客户端，不预装 Buildx、BuildKit 等镜像构建工具或 Compose 插件；工作流运行器可按需使用构建工具。**

本地只执行静态检查，例如 `bash -n start-dev-box.sh`、`node --check tests/docker-smoke.cjs` 与 `git diff --check`。修改 Dockerfile 或工具版本后，推送代码并检查 `.github/workflows/docker.yml` 的构建结果，不得用本地构建代替。

工作流在构建后运行 `tests/cc-connect-smoke.cjs` 和 `tests/docker-smoke.cjs`：在无挂载的临时容器中验证聊天桥接开关、服务退出、日志排空、双项目模拟 OneBot、真实 SSH 登录，以及模拟 Docker 服务的用户组权限与环境保留。测试容器不得挂载实际 home、宿主机目录或真实 Docker 套接字。

## 架构说明

- `Dockerfile` 基于 `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`，并使用 `TARGETPLATFORM`、`TARGETOS` 和 `TARGETARCH` 支持多架构构建。
- 工具版本由 Docker build args 控制：`PNPM_VERSION`、`GO_VERSION`、`MAVEN_VERSION`、`GRADLE_VERSION` 和 `UV_VERSION`。更新版本时优先修改这些默认值，不要在其他位置硬编码版本。`NODE_VERSION` 语义特殊：Node.js 构建时**自动从 `nodejs.org/dist/index.json` 取最新 LTS 版本**安装，`NODE_VERSION` 仅作为无法访问该 index 时的 fallback，建议保持为当前已知最新安全 LTS。
- 系统安装层先运行 `apt-get update` 和 `apt-get upgrade -y`，更新基础镜像中已有软件包的安全修订，再安装常用开发工具、Python、Java 21、Git LFS、浏览器字体以及网络/调试工具。
- GitHub CLI（`gh`）通过 GitHub CLI 官方 apt 源安装。
- OpenSSH 服务（`openssh-server`）随镜像安装，配置文件为 `/etc/ssh/sshd_config_devbox`（独立配置，仅公钥认证、禁用密码与 root 登录、`UsePAM yes`）。`UsePAM yes` 是必需的：vscode 账户密码字段被锁定（`!`），若 `UsePAM no` 则 sshd 会因"账户锁定"拒绝包括公钥在内的所有认证。镜像构建时删除 apt 固化生成的 `/etc/ssh/ssh_host_*`；host key 在容器首次启动时由 `start-dev-box` 生成并持久化到 `/home/vscode/.ssh/host_keys`。公钥可通过环境变量 `SSH_PUBLIC_KEY`、挂载到 `~/.ssh` 下的任意 `*.pub` 文件、或直接放置 `~/.ssh/authorized_keys` 三种方式提供，启动脚本会去重合并到 vscode 用户的 `authorized_keys`；无授权公钥时不启动 sshd。sshd 由 vscode 用户经 `sudo` 以 root 启动。
- `sshd_config_devbox` 含抗爆破限流，**按单人使用调优**：`AllowUsers vscode`、`LoginGraceTime 15`、`MaxAuthTries 3`、`MaxStartups 4:100:10`、`PerSourceMaxStartups 4`、`PerSourceNetBlockSize 32:128`、`MaxSessions 4`。这些参数限制未认证（pre-auth）sshd 子进程的并发数与存活时长——端口暴露公网时扫描器会持续发起连接，每条连接对应一个子进程。两处下限不要再收紧：`MaxAuthTries` 降到 2 会在客户端本地私钥较多时误伤（ssh-agent 逐个试密钥，正确的可能排在第 3 位之后）；`PerSourceMaxStartups` 低于 4 会误伤 VS Code Remote-SSH 等并发建连的工具。若改为多人共享出口 IP（NAT）使用，需放宽 `PerSourceMaxStartups` 与 `MaxStartups`。当前基础镜像的 OpenSSH 为 9.6p1，尚不支持 9.8+ 的 `PerSourcePenalties`；升级基础镜像后可考虑增补。
- **PID 1 必须能回收孤儿进程**：镜像 `ENTRYPOINT` 为 `/usr/bin/tini -s -g --`（`tini` 由 apt 安装）。sshd 的 pre-auth 子进程遭遇扫描时会被 reparent 到 PID 1，若 PID 1 不调用 `wait()`（如历史实现里作为 PID 1 的 `sleep infinity`），这些进程退出后会永久堆积为僵尸（`Z` 状态）直至耗尽 PID。`-s` 启用 `PR_SET_CHILD_SUBREAPER`，使 tini 即便被 `docker run --init` / compose `init: true` 包装成非 PID 1 也仍能收养孤儿；`-g` 让信号投递到整个进程组。不要移除该 `ENTRYPOINT`，也不要在运行时用 `--entrypoint` 直接覆盖为启动脚本本身。
- **统一日志汇聚**：`start-dev-box` 把启动与 SSH 输出汇聚到自身 stdout，每行加 `<ISO8601 时间戳> [来源]` 前缀（`[init]` / `[sshd]`），因此 `docker logs` 一处看全并可按标签过滤。关键实现约束：
  - sshd 必须以 `-D -e` 启动。缺 `-D` 会自我 daemonize 并把 stdio 重定向到 `/dev/null`；缺 `-e` 则日志写向 syslog，而容器内无 syslog 守护进程接收。任缺其一，SSH 日志完全消失（这是此前爆破无从发现的直接原因）。
  - 配合 `sshd_config_devbox` 的 `LogLevel VERBOSE`：`INFO` 不记录公钥指纹，`VERBOSE` 才输出 `Failed publickey ... SHA256:xxx`。
  - 服务用进程替换 `> >(tag_stream ...)` 而非管道 `| tag_stream`。管道下 `$!` 指向 `tag_stream` 而非服务本身，服务崩溃后只要仍有子进程持有写端，`kill -0` 就会把已死服务误判为健康。同理 `sshd -t` 自检不能接管道，否则退出码被 `tag_stream` 的 0 掩盖。
- **容器 ENV 到不了 SSH 会话，须经 `/etc/environment` 中转**：容器 ENV 只被 PID 1 的后代继承，而 SSH 登入的会话不在这条链上——sshd 由启动脚本经 `sudo` 拉起，sudoers 的 `Defaults env_reset` 会清掉自定义变量。因此 compose 注入的 `CHROMIUM_MANAGER_URL` 等值在 SSH 会话（含其中运行的 VS Code Server 与各类 agent）里为空，典型症状是 `curl "$CHROMIUM_MANAGER_URL/agent/acquire"` 打到空地址、HTTP 000。`start-dev-box` 的 `export_env_for_ssh` 把白名单变量写入 `/etc/environment`，靠 `UsePAM yes` + `/etc/pam.d/sshd` 中的 `pam_env.so` 注入会话来打通。改动约束：只导出白名单变量（不要写入 `SSH_PUBLIC_KEY` 这类敏感值，该文件全用户可读）；写入块用 `# >>> dev-box runtime env >>>` 标记包裹并在每次启动时先删后写，保证容器重启不堆积；含换行或双引号的值直接跳过，`pam_env` 只认简单的 `KEY=VALUE`，格式错误会导致整个文件解析异常。当前白名单为 `CHROMIUM_MANAGER_URL`、`CHROMIUM_MANAGER_TOKEN`、`PLAYWRIGHT_BROWSERS_PATH`、`AGY_CLI_DISABLE_AUTO_UPDATE` 与代理变量 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`；注意代理 URL 常含凭据，写入前先确认该凭据可否对容器内所有用户可见。
- 脚本末尾不再是 `exec sleep infinity`，而是周期健康汇报循环（间隔由 `HEALTH_REPORT_INTERVAL` 控制，秒；`0` 关闭）。仅在异常时输出：sshd 进程消失、僵尸进程数变化、SSH 认证失败增量。认证失败计数由 `tag_stream_sshd` 累计到 `$TMPDIR/.devbox-sshd-authfail`（用文件而非变量，因为该函数运行在进程替换的子 shell 中，变量无法回传）；计数模式已去重，只匹配 `Invalid user` / `not allowed because` / `Failed publickey`，避免同一次失败连接的多行日志重复计数。此处不能用 `exec`：虽然进程替换的 FD 会被继承（日志不断流），但 shell 被替换掉后就没有进程做汇报了。
- 镜像通过 Docker 官方 apt 源安装 `docker-ce-cli`，不预装 Buildx、BuildKit 或 Compose 插件，不安装守护进程。默认 Compose 将 `${DOCKER_SOCKET_PATH:-/var/run/docker.sock}` 挂载到容器内 `/var/run/docker.sock`，且 `create_host_path: false` 避免缺失套接字变成目录。`start-dev-box` 按套接字实际组号复用或创建容器内的用户组并授权运行用户，再通过 `sudo` 与 `setpriv --init-groups` 以同一用户保留环境重新执行脚本，使聊天代理和新 SSH 会话直接访问。`docker exec` 或 `docker compose exec` 必须显式指定 `--user vscode` 才会重新读取用户组，默认会沿用容器创建时的旧组。不能修改宿主机套接字的属主或权限。无套接字时跳过初始化。覆盖默认启动命令时需自行通过 `--group-add` 授权。Docker 客户端随每周工作流完整构建刷新，手动刷新用 `no_cache`。
- 默认 `docker-compose.yml` 使用已发布镜像 `ghcr.io/sunyu2481/dev-box:latest`，把 `./workspace` 挂到 `/workspace`、`./.vscode` 绑定挂载持久化 `/home/vscode`。默认 `CMD` 为 `/usr/local/bin/start-dev-box`（启动 sshd，随后进入健康汇报循环常驻），由上述 tini `ENTRYPOINT` 拉起，不要在 Compose 中覆盖二者。Compose 的 SSH 端口映射为 `${DEVBOX_SSH_BIND:-127.0.0.1}:${DEVBOX_SSH_PORT:-2222}:22`——**默认只绑宿主机 loopback，不暴露公网**，推荐经宿主机 SSH 跳转（`ssh -J` / `ProxyJump`）连入容器，这样公网只需开放宿主机自身的 22 端口。要直接暴露需显式设 `DEVBOX_SSH_BIND=0.0.0.0`。改动此默认绑定地址等于扩大公网暴露面，需先确认。Compose 透传的环境变量：`SSH_PUBLIC_KEY`、`HEALTH_REPORT_INTERVAL`、`CHROMIUM_MANAGER_URL`、`CHROMIUM_MANAGER_TOKEN`、`HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`；与 ChromiumManager 的组网以注释形式给出而非默认启用（`external` 网络不存在时 `compose up` 会直接失败）。
- Maven 和 Gradle 从官方二进制发行包安装到 `/opt/maven` 和 `/opt/gradle`。Maven 下载镜像找不到指定版本时，回退到同版本的 Apache 官方归档。
- Node.js 和 Go 从上游发布归档安装，并通过 `TARGETARCH` 做架构映射。如果增加架构支持，需要同步更新这些 `case` 映射。Node.js 安装层会先查 `nodejs.org/dist/index.json` 取最新 LTS 版本号，查不到则回退到 `NODE_VERSION` 构建参数（见架构说明第一条）。
- `uv` 通过 `${UV_VERSION}` 对应的 Astral 安装脚本安装，并与 `uvx` 一起复制到 `/usr/local/bin`。
- 全局 AI CLI 中，Claude Code 和 OpenAI Codex CLI 通过 npm 包参数安装。Google Antigravity CLI 使用官方 `https://antigravity.google/cli/install.sh` 安装器，通过 `--dir /usr/local/bin` 安装 `agy`，支持 `linux/amd64` 与 `linux/arm64`，安装器校验发行包 SHA512。安装层位于 `VOLATILE_TOOLS_CACHE_BUST` 之后，执行时获取最新版本。默认 `AGY_CLI_DISABLE_AUTO_UPDATE=true` 并透传到 SSH 会话，避免普通用户更新 root 管理的系统二进制；通过工作流刷新镜像更新。构建时以 vscode 验证 `agy --version`，冒烟测试验证 SSH 中的命令可用性与自更新开关。
- `cc-connect` 默认 `CC_CONNECT_VERSION=beta`，查询 npm 官方 `beta` 发布标签后，从对应 GitHub Release 下载 `linux/amd64` 或 `linux/arm64` 二进制，校验同版本 `checksums.txt` 后安装到 `/usr/local/bin`。也可传入具体版本号回退。CI 每次构建前解析一次版本并传入构建参数，保证两个架构版本一致且新版本使安装缓存失效。默认查询仅在安装层重新执行时发生；查询失败直接终止，不回退到旧版。示例配置位于 `/usr/local/share/cc-connect/config.example.toml`，用户复制到 home 后填写，不能把机器人密钥放进镜像。
- 聊天桥接仅在 `CC_CONNECT_ENABLED=1` 时启动，`CC_CONNECT_CONFIG` 指定容器内配置路径（默认 `/home/vscode/.cc-connect/config.toml`）。进程以 vscode 运行，继承容器环境，日志用进程替换汇聚为 `[cc-connect]`。启用后配置缺失或进程退出时容器失败退出；`wait -n` 同时等待服务与健康汇报计时，即使 `HEALTH_REPORT_INTERVAL=0` 也检测桥接退出。终止信号通过退出处理通知服务，日志读取进程忽略终止信号并排空输出，Compose 的 `stop_grace_period` 为 30 秒。不要改成管道或 systemd daemon，不要让关闭健康汇报隐藏桥接失败。
- 聊天配置与状态随 home 挂载持久化。示例配置 Codex `backend = "app_server"`、`app_server_url = "stdio://"`，避免监听冲突并允许聊天审批；默认 `exec` 后端无交互审批。平台 `allow_from` 必须明确填写，空或 `*` 为允许全部；项目层 `admin_from` 留空时禁止管理命令。密钥可经权限受限的配置或可选 `env_file` 注入，不扩展 `/etc/environment` 的敏感变量白名单。
- **镜像不预装浏览器二进制**，浏览器由独立的 ChromiumManager 容器提供，agent 与脚本经其 CDP 网关（默认 `10102`，同 Docker 网络内可达，不 publish 到宿主机）连接远程实例。镜像内只保留客户端：`playwright` npm 包（供 `chromium.connectOverCDP()`）与 `chrome-devtools-mcp`（Claude Code / Codex 的浏览器 MCP，用 `--wsEndpoint` 指向 ws 地址）。相关约束：
  - **`chrome-devtools-mcp` 必须用 `--wsEndpoint`，不能用 `--browser-url`。** 其内部（`build/src/third_party/index.js`）以 `new URL('/json/version', browserURL)` 推导端点，绝对路径参数会替换掉 base 的整个 path，`/cdp/<id>` 前缀被丢弃 → 请求落到网关根路径 404。属 puppeteer 固有行为，对任何带路径前缀的 CDP 网关都成立，改注册写法无法绕过。ws 地址从 `curl "$CDP/json/version" | jq -r .webSocketDebuggerUrl` 取得（网关已重写为带前缀形式）。Playwright 的 `connectOverCDP()` 不受此影响，可直接用 cdpUrl。
  - ws 地址含浏览器会话 ID，浏览器重启后失效需重新注册；profile ID 则在重启后保持稳定。
  - 安装层执行的是 `playwright install-deps chromium` 而非 `playwright install --with-deps chromium`——**只装运行期系统库（libgtk-3/libnss3 等，数十 MB），不下载浏览器**。保留这些库是为了让"确需本地浏览器时"退化成一条免 sudo 的 `playwright install chromium`；删掉它们会省不了多少体积，却让现装必须 root + 联网 apt。
  - `PLAYWRIGHT_BROWSERS_PATH` 指向 `/home/vscode/.cache/ms-playwright`（原为 `/ms-playwright`）。改到 home 下是为了让现装的浏览器落进 compose 的绑定挂载，重建容器不必重装。
  - `chrome-devtools-mcp` 依赖全部 bundled，安装不会触发浏览器下载；不要为它补 `puppeteer`（那个包会拉浏览器）。
  - profile ID 由 ChromiumManager 创建时生成，**无法预置进镜像**，因此 MCP 只能在运行期取得实例后注册，不要试图在 Dockerfile 里写死 CDP 或 ws 地址。
  - 两类场景 CDP 替代不了，属已知取舍：`playwright test`（走 Playwright server 协议而非 CDP，`connectOptions` 接不进来）与 `playwright screenshot`/`codegen` 等只能启动本地浏览器的 CLI 子命令。这两类需先 `playwright install chromium` 现装。
  - 远程浏览器的 `localhost` 是 ChromiumManager 容器自身。让它访问 dev-box 里的开发服务器时，服务须监听 `0.0.0.0`，URL 用 `http://dev-box:<port>`。
- 最终镜像以 `vscode` 用户运行，`WORKDIR` 为 `/workspace`；`/home/vscode` 下的缓存和工具目录（含供现装浏览器用的 `.cache/ms-playwright`）会预先创建并归属给 `vscode`。镜像已不再创建顶层 `/ms-playwright`。
- `.github/workflows/docker.yml` 使用 QEMU 和 Docker Buildx，在推送到 `main`、推送 `v*` 标签、手动触发 `workflow_dispatch` 以及每周定时构建时，将 `linux/amd64` 和 `linux/arm64` 镜像发布到 GHCR。
- Docker metadata tag 包括默认分支的 `latest`、分支引用、tag 引用和 `sha-*` tag；定时任务在默认分支运行并沿用这些标签，不额外生成 nightly 标签。每次构建设置 `pull: true`；每周一北京时间 11:17 的定时任务绕过全部缓存，刷新系统安全补丁、Node.js LTS、GitHub CLI 和全局命令行工具。
- `VOLATILE_TOOLS_CACHE_BUST` 在 cc-connect 安装层之前声明，四个 npm 包参数在全局命令行工具安装层之前声明。手动勾选 `refresh_volatile_tools` 使 cc-connect 层及后续层失去缓存，同时刷新聊天桥接和全局 CLI；系统与工具链缓存可以复用。完整安全刷新应在 GitHub Workflow 中勾选 `no_cache`。

## 变更指引

- 修改已安装工具时，如果影响用户可见的镜像内容，需要同步更新 `README.md`。
- 进行版本升级时，更新对应的 Dockerfile `ARG` 默认值，并通过重新构建验证。
- 修改发布 workflow 前，先检查 `docker/metadata-action` 对分支、tag 和 SHA 构建的 tag 与 label 影响。
