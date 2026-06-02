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
- AI CLI 工具：
  - Claude Code
  - OpenAI Codex CLI
  - Gemini CLI
  - Hermes agent

## 镜像

```bash
docker pull ghcr.io/sunyu2481/dev-box:latest
```

## 使用方式

### 使用 Docker Compose 启动

仓库提供了默认的 `docker-compose.yml`，会直接使用 `ghcr.io/sunyu2481/dev-box:latest`，并做以下挂载：

- 当前目录挂载到容器内的 `/workspace`
- 命名卷 `vscode-home` 挂载到 `/home/vscode`，用于保留 shell 配置、工具缓存、Maven/Gradle/Go 缓存等用户数据
- 宿主机 `/var/run/docker.sock` 挂载到容器内，供 Docker 客户端工具使用

启动容器：

```bash
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d
```

进入容器：

```bash
docker compose exec dev-box bash
```

停止并删除容器：

```bash
docker compose down
```

`docker compose down` 默认会保留 `vscode-home` 命名卷，因此 `/home/vscode` 下的配置和缓存会保留下来。如果需要连同该命名卷一起删除，可以执行：

```bash
docker compose down -v
```

### 使用 docker run 启动

也可以直接启动交互式 shell：

```bash
docker run --rm -it ghcr.io/sunyu2481/dev-box:latest bash
```

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

如果访问 `/var/run/docker.sock` 时看到 `permission denied`，请先确认宿主机 Docker daemon 正在运行，并保留 `docker run` 命令里的 `--group-add "$(stat -c '%g' /var/run/docker.sock)"` 参数。

如果需要构建本地项目源码，可以同时挂载项目目录：

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c '%g' /var/run/docker.sock)" \
  ghcr.io/sunyu2481/dev-box:latest bash
```

> 挂载 `/var/run/docker.sock` 会让容器获得访问宿主机 Docker daemon 的能力。请只对可信容器和可信工作负载使用这种方式。
