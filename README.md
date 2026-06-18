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
- Git / Git LFS
- Docker CLI、Buildx 和 Compose plugin
- 通过 Playwright 提供用于浏览器自动化的 Chromium
- 支持 CJK、emoji 和常见网页渲染场景的浏览器字体
- 常用开发工具
- 内置 OpenSSH 服务，支持外部直接 SSH 连入容器（仅公钥认证）
- AI CLI 工具：
  - Claude Code
  - OpenAI Codex CLI
  - Antigravity CLI
  - Hermes agent（随 gateway 预装 Telegram adapter 依赖）

## 镜像

```bash
docker pull ghcr.io/sunyu2481/dev-box:latest
```

## 使用方式

### 使用 Docker Compose 启动

仓库提供了默认的 `docker-compose.yml`，会直接使用 `ghcr.io/sunyu2481/dev-box:latest`，并做以下挂载：

- `./workspace` 挂载到容器内的 `/workspace`
- `./.vscode` 挂载到容器内的 `/home/vscode`，用于保留 shell 配置、工具缓存、Maven/Gradle/Go 缓存等用户数据
- 宿主机 `/var/run/docker.sock` 挂载到容器内，供 Docker 客户端工具使用

启动容器：

```bash
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d
```

`DOCKER_GID` 必须设置为宿主机 `/var/run/docker.sock` 的 group id。否则容器内的非 root 用户无法访问 Docker socket。

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
SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) \
  docker compose up -d
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
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d
```

随后从外部连接（登录用户为 `vscode`）：

```bash
ssh -p 2222 vscode@<宿主机地址>
```

host key 持久化在容器内 `/home/vscode/.ssh/host_keys` 下，借助命名卷/绑定挂载保留，重建容器后 SSH 指纹保持不变，不会触发客户端的 `REMOTE HOST IDENTIFICATION HAS CHANGED` 警告。

> SSH 服务以 root 权限通过 `vscode` 用户的 `sudo` 启动；将端口暴露到公网前，请确认注入的是受信任的公钥。

### 在容器内使用 Docker

镜像只包含 Docker 客户端工具：`docker`、`docker buildx` 和 `docker compose`。镜像内部不会启动 Docker daemon。

默认 `docker-compose.yml` 已经挂载宿主机的 Docker socket。如果需要使用 `docker run` 手动启动，请挂载宿主机的 Docker socket：

```bash
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c '%g' /var/run/docker.sock)" \
  ghcr.io/sunyu2481/dev-box:latest bash
```

进入容器后即可运行 Docker 命令：

```bash
docker ps
docker build .
docker compose up
```

如果访问 `/var/run/docker.sock` 时看到 `permission denied`，请先确认宿主机 Docker daemon 正在运行。使用 Docker Compose 时，请带上 `DOCKER_GID` 并重新创建容器：

```bash
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d --force-recreate
```

使用 `docker run` 时，请保留命令里的 `--group-add "$(stat -c '%g' /var/run/docker.sock)"` 参数。

如果需要构建本地项目源码，可以同时挂载项目目录：

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c '%g' /var/run/docker.sock)" \
  ghcr.io/sunyu2481/dev-box:latest bash
```

> 挂载 `/var/run/docker.sock` 会让容器获得访问宿主机 Docker daemon 的能力。请只对可信容器和可信工作负载使用这种方式。
