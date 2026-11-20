# syntax=docker/dockerfile:1.7

FROM --platform=$TARGETPLATFORM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

# NODE_VERSION：仅在无法查询最新 LTS 时回退到此版本，保持为已知的最新安全版本。
ARG NODE_VERSION=24.22.1
ARG PNPM_VERSION=11.28.6
ARG GO_VERSION=1.26.10
ARG MAVEN_VERSION=3.10.0
ARG GRADLE_VERSION=9.8.2
ARG UV_VERSION=0.13.5

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PNPM_HOME=/home/vscode/.local/share/pnpm \
    GOPATH=/home/vscode/go \
    PLAYWRIGHT_BROWSERS_PATH=/home/vscode/.cache/ms-playwright \
    PATH=/home/vscode/.local/share/pnpm:/opt/maven/bin:/opt/gradle/bin:/usr/local/go/bin:/usr/local/bin:/home/vscode/go/bin:$PATH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 安装系统工具，并更新基础镜像中已有软件包的安全修订。
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
    bash-completion \
    build-essential \
    ca-certificates \
    curl \
    dnsutils \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    git \
    git-lfs \
    gnupg \
    iputils-ping \
    jq \
    less \
    lsb-release \
    make \
    net-tools \
    openssh-client \
    openssh-server \
    pkg-config \
    rsync \
    software-properties-common \
    sudo \
    telnet \
    time \
    tini \
    tree \
    unzip \
    vim \
    wget \
    xz-utils \
    zip \
    zsh \
    python3 \
    python3-pip \
    python3-venv \
    python-is-python3 \
    openjdk-21-jdk \
    && rm -f /etc/ssh/ssh_host_* \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 安装 GitHub CLI
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && gh --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 从 Docker 官方源安装客户端，连接宿主机的 Docker 服务；镜像构建交给 GitHub Workflow。
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && docker --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 从官方发行包安装 Maven 和 Gradle。
# Maven 旧版本可能从下载镜像移除，此时使用同版本的官方归档。
RUN mkdir -p /opt \
    && { curl -fsSL "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz \
      || curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz; } \
    && tar -xzf /tmp/maven.tgz -C /opt \
    && ln -s "apache-maven-${MAVEN_VERSION}" /opt/maven \
    && rm -f /tmp/maven.tgz \
    && curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && ln -s "gradle-${GRADLE_VERSION}" /opt/gradle \
    && rm -f /tmp/gradle.zip \
    && mvn --version \
    && gradle --version

# 从官方发行包安装 Node.js，按目标架构选择二进制。
RUN case "${TARGETARCH}" in \
        amd64) NODE_ARCH='x64' ;; \
        arm64) NODE_ARCH='arm64' ;; \
        *) echo "不支持的目标架构：${TARGETARCH}" && exit 1 ;; \
    esac \
    && NODE_LATEST='' \
    && if curl -fsSL --max-time 30 https://nodejs.org/dist/index.json -o /tmp/node-index.json 2>/dev/null; then \
        NODE_LATEST=$(jq -er '[.[] | select(.lts != false and .lts != null)] | max_by(.version[1:] | split(".") | map(tonumber)) | .version' /tmp/node-index.json 2>/dev/null) || NODE_LATEST=''; \
    fi \
    && rm -f /tmp/node-index.json \
    && NODE_RESOLVED=${NODE_LATEST:-v${NODE_VERSION}} \
    && if [ -n "$NODE_LATEST" ]; then echo "安装 Node.js ${NODE_RESOLVED}（最新 LTS）"; else echo "安装 Node.js ${NODE_RESOLVED}（使用回退版本）"; fi \
    && curl -fsSL "https://nodejs.org/dist/${NODE_RESOLVED}/node-${NODE_RESOLVED}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && node --version \
    && npm --version \
    && npm install -g corepack \
    && corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version

# 安装指定版本的 uv 和 uvx。
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
    && install -Dm755 /root/.local/bin/uv /usr/local/bin/uv \
    && install -Dm755 /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv --version

# 按目标架构安装 Go。
RUN case "${TARGETARCH}" in \
        amd64) GOARCH='amd64' ;; \
        arm64) GOARCH='arm64' ;; \
        *) echo "不支持的目标架构：${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz \
    && go version

