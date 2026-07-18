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
  docker run --rm dev-box:local bash -lc 'node --version && pnpm --version && playwright --version && python --version && uv --version && go version && java -version && mvn --version && gradle --version && gh --version'
  ```
- 验证随镜像安装的 Chromium 可以通过 Playwright 启动：
  ```bash
  docker run --rm dev-box:local bash -lc 'playwright screenshot --browser=chromium about:blank /tmp/chromium.png'
  ```
- 构建与 CI 相同的平台但不推送镜像：
  ```bash
  docker buildx build --platform linux/amd64,linux/arm64 -t dev-box:local .
  ```

## 测试和 lint

本仓库没有配置语言特定的测试套件或 linter。修改 `Dockerfile` 后，优先使用 `docker build -t dev-box:local .` 作为主要验证方式；如果修改了浏览器相关层，再运行 Playwright Chromium 启动检查。本仓库没有单测试命令。

## 架构说明

- `Dockerfile` 基于 `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`，并使用 `TARGETPLATFORM`、`TARGETOS` 和 `TARGETARCH` 支持多架构构建。
- 工具版本由 Docker build args 控制：`NODE_VERSION`、`PNPM_VERSION`、`GO_VERSION`、`MAVEN_VERSION` 和 `GRADLE_VERSION`。更新版本时优先修改这些默认值，不要在其他位置硬编码版本。
- 系统包会安装常用开发工具、Python、Java 21、Git LFS、浏览器字体以及网络/调试工具。
- GitHub CLI（`gh`）通过 GitHub CLI 官方 apt 源安装。
- OpenSSH 服务（`openssh-server`）随镜像安装，配置文件为 `/etc/ssh/sshd_config_devbox`（独立配置，仅公钥认证、禁用密码与 root 登录、`UsePAM yes`）。`UsePAM yes` 是必需的：vscode 账户密码字段被锁定（`!`），若 `UsePAM no` 则 sshd 会因"账户锁定"拒绝包括公钥在内的所有认证。镜像构建时删除 apt 固化生成的 `/etc/ssh/ssh_host_*`；host key 在容器首次启动时由 `start-with-gateway` 生成并持久化到 `/home/vscode/.ssh/host_keys`。公钥可通过环境变量 `SSH_PUBLIC_KEY`、挂载到 `~/.ssh` 下的任意 `*.pub` 文件、或直接放置 `~/.ssh/authorized_keys` 三种方式提供，启动脚本会去重合并到 vscode 用户的 `authorized_keys`；无授权公钥时不启动 sshd。sshd 由 vscode 用户经 `sudo` 以 root 启动。
- 镜像不预装 Docker CLI / Buildx / Compose；如需在容器内操作宿主机 Docker，请自行安装客户端并挂载 socket。
- 默认 `docker-compose.yml` 使用已发布镜像 `ghcr.io/sunyu2481/dev-box:latest`，挂载当前目录到 `/workspace`，用绑定挂载持久化 `/home/vscode`。默认 `CMD` 为 `/usr/local/bin/start-with-gateway`（依次启动 sshd 与 Hermes gateway，最后 `exec sleep infinity`），不要在 Compose 中覆盖。Compose 默认把容器内 22 端口映射到宿主 `2222`，并透传 `SSH_PUBLIC_KEY` 环境变量。
- Maven 和 Gradle 从官方二进制发行包安装到 `/opt/maven` 和 `/opt/gradle`。
- Node.js 和 Go 从上游发布归档安装，并通过 `TARGETARCH` 做架构映射。如果增加架构支持，需要同步更新这些 `case` 映射。
- `uv` 通过 Astral 安装脚本安装，并与 `uvx` 一起复制到 `/usr/local/bin`。
- 全局 AI CLI 中，Claude Code 和 OpenAI Codex CLI 通过 npm 包参数安装。
- Hermes 通过官方 `install.sh`（`--skip-setup --skip-browser --non-interactive`）安装到 `/usr/local/lib/hermes-agent`，并额外 `uv pip install python-telegram-bot`。安装后删除 gateway 非必需内容（`node_modules`、`apps`/`website`/`web`/`ui-tui`/`tests`/`.git` 等），仅保留 Python venv 与 editable 源码树供 `hermes gateway` 使用。
- Chromium 通过 Playwright 安装到 `/ms-playwright`，以保持浏览器自动化在 `linux/amd64` 和 `linux/arm64` 构建中的兼容性。
- 最终镜像以 `vscode` 用户运行，`WORKDIR` 为 `/workspace`；`/home/vscode` 下的缓存和工具目录以及 `/ms-playwright` 会预先创建并归属给 `vscode`。
- `.github/workflows/docker.yml` 使用 QEMU 和 Docker Buildx，在推送到 `main`、推送 `v*` tag 以及手动触发 `workflow_dispatch` 时，将 `linux/amd64` 和 `linux/arm64` 镜像发布到 GHCR。
- Docker metadata tag 包括默认分支的 `latest`、分支引用、tag 引用和 `sha-*` tag。

## 变更指引

- 修改已安装工具时，如果影响用户可见的镜像内容，需要同步更新 `README.md`。
- 进行版本升级时，更新对应的 Dockerfile `ARG` 默认值，并通过重新构建验证。
- 修改发布 workflow 前，先检查 `docker/metadata-action` 对分支、tag 和 SHA 构建的 tag 与 label 影响。
