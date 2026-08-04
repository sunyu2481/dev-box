# syntax=docker/dockerfile:1.7

FROM --platform=$TARGETPLATFORM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

# NODE_VERSION: 自动安装最新 LTS 版本时的 fallback（仅当无法访问 nodejs.org/dist/index.json
# 时回退到此版本）。设为当前已知最新的 LTS，避免回退命中历史坏区间版本导致构建失败。
ARG NODE_VERSION=24.19.0
ARG PNPM_VERSION=11.20.0
ARG GO_VERSION=1.26.3
ARG MAVEN_VERSION=3.9.16
ARG GRADLE_VERSION=9.5.1

ARG CLAUDE_CODE_NPM_PACKAGE="@anthropic-ai/claude-code"
ARG CODEX_CLI_NPM_PACKAGE="@openai/codex"
ARG PLAYWRIGHT_NPM_PACKAGE="playwright"
ARG VOLATILE_TOOLS_CACHE_BUST=0

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PNPM_HOME=/home/vscode/.local/share/pnpm \
    GOPATH=/home/vscode/go \
    HERMES_HOME=/home/vscode/.hermes \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PATH=/home/vscode/.local/share/pnpm:/opt/maven/bin:/opt/gradle/bin:/usr/local/go/bin:/usr/local/bin:/home/vscode/go/bin:$PATH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Install Maven and Gradle from official distributions
RUN mkdir -p /opt \
    && curl -fsSL "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz \
    && tar -xzf /tmp/maven.tgz -C /opt \
    && ln -s "apache-maven-${MAVEN_VERSION}" /opt/maven \
    && rm -f /tmp/maven.tgz \
    && curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && ln -s "gradle-${GRADLE_VERSION}" /opt/gradle \
    && rm -f /tmp/gradle.zip \
    && mvn --version \
    && gradle --version

# Install Node.js from official binaries for better multi-arch stability
RUN case "${TARGETARCH}" in \
        amd64) NODE_ARCH='x64' ;; \
        arm64) NODE_ARCH='arm64' ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL https://nodejs.org/dist/index.json -o /tmp/node-index.json 2>/dev/null || true \
    && NODE_LATEST=$(jq -r '
            [.[] | select(.lts != false) | .version[1:]]
            | map(split(".") | map(tonumber))
            | sort_by(.[0],.[1],.[2]) | last | "v"+(.[0]|tostring)+"."+(.[1]|tostring)+"."+(.[2]|tostring)
          ' /tmp/node-index.json 2>/dev/null) || true \
    && rm -f /tmp/node-index.json \
    && NODE_RESOLVED=${NODE_LATEST:-v${NODE_VERSION}} \
    && if [ -n "$NODE_LATEST" ]; then echo "Resolved Node: ${NODE_RESOLVED} (auto latest LTS)"; else echo "Resolved Node: ${NODE_RESOLVED} (fallback to built-in: v${NODE_VERSION})"; fi \
    && curl -fsSL "https://nodejs.org/dist/${NODE_RESOLVED}/node-${NODE_RESOLVED}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && node --version \
    && npm --version \
    && npm install -g corepack \
    && corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && install -Dm755 /root/.local/bin/uv /usr/local/bin/uv \
    && install -Dm755 /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv --version

# Install Go
RUN case "${TARGETARCH}" in \
        amd64) GOARCH='amd64' ;; \
        arm64) GOARCH='arm64' ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz \
    && go version

