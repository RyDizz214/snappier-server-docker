# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository builds `ghcr.io/rydizz214/snappier-server-docker`, a Docker image that bundles:
- **Snappier Server CLI** (v1.2.8) - IPTV recording server
- **FFmpeg toolchain** - statically linked with x264/x265, libvpx, fdk-aac, opus, etc.
- **Enhanced notification pipeline** - Python webhook + Node.js shim that enriches events with EPG metadata and forwards to Pushover

## Build & Development Commands

### Building the Docker Image
```bash
docker build -t ghcr.io/rydizz214/snappier-server-docker:1.2.8 .
```

### Publishing to GHCR
```bash
# Authenticate once (requires GitHub PAT with package:write scope)
echo "${GHCR_TOKEN}" | docker login ghcr.io -u rydizz214 --password-stdin

# Push the image
docker push ghcr.io/rydizz214/snappier-server-docker:1.2.8
```

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

#### Path 2: Node Notifier Shim (Optional)
`notify/enhanced-node-notifier.js` → webhook

- Can replace Snappier's built-in `node-notifier` module
- Intercepts `.notify()` calls, parses them, and forwards to webhook
- **Note**: Using both paths may cause duplicate notifications

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

### New in v1.2.8 - Bug Fixes & Features

#### Catch-up Download Extension
- `CATCHUP_EXTENSION_ENABLED=1` - Enable 3-minute buffer for catch-up downloads (default: enabled)
- `CATCHUP_BUFFER_SECONDS=180` - Buffer time in seconds (default: 180 = 3 minutes)
- `FFMPEG_WRAPPER_LOG=/logs/ffmpeg_wrapper.log` - FFmpeg wrapper log location

#### Performance & Reliability
- `EPG_INDEX_MAX_SIZE=50000` - Max EPG cache entries before eviction (prevents memory bloat)
- `HTTPS_CACHE_MAX_SIZE=1000` - Max HTTPS capability cache entries (LRU eviction)
- `NOTIFY_RETRY_ATTEMPTS=3` - Number of notification POST retry attempts
- `NOTIFY_RETRY_DELAY=2` - Initial retry delay in seconds (exponential backoff)
- `REGEX_TIMEOUT_SEC=1` - Timeout for regex operations (prevents ReDoS attacks)

See `example.env` for full list.

## File Structure

```
/opt/snappier-server/           # Build context root
├── Dockerfile                  # Multi-stage build: base → snappier-server → final
├── entrypoint.sh               # Boot sequence (notify + helpers + CLI)
├── ffmpeg-wrapper.sh           # HTTP→HTTPS upgrade + network flags
├── notify/
│   ├── enhanced_webhook.py     # Flask webhook with EPG enrichment
│   └── enhanced-node-notifier.js  # Optional node-notifier shim
└── scripts/
    ├── log_monitor.sh          # Tail server.log, parse events, POST to webhook
    ├── log_rotate.sh           # Rotate logs to prevent unbounded growth
    ├── health_watcher.py       # Poll /serverStats, alert on failure
    └── schedule_watcher.py     # Watch scheduled recordings

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

- Version is set via `SNAPPIER_SERVER_VERSION` build arg (default: 1.2.8)
- Update `docker-compose.yml` `SNAPPIER_SERVER_VERSION` env var to match
- When bumping version:
  1. Update version in build command
  2. Update `CHANGELOG.md`
  3. Tag release in git
  4. Push to GHCR with new version tag