# 默认跟踪上游 beta 通道，也可传入具体版本号。
# 刷新参数放在工具链之后，同时刷新聊天桥接与全局命令行工具。
ARG VOLATILE_TOOLS_CACHE_BUST=0
ARG CC_CONNECT_VERSION=beta
RUN case "${TARGETARCH}" in \
        amd64|arm64) CC_CONNECT_ARCH="${TARGETARCH}" ;; \
        *) echo "不支持的目标架构：${TARGETARCH}" && exit 1 ;; \
    esac \
    && echo "命令行工具刷新编号：${VOLATILE_TOOLS_CACHE_BUST}" \
    && CC_CONNECT_RESOLVED="${CC_CONNECT_VERSION}" \
    && if [ "$CC_CONNECT_VERSION" = beta ]; then \
        CC_CONNECT_RESOLVED=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 https://registry.npmjs.org/-/package/cc-connect/dist-tags \
          | jq -er '.beta | select(type == "string") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9A-Za-z.-]+$"))'); \
    fi \
    && [[ "$CC_CONNECT_RESOLVED" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    && echo "安装 cc-connect ${CC_CONNECT_RESOLVED}（构建参数：${CC_CONNECT_VERSION}）" \
    && CC_CONNECT_ARCHIVE="cc-connect-v${CC_CONNECT_RESOLVED}-linux-${CC_CONNECT_ARCH}.tar.gz" \
    && CC_CONNECT_RELEASE="https://github.com/chenhg5/cc-connect/releases/download/v${CC_CONNECT_RESOLVED}" \
    && mkdir -p /tmp/cc-connect \
    && curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "${CC_CONNECT_RELEASE}/${CC_CONNECT_ARCHIVE}" -o "/tmp/cc-connect/${CC_CONNECT_ARCHIVE}" \
    && curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "${CC_CONNECT_RELEASE}/checksums.txt" -o /tmp/cc-connect/checksums.txt \
    && CC_CONNECT_SHA256=$(awk -v archive="${CC_CONNECT_ARCHIVE}" '$2 == archive { print $1 }' /tmp/cc-connect/checksums.txt) \
    && test -n "$CC_CONNECT_SHA256" \
    && printf '%s  %s\n' "$CC_CONNECT_SHA256" "/tmp/cc-connect/${CC_CONNECT_ARCHIVE}" | sha256sum -c - \
    && tar -xzf "/tmp/cc-connect/${CC_CONNECT_ARCHIVE}" -C /tmp/cc-connect "${CC_CONNECT_ARCHIVE%.tar.gz}" \
    && install -m 0755 "/tmp/cc-connect/${CC_CONNECT_ARCHIVE%.tar.gz}" /usr/local/bin/cc-connect \
    && install -d -m 0755 /usr/local/share/cc-connect \
    && cc-connect --version \
    && rm -rf /tmp/cc-connect

# 安装全局命令行工具和浏览器自动化客户端。
#
# 镜像刻意不预装浏览器二进制：浏览器由 ChromiumManager 容器提供，agent 经其
# CDP 网关（默认 10102）连接已配置好指纹与代理的实例，因此本地只需要客户端库。
#   - playwright：仅保留 npm 包（几 MB），供 chromium.connectOverCDP() 连远程浏览器。
#   - chrome-devtools-mcp：Claude Code / Codex 的浏览器 MCP，走 --wsEndpoint 连 CDP。
#     其依赖全部 bundled，安装不会触发浏览器下载。
# 仍执行 install-deps 装齐 Chromium 的运行期系统库（libgtk-3/libnss3 等，合计数十 MB）：
# 这些库对 CDP 远程连接虽非必需，但让"需要本地浏览器时现装"退化为一条免 sudo 的
# `playwright install chromium`（否则 install-deps 要 root 且需联网 apt）。
# npm 包参数只在本层声明，版本调整时复用前面的安装缓存。
ARG CLAUDE_CODE_NPM_PACKAGE="@anthropic-ai/claude-code"
ARG CODEX_CLI_NPM_PACKAGE="@openai/codex"
ARG PLAYWRIGHT_NPM_PACKAGE="playwright"
ARG CHROME_DEVTOOLS_MCP_NPM_PACKAGE="chrome-devtools-mcp"
RUN echo "命令行工具刷新编号：${VOLATILE_TOOLS_CACHE_BUST}" \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g \
    "${CLAUDE_CODE_NPM_PACKAGE}" \
    "${CODEX_CLI_NPM_PACKAGE}" \
    "${PLAYWRIGHT_NPM_PACKAGE}" \
    "${CHROME_DEVTOOLS_MCP_NPM_PACKAGE}" \
    && apt-get update \
    && playwright install-deps chromium \
    && command -v chrome-devtools-mcp >/dev/null \
    && npm cache clean --force \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 准备 vscode 用户的工具和缓存目录。
# ms-playwright 目录预建并归属 vscode：镜像不带浏览器二进制，但需要本地浏览器时
# （如 `playwright test`、`playwright screenshot` 这类只能启动本地浏览器的场景）
# 可免 sudo 直接 `playwright install chromium` 装到这里。该路径位于 /home/vscode 下，
# 配合 compose 的绑定挂载可跨容器重建持久化。
RUN mkdir -p \
    /home/vscode/.local/share/pnpm \
    /home/vscode/.cache/pip \
    /home/vscode/.cache/uv \
    /home/vscode/.cache/ms-playwright \
    /home/vscode/.cc-connect \
    /home/vscode/.m2 \
    /home/vscode/.gradle \
    /home/vscode/go/pkg \
    /home/vscode/go/bin \
    /workspace \
    && chown -R vscode:vscode /home/vscode /workspace

COPY --chmod=0644 cc-connect.config.example.toml /usr/local/share/cc-connect/config.example.toml
COPY sshd_config_devbox /etc/ssh/sshd_config_devbox
COPY --chmod=0755 start-dev-box.sh /usr/local/bin/start-dev-box

USER vscode
WORKDIR /workspace

# 验证 vscode 用户的工具链，并激活默认 pnpm 版本。
RUN corepack enable \
    && command -v setpriv >/dev/null \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version \
    && claude --version \
    && codex --version \
    && cc-connect --version \
    && playwright --version \
    && test -r /usr/local/share/cc-connect/config.example.toml \
    && chrome-devtools-mcp --version \
    && python --version \
    && java -version \
    && mvn --version \
    && gradle --version \
    && go version \
    && uv --version \
    && gh --version \
    && docker --version

# tini 作为 PID 1：容器主进程必须负责回收孤儿进程。sshd 的 pre-auth 子进程在
# 遭遇扫描/爆破时会被 reparent 到 PID 1，若 PID 1 不调用 wait()（如 sleep），
# 这些进程退出后会永久停留在 Z 状态并耗尽 PID。tini 内置于镜像，因此无论调用方
# 是否传 `docker run --init` / compose `init: true`，回收行为都成立。
# -s：即使 tini 不是 PID 1（例如调用方又叠了 docker-init）也注册为 child subreaper，
# 保证孤儿仍被收养回收；-g：信号转发给整个进程组，便于 docker stop 干净退出。
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--"]
CMD ["/usr/local/bin/start-dev-box"]