# Install Hermes agent（仅保留 gateway 运行时：Python venv + 源码；去掉桌面/TUI/Web/测试与 node 依赖）
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh" -o /tmp/hermes-install.sh \
    && bash /tmp/hermes-install.sh --skip-setup --skip-browser --non-interactive \
    && uv pip install --python /usr/local/lib/hermes-agent/venv/bin/python python-telegram-bot \
    && /usr/local/lib/hermes-agent/venv/bin/python -c "import telegram" \
    && hermes --help >/dev/null \
    && hermes gateway --help >/dev/null \
    && rm -rf \
        /usr/local/lib/hermes-agent/node_modules \
        /usr/local/lib/hermes-agent/apps \
        /usr/local/lib/hermes-agent/website \
        /usr/local/lib/hermes-agent/tests \
        /usr/local/lib/hermes-agent/web \
        /usr/local/lib/hermes-agent/ui-tui \
        /usr/local/lib/hermes-agent/tui_gateway \
        /usr/local/lib/hermes-agent/docs \
        /usr/local/lib/hermes-agent/.github \
        /usr/local/lib/hermes-agent/.git \
        /usr/local/lib/hermes-agent/.plans \
        /usr/local/lib/hermes-agent/nix \
        /usr/local/lib/hermes-agent/docker \
        /usr/local/lib/hermes-agent/assets \
        /usr/local/lib/hermes-agent/datagen-config-examples \
        /usr/local/lib/hermes-agent/package.json \
        /usr/local/lib/hermes-agent/package-lock.json \
        /usr/local/lib/hermes-agent/Dockerfile \
        /usr/local/lib/hermes-agent/docker-compose.yml \
        /usr/local/lib/hermes-agent/docker-compose.windows.yml \
        /usr/local/lib/hermes-agent/flake.nix \
        /usr/local/lib/hermes-agent/flake.lock \
        /usr/local/lib/hermes-agent/.hadolint.yaml \
        /usr/local/lib/hermes-agent/.dockerignore \
        /usr/local/lib/hermes-agent/.gitattributes \
        /usr/local/lib/hermes-agent/.gitignore \
        /usr/local/lib/hermes-agent/.mailmap \
        /usr/local/lib/hermes-agent/.envrc \
        /usr/local/lib/hermes-agent/README.md \
        /usr/local/lib/hermes-agent/README.es.md \
        /usr/local/lib/hermes-agent/README.ur-pk.md \
        /usr/local/lib/hermes-agent/README.zh-CN.md \
        /usr/local/lib/hermes-agent/CONTRIBUTING.md \
        /usr/local/lib/hermes-agent/CONTRIBUTING.es.md \
        /usr/local/lib/hermes-agent/SECURITY.md \
        /usr/local/lib/hermes-agent/SECURITY.es.md \
        /usr/local/lib/hermes-agent/AGENTS.md \
        /usr/local/lib/hermes-agent/hermes-already-has-routines.md \
    && rm -rf \
        "${HERMES_HOME}/node" \
        /root/.hermes/node \
        /root/.npm \
        /tmp/npm-* \
        /tmp/hermes-install.sh \
    && hermes --help >/dev/null \
    && hermes gateway --help >/dev/null \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /root/.cache/uv /root/.cache/pip /root/.npm

# Install global CLIs and browser automation runtime
RUN echo "VOLATILE_TOOLS_CACHE_BUST=${VOLATILE_TOOLS_CACHE_BUST}" \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g \
    "${CLAUDE_CODE_NPM_PACKAGE}" \
    "${CODEX_CLI_NPM_PACKAGE}" \
    "${PLAYWRIGHT_NPM_PACKAGE}" \
    && playwright install --with-deps chromium \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

# Prepare vscode user environment
RUN mkdir -p \
    /home/vscode/.local/share/pnpm \
    /home/vscode/.cache/pip \
    /home/vscode/.cache/uv \
    /home/vscode/.hermes \
    /home/vscode/.m2 \
    /home/vscode/.gradle \
    /home/vscode/go/pkg \
    /home/vscode/go/bin \
    /workspace \
    /ms-playwright \
    && chown -R vscode:vscode /home/vscode /workspace /ms-playwright

COPY sshd_config_devbox /etc/ssh/sshd_config_devbox
COPY --chmod=0755 start-with-gateway.sh /usr/local/bin/start-with-gateway

USER vscode
WORKDIR /workspace

# Re-enable corepack for vscode user
RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version \
    && playwright --version \
    && python --version \
    && java -version \
    && mvn --version \
    && gradle --version \
    && go version \
    && uv --version \
    && gh --version

# tini 作为 PID 1：容器主进程必须负责回收孤儿进程。sshd 的 pre-auth 子进程在
# 遭遇扫描/爆破时会被 reparent 到 PID 1，若 PID 1 不调用 wait()（如 sleep），
# 这些进程退出后会永久停留在 Z 状态并耗尽 PID。tini 内置于镜像，因此无论调用方
# 是否传 `docker run --init` / compose `init: true`，回收行为都成立。
# -s：即使 tini 不是 PID 1（例如调用方又叠了 docker-init）也注册为 child subreaper，
# 保证孤儿仍被收养回收；-g：信号转发给整个进程组，便于 docker stop 干净退出。
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--"]
CMD ["/usr/local/bin/start-with-gateway"]
