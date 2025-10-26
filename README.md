# Snappier Server Docker Image

[![Docker Image](https://ghcr.io/rydizz214/snappier-server-docker/badge)](https://ghcr.io/rydizz214/snappier-server-docker)

A production-ready Docker image bundling **Snappier Server CLI** with a **hardened FFmpeg toolchain** and **enhanced notification pipeline** that intelligently enriches recording events with EPG metadata and forwards structured alerts to Pushover.

**Current Version**: `1.3.4a` | **FFmpeg**: Latest | **Architecture**: x64 Linux

---

## ✨ Key Features

### Core Recording & Streaming
- **Snappier Server CLI** – IPTV recording, scheduled downloads, catch-up support
- **Statically-linked FFmpeg** – x264, x265, libvpx, fdk-aac, opus, freetype, fontconfig
- **HTTP→HTTPS upgrade** – Automatic protocol upgrade for insecure sources (configurable)
- **Network resilience** – Automatic reconnection with exponential backoff for stream interruptions
- **Catch-up buffer extension** – Configurable 3-minute extension on catch-up downloads to prevent truncation

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

### Developer-Friendly
- **Comprehensive logging** – Easily filterable structured logs for debugging
- **Configuration validation** – Startup checks for Pushover credentials
- **Error handling** – Graceful degradation with clear error messages
- **Docker Compose support** – Reference configuration with sane defaults

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

### Retry & Reliability
| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFY_RETRY_ATTEMPTS` | `3` | Number of Pushover API retry attempts |
| `NOTIFY_RETRY_DELAY` | `2` | Initial retry delay in seconds (exponential backoff) |
| `HTTPS_PROBE_TIMEOUT` | `3` | Timeout for HTTPS capability probe (seconds) |
| `HTTPS_PROBE_METHOD` | `HEAD` | HTTP method for probe: `HEAD` or `GET` |

### HTTP/HTTPS Upgrade
| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOW_HTTP` | `0` | Allow insecure HTTP streams (1=yes, 0=no) |
| `ALLOW_HTTP_HOSTS` | `localhost,127.0.0.1,snappier-server` | Comma-separated hosts allowed to use HTTP |

### Logging
| Variable | Default | Description |
|----------|---------|-------------|
| `WEBHOOK_LOG_LEVEL` | `INFO` | Log level: `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `FFMPEG_WRAPPER_LOG` | `/logs/ffmpeg_wrapper.log` | FFmpeg wrapper log location |

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

### Logging Paths
| Variable | Default | Description |
|----------|---------|-------------|
| `LOG` | `/root/SnappierServer/server.log` | Snappier Server log file (tailed by monitor) |
| `SNAP_LOG_FILE` | `/root/SnappierServer/server.log` | Alternative log path variable |

---

## Architecture

```
┌─────────────────────────────────────────┐
│     Docker Container                    │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Snappier Server CLI (Port 8000)│   │
│  │  - Recordings                   │   │
│  │  - Scheduled Downloads          │   │
│  │  - Catch-up Support             │   │
│  └──────────┬──────────────────────┘   │
│             │                           │
│             ▼                           │
│  ┌─────────────────────────────────┐   │
│  │  Log Monitor (log_monitor.sh)   │   │
│  │  - Tails /root/SnappierServer/  │   │
│  │    server.log                   │   │
│  │  - Parses events via regex      │   │
│  │  - Extracts metadata            │   │
│  └──────────┬──────────────────────┘   │
│             │                           │
│             ▼                           │
│  ┌─────────────────────────────────┐   │
│  │ Enhanced Webhook (Port 9080)    │   │
│  │ - Enriches with EPG metadata    │   │
│  │ - Cleans channel names          │   │
│  │ - Validates payloads            │   │
│  │ - Retries on failure            │   │
│  └──────────┬──────────────────────┘   │
│             │                           │
│             ▼                           │
│  ┌─────────────────────────────────┐   │
│  │    Pushover API (External)      │   │
│  │    - Send notifications         │   │
│  │    - Priority-based alerts      │   │
│  └─────────────────────────────────┘   │
│                                         │
│  Background Helpers:                    │
│  ┌────────────────────────────────┐    │
│  │ health_watcher.py - Poll       │    │
│  │ schedule_watcher.py - Monitor  │    │
│  │ log_rotate.sh - Maintenance    │    │
│  └────────────────────────────────┘    │
│                                         │
└─────────────────────────────────────────┘
```

---

## Notification Events

All notifications follow a consistent format with structured JSON payloads:

### Recording Events
- **recording_started** – Scheduled recording began (includes start/end times)
- **recording_live_started** – "Record now" request started (🔴 icon)
- **recording_completed** – Recording finished successfully
- **recording_failed** – Recording failed with error details
- **recording_cancelled** – Recording manually cancelled

### Catch-up Events
- **catchup_started** – Catch-up download initiated
- **catchup_completed** – Catch-up finished
- **catchup_failed** – Catch-up failed (network error, etc.)

### Movie & Series
- **movie_started** / **movie_completed** / **movie_failed**
- **series_started** / **series_completed** / **series_failed**
- Includes TMDB enrichment (ratings, genres, descriptions) if available

### System Events
- **health_warn** – Health check failed (after threshold)
- **server_error** – General server error
- **server_failed** – Critical server failure

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

### Build Arguments
| Argument | Default | Description |
|----------|---------|-------------|
| `SNAPPIER_SERVER_VERSION` | `1.3.4a` | Snappier Server CLI version |
| `SNAPPIER_SERVER_ARCH` | `linux-x64` | Snappier binary architecture |
| `FFMPEG_VERSION` | `latest` | FFmpeg version (`latest` or `7.1.1`) |

**Build time**: ~30-45 minutes (FFmpeg compilation)

---

## Publishing to GHCR

```bash
# Authenticate (one-time setup)
echo "${GHCR_TOKEN}" | docker login ghcr.io -u rydizz214 --password-stdin

# Push image
docker push ghcr.io/rydizz214/snappier-server-docker:1.3.4a

# Also tag as latest
docker tag ghcr.io/rydizz214/snappier-server-docker:1.3.4a \
           ghcr.io/rydizz214/snappier-server-docker:latest
docker push ghcr.io/rydizz214/snappier-server-docker:latest
```

---

## Troubleshooting

### Notifications Not Sending
1. **Check credentials**:
   ```bash
   docker compose logs snappier-server | grep -i "pushover"
   ```
   Look for: `Pushover credentials configured` or `ERROR` messages.

2. **Test webhook manually**:
   ```bash
   curl -X POST http://localhost:9080/notify \
     -H 'Content-Type: application/json' \
     -d '{"action":"health_warn","desc":"Test alert"}'
   ```

3. **Check log level**:
   ```bash
   # Enable DEBUG logging
   docker compose exec snappier-server \
     bash -c 'export WEBHOOK_LOG_LEVEL=DEBUG && /opt/notify/enhanced_webhook.py'
   ```

### Container Won't Start
1. **Check entrypoint logs**:
   ```bash
   docker compose logs snappier-server
   ```

2. **Verify volumes are mounted**:
   ```bash
   docker compose exec snappier-server ls -la /root/SnappierServer
   ```

3. **Check port conflicts**:
   ```bash
   lsof -i :7429 -i :9080 -i :8000
   ```

### Slow Notifications
1. **Check EPG cache size**:
   ```bash
   curl http://localhost:9080/health | jq .cache_stats
   ```

2. **Enable debug logging** to see where time is spent:
   ```bash
   # Set in .env
   WEBHOOK_LOG_LEVEL=DEBUG
   docker compose restart snappier-server
   ```

### Missing Channel/Program Metadata
1. **Verify EPG cache exists**:
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

## Development

### Adding Custom Event Types
1. Update `scripts/log_monitor.sh` to detect new event patterns
2. Add to `_ACTION_MAP` in `notify/enhanced_webhook.py`
3. Add formatting logic in `_format_for_pushover()`
4. Test with manual webhook calls

### Modifying Channel Cleaning
1. Edit `clean_channel_name()` in `notify/enhanced_webhook.py` (line ~67)
2. Also update `clean_channel()` in `scripts/log_monitor.sh` if applicable
3. Test with various channel names

### Performance Tuning
- Increase `EPG_INDEX_MAX_SIZE` if you have large EPG (slower startup, faster lookups)
- Decrease `NOTIFY_RETRY_ATTEMPTS` if you want faster failure feedback
- Adjust `WEBHOOK_LOG_LEVEL` to `WARNING` in production to reduce I/O

---

## Environment Files

### example.env
Template with all available options and their defaults. Copy to `.env` and customize.

### .env (Your Settings)
⚠️ **Not committed to git** – Add to `.gitignore` to prevent credential leakage.

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
├── CHANGELOG.md                        # Release notes
├── CLAUDE.md                           # AI assistant guidelines
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

## License

MIT License – See [LICENSE](LICENSE) for details.

---

## Support

- **Issues**: Open a GitHub issue with logs and configuration details
- **Pull Requests**: Welcome! Please include test results and update CHANGELOG.md
- **Questions**: Check [CLAUDE.md](CLAUDE.md) for architecture details

---

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed release notes.

**Latest**: v1.3.4a
- ✨ Structured logging with log levels
- 🔄 Pushover retry logic with exponential backoff
- ✅ Credential validation on startup
- ⏱️ Request timeouts for file operations
- 🐛 Catchup notification improvements
- 🎯 Enhanced error handling & validation

