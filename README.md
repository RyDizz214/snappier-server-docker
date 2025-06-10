# Snappier-Server Docker

**Snappier-Server** is a self-hosted, lightweight recording and streaming service packaged in Docker with integrated push notification support.

## Table of Contents

* [Features](#features)
* [Prerequisites](#prerequisites)
* [Directory Structure](#directory-structure)
* [Configuration](#configuration)
* [Building the Docker Image](#building-the-docker-image)
* [Running with Docker Compose](#running-with-docker-compose)
* [Environment Variables](#environment-variables)
* [Version Bump and Tagging](#version-bump-and-tagging)
* [Healthcheck](#healthcheck)
* [Contributing](#contributing)
* [License](#license)

## Features

* Multi-arch support (amd64, arm64)
* FFmpeg-based recording and streaming
* Push notification service (Pushover, ntfy.sh, Telegram, Discord)
* Integrated webhook monitor and log forwarder
* Health check endpoint at `/serverStats`
* Easy environment-based configuration via `.env`

## Prerequisites

* Docker 20.10+ and Docker Compose 1.29+
* Git (for source and tags)
* A GitHub account with Container Registry access (ghcr.io)

## Directory Structure

```bash
snappier-server-docker/
├── Dockerfile
├── docker-compose.yml
├── example.env            # Copy to .env and fill in
├── .gitignore
├── README.md
├── headless-entrypoint.sh
├── notification-service/  # Node notifier in its own layer
│   ├── package.json
│   └── push-service.js
├── enhanced-node-notifier.js
├── snappier-webhook.js
└── notification_client.py
```

## Configuration

1. Copy `example.env` to `.env`:

   ```bash
   cp example.env .env
   ```
2. Edit `.env` and set your values.

```bash
remov
```

## Running with Docker Compose

```bash
docker compose up -d --build
```

## Environment Variables

| Variable                   | Default | Description                              |
| -------------------------- | ------- | ---------------------------------------- |
| `SNAPPIER_SERVER_VERSION`  | `1.0.0` | Version to download and run              |
| `PORT`                     | `8000`  | Service listen port                      |
| `HOST_PORT`                | `7429`  | Host port mapped to `PORT`               |
| `NOTIFY_HTTP_PORT`         | `9080`  | HTTP port for notification service       |
| `NOTIFY_WS_PORT`           | `9081`  | WebSocket port for notification service  |
| `USE_CURL_TO_DOWNLOAD`     | `false` | Use curl instead of FFmpeg for downloads |
| `DOWNLOAD_SPEED_LIMIT_MBS` | `0`     | Download rate limit (0 = no limit)       |
| `PUSHOVER_USER_KEY`        | \*      | Pushover user key (optional)             |
| `PUSHOVER_API_TOKEN`       | \*      | Pushover API token (optional)            |
| `NTFY_TOPIC`               | \*      | ntfy.sh topic (optional)                 |
| `TELEGRAM_TOKEN`           | \*      | Telegram bot token (optional)            |
| `TELEGRAM_CHAT_ID`         | \*      | Telegram chat ID (optional)              |
| `DISCORD_WEBHOOK_URL`      | \*      | Discord webhook URL (optional)           |

> **Note:** `*` = empty by default; fill these in `.env`.

## Healthcheck

The container exposes a health endpoint:

```
http://localhost:${PORT}/serverStats
```

Use this for liveness/readiness probes.

## Contributing

1. Fork the repo
2. Create a feature branch
3. Implement and test
4. Submit a pull request

## License

This project is licensed under the MIT License.
