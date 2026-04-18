# syntax=docker/dockerfile:1.7

FROM --platform=$TARGETPLATFORM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

ARG NODE_VERSION=22.17.0
ARG PNPM_VERSION=10.8.1
ARG GO_VERSION=1.23.6

ARG CLAUDE_CODE_NPM_PACKAGE="@anthropic-ai/claude-code"
ARG CODEX_CLI_NPM_PACKAGE="@openai/codex"
ARG GEMINI_CLI_NPM_PACKAGE="@google/gemini-cli"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PNPM_HOME=/home/vscode/.local/share/pnpm \
    GOPATH=/home/vscode/go \
    PATH=/home/vscode/.local/share/pnpm:/usr/local/go/bin:/usr/local/bin:/home/vscode/go/bin:$PATH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    build-essential \
    ca-certificates \
    curl \
    dnsutils \
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
    pkg-config \
    rsync \
    software-properties-common \
    sudo \
    telnet \
    time \
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
    maven \
    gradle \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js from official binaries for better multi-arch stability
RUN case "${TARGETARCH}" in \
        amd64) NODE_ARCH='x64' ;; \
        arm64) NODE_ARCH='arm64' ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz \
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

# Install global AI CLIs
RUN npm install -g \
    "${CLAUDE_CODE_NPM_PACKAGE}" \
    "${CODEX_CLI_NPM_PACKAGE}" \
    "${GEMINI_CLI_NPM_PACKAGE}" \
    && npm cache clean --force

# Prepare vscode user environment
RUN mkdir -p \
    /home/vscode/.local/share/pnpm \
    /home/vscode/.cache/pip \
    /home/vscode/.cache/uv \
    /home/vscode/.m2 \
    /home/vscode/.gradle \
    /home/vscode/go/pkg \
    /home/vscode/go/bin \
    /workspace \
    && chown -R vscode:vscode /home/vscode /workspace

USER vscode
WORKDIR /workspace

# Re-enable corepack for vscode user
RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && pnpm --version \
    && python --version \
    && java -version \
    && go version \
    && uv --version

CMD ["sleep", "infinity"]