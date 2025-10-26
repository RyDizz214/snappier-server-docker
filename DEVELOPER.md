# DEVELOPER.md

This file provides guidance for developers and contributors working on this repository.

## Project Overview

This repository builds `ghcr.io/rydizz214/snappier-server-docker`, a Docker image that bundles:
- **Snappier Server CLI** (v1.3.4a) - IPTV recording server by Sarah Bainbridge
- **FFmpeg toolchain** - statically linked with x264/x265, libvpx, fdk-aac, opus, etc.
- **Enhanced notification pipeline** - Python webhook that intelligently enriches events with EPG metadata and forwards to Pushover

### Core Features

**Real-time EPG (Electronic Program Guide)**
- Browse current and upcoming programs across channels
- View program titles, descriptions, and air times
- Support for multiple EPG sources with priority settings
- Automatic refresh intervals (typically every 24 hours)
- Used by the notification system for program metadata enrichment

**PVR (Personal Video Recorder)**
- Automatic recording rules that monitor EPG data
- Series recording: Continuously records all matching future episodes
- One-time recording: Records a single program instance
- Exclusion rules: Prevents specific episodes from auto-scheduling
- Manual control: Enable/disable rules, adjust matching criteria, manage schedules
- Works seamlessly with this Docker image for scheduling and notification

