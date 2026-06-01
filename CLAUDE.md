# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

This repository defines `dev-box`, a multi-architecture development container image published to GitHub Container Registry. The repository is intentionally small: `Dockerfile` is the source of truth for the image contents, and `.github/workflows/docker.yml` builds and publishes it.

## Common commands

- Build the image locally for the current platform:
  ```bash
  docker build -t dev-box:local .
  ```
- Build with explicit toolchain versions:
  ```bash
  docker build \
    --build-arg NODE_VERSION=22.17.0 \
    --build-arg PNPM_VERSION=10.8.1 \
    --build-arg GO_VERSION=1.23.6 \
    -t dev-box:local .
  ```
- Run an interactive shell in the built image:
  ```bash
  docker run --rm -it dev-box:local bash
  ```
- Verify the main installed toolchains inside the image:
  ```bash
  docker run --rm dev-box:local bash -lc 'node --version && pnpm --version && playwright --version && python --version && uv --version && go version && java -version && mvn --version && gradle --version'
  ```
- Verify bundled Chromium can launch through Playwright:
  ```bash
  docker run --rm dev-box:local bash -lc 'playwright screenshot --browser=chromium about:blank /tmp/chromium.png'
  ```
- Build the same platforms as CI without pushing:
  ```bash
  docker buildx build --platform linux/amd64,linux/arm64 -t dev-box:local .
  ```

## Tests and linting

No language-specific test suite or linter is configured in this repository. Use `docker build -t dev-box:local .` as the primary validation after Dockerfile changes, then run the Playwright Chromium launch check when browser-related layers change. There is no single-test command.

## Architecture notes

- `Dockerfile` starts from `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` and uses `TARGETPLATFORM`, `TARGETOS`, and `TARGETARCH` for multi-architecture builds.
- Tool versions are controlled by Docker build args: `NODE_VERSION`, `PNPM_VERSION`, and `GO_VERSION`. Prefer updating these defaults over hard-coding versions elsewhere.
- System packages install common development tooling, Python, Java 21, Maven, Gradle, Git LFS, browser fonts, and network/debugging utilities.
- Node.js and Go are installed from upstream release archives with `TARGETARCH`-based architecture mapping. Keep those `case` mappings in sync if adding architecture support.
- `uv` is installed from Astral's installer and copied to `/usr/local/bin` with `uvx`.
- Global AI CLIs are installed through npm package args: Claude Code, OpenAI Codex CLI, and Gemini CLI.
- Chromium is installed through Playwright into `/ms-playwright` to keep browser automation compatible with both `linux/amd64` and `linux/arm64` builds.
- The final image runs as the `vscode` user with `WORKDIR /workspace`; cache and tool directories under `/home/vscode` plus `/ms-playwright` are precreated and owned by `vscode`.
- `.github/workflows/docker.yml` uses QEMU and Docker Buildx to publish `linux/amd64` and `linux/arm64` images to GHCR on pushes to `main`, `v*` tags, and manual `workflow_dispatch` runs.
- Docker metadata tags include `latest` for the default branch, branch refs, tag refs, and `sha-*` tags.

## Change guidance

- When changing installed tooling, update `README.md` if the user-facing image contents change.
- For version bumps, update the corresponding Dockerfile `ARG` default and validate with a rebuild.
- Before modifying the publish workflow, check how `docker/metadata-action` tags and labels will change for branch, tag, and SHA builds.
