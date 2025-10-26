# Snappier Server Docker Image

[![Docker Image](https://ghcr.io/rydizz214/snappier-server-docker/badge)](https://ghcr.io/rydizz214/snappier-server-docker)

A production-ready Docker image bundling **Snappier Server CLI** with a **hardened FFmpeg toolchain** and **enhanced notification pipeline** that intelligently enriches recording events with EPG metadata and forwards structured alerts to Pushover.

**Current Version**: `1.3.4a` | **FFmpeg**: Latest | **Architecture**: x64 Linux

---

## ✨ Key Features

### Core Recording & Streaming
- **Snappier Server CLI** – IPTV recording, scheduled downloads, catch-up support
- **Real-time EPG (Electronic Program Guide)** – Browse and search current/upcoming programs
- **PVR (Personal Video Recorder)** – Automatic recording rules, series tracking, episode exclusions
- **Statically-linked FFmpeg** – x264, x265, libvpx, fdk-aac, opus, freetype, fontconfig
- **FFmpeg wrapper** – Automatic HTTP→HTTPS upgrade, network resilience, smart reconnection
- **Catch-up buffer extension** – Automatic 3-minute buffer extension on catch-up downloads to ensure endings don't get cut off
- **Network resilience** – Automatic reconnection with exponential backoff for stream interruptions

### Notifications & Monitoring
- **Intelligent webhook system** – Parses Snappier logs, enriches with EPG metadata, sends to Pushover
- **Structured logging** – Log levels (DEBUG, INFO, WARNING, ERROR) with ISO 8601 timestamps
- **Pushover retry logic** – Exponential backoff (2s → 4s → 8s) ensures no lost notifications
- **Health monitoring** – Background health checker with configurable alert thresholds
- **Request timeouts** – 5-second timeouts on file operations prevent handler hangs

### User Experience
- **Clean channel names** – Strips IPTV provider prefixes (US, CA, UK, etc.) and region suffixes
- **Shortened job IDs** – Full UUID preserved, but display uses first 8 characters
- **Human-friendly timestamps** – Auto-localized to container's `TZ` variable
- **EPG enrichment** – Programs matched by title/timestamp with scoring algorithm
- **TMDB integration** – Optional movie/series metadata enrichment with ratings

---

## Quick Start

### Prerequisites
- **Docker** 24.0+
- **Docker Compose** 2.0+ (optional, but recommended)
- **Pushover credentials** (user key + app token)

### 1. Clone Repository
```bash
git clone https://github.com/rydizz214/snappier-server-docker.git
cd snappier-server-docker
```

### 2. Configure Environment
```bash
# Copy example configuration
cp example.env .env

# Edit with your credentials
nano .env
```

**Required variables**:
```bash
PUSHOVER_USER_KEY=<your-user-key>
PUSHOVER_APP_TOKEN=<your-app-token>
```

### 3. Start Container
```bash
# Using Docker Compose (recommended)
docker compose up -d

# Or with Docker directly
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -p 9080:9080 \
  -e PUSHOVER_USER_KEY="your-key" \
  -e PUSHOVER_APP_TOKEN="your-token" \
  -e TZ="America/New_York" \
  -v snappier-data:/root/SnappierServer \
  ghcr.io/rydizz214/snappier-server-docker:1.3.4a
```

### 4. Verify Health
```bash
# Check webhook is running
curl http://localhost:9080/health | jq .

# View logs
docker compose logs -f snappier-server
```

---

## Configuration Reference

### Core Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `America/New_York` | Container timezone (affects timestamps in logs and notifications) |
| `PORT` | `8000` | Snappier Server listen port (inside container) |
| `HOST_PORT` | `7429` | Host port mapping for Snappier Server |

### Notification Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `PUSHOVER_USER_KEY` | _(required)_ | Your Pushover user key (32-char alphanumeric) |
| `PUSHOVER_APP_TOKEN` | _(required)_ | Your Pushover app token (32-char alphanumeric) |
| `NOTIFICATION_HTTP_PORT` | `9080` | Webhook port (not exposed externally by default) |
| `NOTIFY_TITLE_PREFIX` | `🎬 Snappier` | Prefix for all notification titles |
| `NOTIFY_DESC_LIMIT` | `900` | Max description length in characters |

### Reliability & Retry Logic
| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFY_RETRY_ATTEMPTS` | `3` | Number of Pushover API retry attempts |
| `NOTIFY_RETRY_DELAY` | `2` | Initial retry delay in seconds (exponential backoff) |
| `WEBHOOK_LOG_LEVEL` | `INFO` | Log level: `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `HTTPS_PROBE_TIMEOUT` | `3` | Timeout for HTTPS capability probe (seconds) |

### HTTP/HTTPS Upgrade
| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOW_HTTP` | `0` | Allow insecure HTTP streams (1=yes, 0=no) |
| `ALLOW_HTTP_HOSTS` | `localhost,127.0.0.1,snappier-server` | Comma-separated hosts allowed to use HTTP |

### Catch-up Downloads
| Variable | Default | Description |
|----------|---------|-------------|
| `CATCHUP_EXTENSION_ENABLED` | `1` | Enable duration extension (1=yes, 0=no) |
| `CATCHUP_BUFFER_SECONDS` | `180` | Buffer duration in seconds (default 3 minutes) |
| `CATCHUP_AUDIO_BITRATE` | `384k` | Audio bitrate for transcoding (e.g., 192k, 256k, 384k) |

### EPG & API
| Variable | Default | Description |
|----------|---------|-------------|
| `SNAPPY_API_ENABLED` | `1` | Enable Snappier API for EPG enrichment |
| `SNAPPY_API_BASE` | `http://127.0.0.1:8000` | Snappier Server REST endpoint |
| `SNAPPY_API_TIMEOUT` | `5` | API request timeout (seconds) |
| `EPG_CACHE` | `/root/SnappierServer/epg/epg_cache.json` | EPG cache file location |
| `EPG_INDEX_MAX_SIZE` | `50000` | Max EPG index entries before LRU eviction |

See `example.env` for complete configuration options.

---

## Building Locally

### Build with Defaults
```bash
docker build -t ghcr.io/rydizz214/snappier-server-docker:1.3.4a .
```

### Build with Custom FFmpeg Version
```bash
docker build \
  --build-arg FFMPEG_VERSION=7.1.1 \
  -t ghcr.io/rydizz214/snappier-server-docker:1.3.4a .
```

**Build time**: ~30-45 minutes (FFmpeg compilation)

---

## Troubleshooting

### Notifications Not Sending
1. **Check credentials**:
   ```bash
   docker compose logs snappier-server | grep -i "pushover"
   ```

2. **Test webhook manually**:
   ```bash
   curl -X POST http://localhost:9080/notify \
     -H 'Content-Type: application/json' \
     -d '{"action":"health_warn","desc":"Test alert"}'
   ```

### Container Won't Start
1. **Check logs**:
   ```bash
   docker compose logs snappier-server
   ```

2. **Verify volumes**:
   ```bash
   docker compose exec snappier-server ls -la /root/SnappierServer
   ```

### Missing Channel/Program Metadata
1. **Verify EPG cache**:
   ```bash
   docker compose exec snappier-server \
     ls -lh /root/SnappierServer/epg/epg_cache.json
   ```

2. **Check API connectivity**:
   ```bash
   docker compose exec snappier-server \
     curl http://127.0.0.1:8000/epg/status
   ```

---

## Notification Events

All notifications follow a consistent format with structured JSON payloads:

### Recording Events
- **recording_started** – Scheduled recording began
- **recording_live_started** – "Record now" request (🔴 icon)
- **recording_completed** – Recording finished successfully
- **recording_failed** – Recording failed
- **recording_cancelled** – Recording manually cancelled

### Catch-up Events
- **catchup_started** – Catch-up download initiated
- **catchup_completed** – Catch-up finished
- **catchup_failed** – Catch-up failed

### Movie & Series
- **movie_started** / **movie_completed** / **movie_failed**
- **series_started** / **series_completed** / **series_failed**
- Includes TMDB enrichment (ratings, genres, descriptions) if available

### System Events
- **health_warn** – Health check failed
- **server_error** – General server error
- **server_failed** – Critical server failure

---

## Support & Issue Reporting

### Issues with Snappier Server Itself
For problems with recording, EPG, PVR, or the Snappier Server CLI:
- **Join**: [Snappier Discord Channel](https://discord.gg/KSdU5VrHgM)
- Include Snappier Server version, logs, and detailed reproduction steps
- **Note**: Visit [snappierserver.app](https://snappierserver.app) for complete Snappier Server documentation

### Issues with Docker Image & Notifications
For Docker-specific issues, notification failures, webhook enrichment problems, or build issues:
- **Open GitHub Issue**: [snappier-server-docker/issues](https://github.com/rydizz214/snappier-server-docker/issues)
- Include Docker logs, sanitized configuration, `docker --version`, and reproduction steps

### Pull Requests
- Welcome! Please include test results and update CHANGELOG.md
- See [DEVELOPER.md](DEVELOPER.md) for architecture and development guide

---

## File Structure

```
snappier-server-docker/
├── Dockerfile                          # Multi-stage build: FFmpeg + Runtime
├── docker-compose.yml                  # Reference compose file
├── entrypoint.sh                       # Boot sequence
├── ffmpeg-wrapper.sh                   # HTTP→HTTPS upgrade + resilience
├── example.env                         # Configuration template
├── README.md                           # This file
├── DEVELOPER.md                        # Architecture and development guide
├── RELEASE_NOTES_v1.3.4a.md            # v1.3.4a release notes
├── CHANGELOG.md                        # Full version history
├── notify/
│   ├── enhanced_webhook.py             # Flask webhook with EPG enrichment
│   └── tmdb_helper.py                  # Optional TMDB metadata
└── scripts/
    ├── log_monitor.sh                  # Log tailer & event parser
    ├── health_watcher.py               # Health check monitor
    ├── schedule_watcher.py             # Recording schedule watcher
    ├── log_rotate.sh                   # Log rotation & cleanup
    └── timestamp_helpers.py            # Shared timestamp utilities
```

---

## Acknowledgments

- **Snappier Server** – Core recording, PVR, and EPG functionality
- **FFmpeg** community – Video encoding/transcoding
- **Pushover** – Notification delivery service
- Contributors to this Docker wrapper and notification pipeline

---

## License

MIT License – See [LICENSE](LICENSE) for details.

---

**Happy recording! 🎬**

For questions about Snappier Server features, join the [Snappier Discord](https://discord.gg/KSdU5VrHgM). For Docker or notification issues, open a [GitHub Issue](https://github.com/rydizz214/snappier-server-docker/issues).

