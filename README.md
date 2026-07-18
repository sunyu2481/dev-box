# dev-box

`dev-box` 是一个多架构开发容器镜像，通过 GitHub Actions 构建并发布到 GitHub Container Registry（GHCR）。

## 功能特性

- 基于 Ubuntu 24.04
- Node.js 24
- pnpm 11
- Python
- uv
- Go 1.26
- Java 21
- Maven 3.9
- Gradle 9
- Git / Git LFS / GitHub CLI (`gh`)
- 通过 Playwright 提供用于浏览器自动化的 Chromium
- 支持 CJK、emoji 和常见网页渲染场景的浏览器字体
- 常用开发工具
- 内置 OpenSSH 服务，支持外部直接 SSH 连入容器（仅公钥认证）
- AI CLI 工具：
  - Claude Code
  - OpenAI Codex CLI
  - Hermes agent gateway（预装 Telegram adapter；镜像仅保留 gateway 运行时，不含桌面/TUI/Web UI 与浏览器工具链）

## 镜像

```bash
docker pull ghcr.io/sunyu2481/dev-box:latest
```

## 发布与刷新预装工具

GitHub Actions 会在推送到 `main`、推送 `v*` 标签或手动触发 workflow 时构建并推送镜像。workflow 默认使用 Docker layer cache，因此未修改 `Dockerfile` 时，手动触发可能会快速命中缓存，不会重新安装 Codex、Claude Code、Playwright 这类默认安装 latest 的工具。

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

### 通过 SSH 直连容器

镜像内置 OpenSSH 服务，外部可以不经宿主机跳转、直接 SSH 连入容器。出于安全考虑**只启用公钥认证**，密码与 root 登录均已禁用。

sshd 仅在检测到已授权公钥时才启动。公钥可通过以下任一方式提供（任选其一）：

- **环境变量**：启动时设置 `SSH_PUBLIC_KEY`；
- **挂载公钥文件**：把 `id_ed25519.pub` 等公钥文件放到宿主机 `./.vscode/.ssh/`（对应容器内 `~/.ssh`），启动时会自动合并该目录下所有 `*.pub`；
- **挂载 authorized_keys**：直接编辑/挂载 `./.vscode/.ssh/authorized_keys`。

方式一，使用 Docker Compose 注入环境变量（默认把容器内 22 端口映射到宿主机 `2222`）：

```bash
SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d
```

使用 `docker run`：

```bash
docker run -d \
  -p 2222:22 \
  -e SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  ghcr.io/sunyu2481/dev-box:latest
```

方式二，把公钥文件丢进挂载目录（无需环境变量）：

```bash
mkdir -p ./.vscode/.ssh
cp ~/.ssh/id_ed25519.pub ./.vscode/.ssh/
docker compose up -d
```

随后从外部连接（登录用户为 `vscode`）：

```bash
ssh -p 2222 vscode@<宿主机地址>
```

host key 持久化在容器内 `/home/vscode/.ssh/host_keys` 下，借助命名卷/绑定挂载保留，重建容器后 SSH 指纹保持不变，不会触发客户端的 `REMOTE HOST IDENTIFICATION HAS CHANGED` 警告。

> SSH 服务以 root 权限通过 `vscode` 用户的 `sudo` 启动；将端口暴露到公网前，请确认注入的是受信任的公钥。
