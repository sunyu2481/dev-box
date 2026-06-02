# dev-box

A multi-architecture development container image built with GitHub Actions and published to GitHub Container Registry (GHCR).

## Features

- Ubuntu 24.04 base
- Node.js 24
- pnpm 11
- Python
- uv
- Go 1.26
- Java 21
- Maven 3.9
- Gradle 9
- Git / Git LFS
- Chromium for browser automation via Playwright
- Browser fonts for CJK, emoji, and common web rendering
- Common development tools
- AI CLI tools:
  - Claude Code
  - OpenAI Codex CLI
  - Gemini CLI
  - Hermes agent

## Image

```bash
docker pull ghcr.io/sunyu2481/dev-box:latest