See [snappierserver.app](https://snappierserver.app) for complete Snappier Server documentation.

## Build & Development Commands

### Building the Docker Image
```bash
docker build -t ghcr.io/rydizz214/snappier-server-docker:1.3.4a .
```

### Publishing to GHCR (Maintainers Only)
```bash
# Authenticate once (requires GitHub PAT with package:write scope)
echo "${GHCR_TOKEN}" | docker login ghcr.io -u rydizz214 --password-stdin

# Push the image
docker push ghcr.io/rydizz214/snappier-server-docker:1.3.4a

# Also tag as latest
docker tag ghcr.io/rydizz214/snappier-server-docker:1.3.4a ghcr.io/rydizz214/snappier-server-docker:latest
docker push ghcr.io/rydizz214/snappier-server-docker:latest
```

**Note**: Only maintainers with GHCR push credentials need to run these commands.

### Local Testing with Docker Compose
```bash
# Copy example.env to .env and configure Pushover credentials first
docker compose up -d

# View logs
docker compose logs -f snappier-server

# Filter for notification events
docker compose logs -f snappier-server | grep notify

# Stop the container
docker compose down
```

## Architecture Overview

### Boot Sequence (entrypoint.sh)
The container startup follows this sequence:

1. **Initialize directories** - Creates `/logs`, `/root/SnappierServer/epg`, and media folders
2. **Start notification webhook** (`enhanced_webhook.py` on port 9080)
   - Flask app that receives events via POST to `/notify`
   - Enriches payloads with EPG metadata from cache
   - Forwards to Pushover with cleaned channel names and formatted timestamps
3. **Start helper processes** (all run in background):
   - `health_watcher.py` - Polls `/serverStats` endpoint, sends alerts on failure
   - `schedule_watcher.py` - Watches scheduled recordings
   - `log_monitor.sh` - Tails `server.log`, parses events, posts to webhook
   - `log_rotate.sh` - Keeps log files bounded
4. **Launch Snappier Server CLI** - Main recording server process

All helpers output to `/logs/*.log` and are killed on container stop.

### Notification Pipeline

The notification system has **two parallel paths**:

#### Path 1: Log Monitor (Primary)
`scripts/log_monitor.sh` → `notify/enhanced_webhook.py` → Pushover

- **log_monitor.sh** tails `/root/SnappierServer/server.log` using `tail -F`
- Parses log lines with regex to detect events:
  - Recording started (live and scheduled)
  - Recording cancelled (code 255 from `saveLiveWithFFmpeg`)
  - Catch-up downloads (started/completed/failed)
  - FFmpeg errors
- Extracts metadata from TS filename patterns:
  - Recording: `Channel--Program--START--END--UUID.ts`
  - Catch-up: `--Program--START--UUID.ts`
- POSTs JSON to `http://127.0.0.1:9080/notify` with structured fields

#### Path 2: Snappier API (Fallback)
Direct API calls to Snappier Server for additional metadata

- Used as fallback when log monitor doesn't provide channel info
- Queries `/epg/search` endpoint for program enrichment
- Caches results to minimize API load

### Webhook Enrichment (enhanced_webhook.py)

The Flask webhook receives events and:

1. **Cleans channel names**:
   - Strips IPTV provider prefixes (US, CA, UK, AU, etc.)
   - Removes region suffixes like `.us`, `.ca`
   - Normalizes underscores and pipes
2. **Looks up EPG metadata**:
   - Reads `/root/SnappierServer/epg/epg_cache.json` (if fresh)
   - Optionally calls `SNAPPY_API_BASE/channels` for live channel data
   - Matches programs by name and timestamp
3. **Formats timestamps**:
   - Parses ISO 8601 and XMLTV datetime formats
   - Converts to container's `TZ` for human-friendly display
4. **Shortens job IDs**:
   - UUIDs shortened to first 8 chars for readability
   - Full UUID preserved as `job_id_full`
5. **Forwards to Pushover**:
   - Uses `PUSHOVER_USER_KEY` and `PUSHOVER_APP_TOKEN`
   - Sets priority based on event type (failures = priority 1)

### FFmpeg Wrapper (ffmpeg-wrapper.sh)

The wrapper intercepts FFmpeg calls to:

- **Upgrade HTTP → HTTPS** (if remote server supports HTTPS and host is not in `ALLOW_HTTP_HOSTS`)
- **Add network resilience flags** (`-reconnect`, `-rw_timeout`, etc.) for HTTP/HTTPS inputs
- **Pass through file operations** without extra flags

Controlled by environment variables:
- `ALLOW_HTTP=1` - Skip HTTPS upgrade entirely
- `ALLOW_HTTP_HOSTS` - Comma-separated list of hosts allowed to use HTTP (default: `localhost,127.0.0.1,snappier-server`)
- `HTTPS_PROBE_TIMEOUT=3` - Seconds to wait for HTTPS probe
- `HTTPS_PROBE_METHOD=HEAD` - Method for probe (HEAD or GET)

## Configuration

### Required Environment Variables
- `PUSHOVER_USER_KEY` / `PUSHOVER_APP_TOKEN` - Pushover credentials for alerts

### Key Optional Variables
- `TZ=America/New_York` - Timezone for logs and notification timestamps
- `NOTIFICATION_HTTP_PORT=9080` - Webhook port (set to `0` to disable notifications)
- `SNAPPY_API_BASE=http://127.0.0.1:8000` - REST endpoint for EPG enrichment
- `LOG=/root/SnappierServer/server.log` - Log file path for monitor
- `ENABLE_EPG=1` - Enable EPG fetching
- `ENABLE_REMUX=1` - Enable post-recording remux
- `DOWNLOAD_SPEED_LIMIT_MBS=0` - Speed limit in MB/s (0 = unlimited)

### New in v1.3.4a - Production Reliability & Observability

#### Structured Logging System
- `WEBHOOK_LOG_LEVEL=INFO` - Log level: DEBUG, INFO, WARNING, ERROR (default: INFO)
- ISO 8601 timestamps on all log entries
- Separate stderr for errors and warnings
- All print statements replaced with structured logging

#### Pushover Retry Logic with Exponential Backoff
- `NOTIFY_RETRY_ATTEMPTS=3` - Number of retry attempts (default: 3)
- `NOTIFY_RETRY_DELAY=2` - Initial retry delay in seconds (exponential backoff: 2s → 4s → 8s)
- Handles timeouts, connection errors, and API errors separately
- Detailed retry logging for troubleshooting

#### Startup Credential Validation
- Pushover credentials validated on webhook startup
- Clear error messages if missing
- Masked credential display in logs

#### Request Timeouts
- 5-second timeout on all JSON file operations (EPG, schedules)
- Prevents handler hangs from slow filesystem/NFS issues

#### Catch-up Download Extension (v1.2.8+)
- `CATCHUP_EXTENSION_ENABLED=1` - Enable 3-minute buffer for catch-up downloads (default: enabled)
- `CATCHUP_BUFFER_SECONDS=180` - Buffer time in seconds (default: 180 = 3 minutes)
- `FFMPEG_WRAPPER_LOG=/logs/ffmpeg_wrapper.log` - FFmpeg wrapper log location

#### Performance & Reliability
- `EPG_INDEX_MAX_SIZE=50000` - Max EPG cache entries before eviction (prevents memory bloat)
- `HTTPS_CACHE_MAX_SIZE=1000` - Max HTTPS capability cache entries (LRU eviction)
- `REGEX_TIMEOUT_SEC=1` - Timeout for regex operations (prevents ReDoS attacks)

See `example.env` for full list.

## File Structure

```
/opt/snappier-server/           # Build context root
├── Dockerfile                  # Multi-stage build: base → snappier-server → final
├── entrypoint.sh               # Boot sequence (notify + helpers + CLI)
├── ffmpeg-wrapper.sh           # HTTP→HTTPS upgrade + network flags
├── README.md                   # User guide and quick start
├── DEVELOPER.md                # This file - architecture and development guide
├── RELEASE_NOTES_v1.3.4a.md    # v1.3.4a release notes
├── notify/
│   ├── enhanced_webhook.py     # Flask webhook with EPG enrichment + retry logic
│   └── tmdb_helper.py          # Optional TMDB metadata enrichment
└── scripts/
    ├── log_monitor.sh          # Tail server.log, parse events, POST to webhook
    ├── log_rotate.sh           # Rotate logs to prevent unbounded growth
    ├── health_watcher.py       # Poll /serverStats, alert on failure
    ├── schedule_watcher.py     # Watch scheduled recordings
    └── timestamp_helpers.py    # Shared timestamp parsing utilities

/root/SnappierServer/           # Runtime directory (inside container)
├── server.log                  # Main Snappier log (tailed by monitor)
├── schedules.json              # Scheduled recordings
├── epg/epg_cache.json          # EPG metadata cache
├── Recordings/                 # Live recordings
├── Movies/                     # Downloaded movies
├── TVSeries/                   # Downloaded TV series
└── PVR/                        # PVR recordings

/logs/                          # Helper logs
├── notify.log                  # Webhook output
├── log_monitor.log             # Monitor output
├── health_watcher.log
├── schedule_watcher.log
└── log_rotate_runner.log
```

## Notification Event Types

All events are sent to webhook with `action` field matching one of:

### Recording Events
- `recording_started` - Scheduled recording began (includes start time)
- `recording_live_started` - "Record now" request (uses 🔴 icon)
- `recording_cancelled` - Recording cancelled (recovers metadata from log tail)
- `recording_completed` - Recording finished successfully
- `recording_failed` - Recording failed

### Catch-up Events
- `catchup_started` - Catch-up download began
- `catchup_completed` - Catch-up finished
- `catchup_failed` - Catch-up failed

### System Events
- `health_warn` - Health check failed (after threshold)
- `server_error` - General server error

All failure/warning events use ❗ icon for consistency.

## Common Development Patterns

### Modifying Notification Behavior

1. **Change channel name cleaning**:
   - Edit `clean_channel_name()` in `notify/enhanced_webhook.py:29`
   - Also update `clean_channel()` in `scripts/log_monitor.sh:99` (Python block)

2. **Add new event type**:
   - Add regex pattern in `scripts/log_monitor.sh` (search for existing patterns like `"Cancelled recording"`)
   - Add corresponding action to `_ACTION_MAP` in `notify/enhanced_webhook.py`
   - Update `_format_for_pushover()` to handle new action

3. **Change notification priority**:
   - Edit `priority=` logic in `notify/enhanced_webhook.py` `_format_for_pushover()` function

### Testing Log Monitoring

```bash
# Tail the log monitor output
docker compose exec snappier-server tail -f /logs/log_monitor.log

# Manually trigger a test event (inside container)
docker compose exec snappier-server bash -c 'echo "[$(date)] Started recording /root/SnappierServer/Recordings/Test--Program--20250101120000--20250101130000--test-uuid-1234.ts" >> /root/SnappierServer/server.log'
```

### Debugging Webhook

```bash
# Check webhook health
curl http://localhost:9080/health

# Send test notification
curl -X POST http://localhost:9080/notify \
  -H 'Content-Type: application/json' \
  -d '{"action":"recording_started","channel":"Test","program":"Test Program","job_id":"test-1234"}'

# View webhook logs
docker compose exec snappier-server tail -f /logs/notify.log
```

## Version Management

- Current version: **1.3.4a**
- Version is set via `SNAPPIER_SERVER_VERSION` build arg (default: 1.3.4a)
- Update `docker-compose.yml` `SNAPPIER_SERVER_VERSION` env var to match
- When bumping version:
  1. Update version in build command
  2. Update `CHANGELOG.md` with detailed changes
  3. Create `RELEASE_NOTES_v<version>.md` with comprehensive notes
  4. Update references to old version throughout docs
  5. Tag release in git: `git tag -a v<version>`
  6. Push to GHCR with new version tag: `docker push ghcr.io/rydizz214/snappier-server-docker:<version>`
  7. Also tag as latest if appropriate

## Support & Issue Reporting

### Issues with Snappier Server Binary
For issues related to the Snappier Server CLI itself (recording problems, EPG issues, PVR functionality, etc.):
- **Report to**: [Snappier Discord Channel](https://discord.gg/snappier)
- Include: Snappier Server version, logs from `/root/SnappierServer/server.log`, reproduction steps
- Mention: Whether the issue occurs in Docker or native installation

### Issues with Docker Image/Notification Pipeline
For issues specific to this Docker image, notification system, or webhook enrichment:
- **Report to**: [GitHub Issues](https://github.com/rydizz214/snappier-server-docker/issues)
- Include: Docker logs, configuration (sanitized), reproduction steps, `docker --version`
- Categories:
  - Notification failures or delays
  - Docker build issues
  - Webhook/enrichment problems
  - Documentation or configuration clarifications

### General Questions
- Snappier Server questions → Snappier Discord
- Docker deployment questions → GitHub Issues
- Development/contribution questions → GitHub Issues or Pull Requests

## Contributing

1. Fork the repository and create a feature branch
2. Make your changes and test locally:
   ```bash
   docker build -t snappier-test:latest .
   docker compose -f docker-compose.yml up -d
   ```
3. Update relevant documentation (README.md, DEVELOPER.md, example.env)
4. Update CHANGELOG.md with your changes
5. Test all 20 notification types (see Testing Log Monitoring section)
6. Create a pull request with detailed description of changes

## Acknowledgments

- **Snappier Server** by Sarah Bainbridge - Core recording and PVR functionality
- **FFmpeg** community - Video encoding/transcoding
- **Pushover** - Notification delivery service
- Contributors to this Docker wrapper and notification pipeline
