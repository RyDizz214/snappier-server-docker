#!/usr/bin/env bash
set -euo pipefail

log(){ printf "[entrypoint] %s %s\n" "$(date -u +%FT%TZ)" "$*"; }

# -----------------------------
# Core env (with sane defaults)
# -----------------------------
PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"
TZ="${TZ:-America/New_York}"

ENABLE_EPG="${ENABLE_EPG:-0}"
EPG_URL="${EPG_URL:-}"
# Support both EPG_URLS_JSON and legacy EPG_URLS
EPG_URLS_JSON="${EPG_URLS_JSON:-${EPG_URLS:-}}"
EPG_INTERVAL_HOURS="${EPG_INTERVAL_HOURS:-${EPG_REFRESH_INTERVAL:-24}}"

ENABLE_REMUX="${ENABLE_REMUX:-0}"
DOWNLOAD_SPEED_LIMIT_MBS="${DOWNLOAD_SPEED_LIMIT_MBS:-0}"

RECORDINGS_DIR="${RECORDINGS_DIR:-/root/SnappierServer/Recordings}"
MOVIES_DIR="${MOVIES_DIR:-/root/SnappierServer/Movies}"
SERIES_DIR="${SERIES_DIR:-/root/SnappierServer/TVSeries}"

SNAP_LOG_FILE="${SNAP_LOG_FILE:-/logs/snappier.log}"
EPG_CACHE="${EPG_CACHE:-/root/SnappierServer/epg/epg_cache.json}"
SCHEDULES="${SCHEDULES:-/root/SnappierServer/schedules.json}"

# Notify (Flask webhook)
NOTIFICATION_HTTP_PORT="${NOTIFICATION_HTTP_PORT:-9080}"
NOTIFICATION_BIND="${NOTIFICATION_BIND:-127.0.0.1}"   # keep private
NOTIFICATION_SSE_PATH="${NOTIFICATION_SSE_PATH:-/events}"

# Health monitor helpers
HEALTH_INTERVAL_SEC="${HEALTH_INTERVAL_SEC:-30}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/serverStats}"
SNAPPY_API_BASE="${SNAPPY_API_BASE:-http://127.0.0.1:8000}"

# -----------------------------
# Layout / directories
# -----------------------------
mkdir -p /logs /root/SnappierServer/epg || true
mkdir -p "${RECORDINGS_DIR}" "${MOVIES_DIR}" "${SERIES_DIR}" || true

# -----------------------------
# Pretty banner
# -----------------------------
log "==================================="
log "Snappier starting with:"
log "  PORT=${PORT}  HOST=${HOST}  TZ=${TZ}"
log "  ENABLE_EPG=${ENABLE_EPG}  INTERVAL=${EPG_INTERVAL_HOURS}"
if [[ -n "${EPG_URLS_JSON}" ]]; then
  log "  EPG_URLS_JSON: present"
elif [[ -n "${EPG_URL}" ]]; then
  log "  EPG_URL: ${EPG_URL}"
else
  log "  EPG: disabled or no sources"
fi
log "  ENABLE_REMUX=${ENABLE_REMUX}  SPEED_LIMIT=${DOWNLOAD_SPEED_LIMIT_MBS} MB/s"
log "  RECORDINGS=${RECORDINGS_DIR}"
log "  MOVIES=${MOVIES_DIR}"
log "  SERIES=${SERIES_DIR}"
log "  LOG=${SNAP_LOG_FILE}"
log "==================================="

# -----------------------------
# Helpers: Notify webhook
# -----------------------------
start_notify () {
  # Port 0 disables notify entirely
  [[ "${NOTIFICATION_HTTP_PORT}" == "0" ]] && { log "notify disabled (port=0)"; return; }

  local URL="http://${NOTIFICATION_BIND}:${NOTIFICATION_HTTP_PORT}"
  local HEALTH="${URL}/health"
  local WAIT_SECS=45

  # If already up, don't start another instance
  if curl -fsS "${HEALTH}" >/dev/null 2>&1; then
    log "notify_webhook already running at ${URL} (skipping start)"
    return
  fi

  : > /logs/notify.log || true
  log "starting notify_webhook on ${NOTIFICATION_BIND}:${NOTIFICATION_HTTP_PORT} ..."

  (
    cd /opt/notify
    exec python3 -u /opt/notify/enhanced_webhook.py >>/logs/notify.log 2>&1
  ) & echo $! > /tmp/notify.pid

  # Wait until healthy (or time out)
  local i=0
  until curl -fsS "${HEALTH}" >/dev/null 2>&1; do
    sleep 0.5; i=$((i+1))
    if [[ $((i/2)) -ge ${WAIT_SECS} ]]; then
      log "WARN: notify_webhook did not come up; recent log lines:"
      tail -n 200 /logs/notify.log || true
      break
    fi
  done

  if curl -fsS "${HEALTH}" >/dev/null 2>&1; then
    log "notify_webhook is up at ${URL}"
  fi
}

# -----------------------------
# Helpers: other background jobs
# -----------------------------
start_helpers () {
  # health_watcher.py
  if [[ -f /opt/scripts/health_watcher.py ]]; then
    log "Starting health_watcher ..."
    ( exec python3 -u /opt/scripts/health_watcher.py >>/logs/health_watcher.log 2>&1 ) & echo $! > /tmp/health_watcher.pid
  fi

  # https_watcher.py
  if [[ -f /opt/scripts/https_watcher.py ]]; then
    log "Starting https_watcher ..."
    ( exec python3 -u /opt/scripts/https_watcher.py >>/logs/https_watcher.log 2>&1 ) & echo $! > /tmp/https_watcher.pid
  fi

  # schedule_watcher.py
  if [[ -f /opt/scripts/schedule_watcher.py ]]; then
    log "Starting schedule_watcher ..."
    ( exec python3 -u /opt/scripts/schedule_watcher.py >>/logs/schedule_watcher.log 2>&1 ) & echo $! > /tmp/schedule_watcher.pid
  fi

  # log_monitor.sh — starts AFTER notify so it can post to /notify
  if [[ -x /opt/scripts/log_monitor.sh && "${NOTIFICATION_HTTP_PORT}" != "0" ]]; then
    local NOTIFY_URL="http://${NOTIFICATION_BIND}:${NOTIFICATION_HTTP_PORT}/notify"
    log "Starting log_monitor ..."
    ( NOTIFY_URL="${NOTIFY_URL}" exec /opt/scripts/log_monitor.sh >>/logs/log_monitor.log 2>&1 ) & echo $! > /tmp/log_monitor.pid
  fi
}

# -----------------------------
# Build CLI args for snappier
# -----------------------------
build_args () {
  ARGS=( -p "${PORT}" -h "${HOST}" )

  # EPG switches
  if [[ "${ENABLE_EPG,,}" == "1" || "${ENABLE_EPG,,}" == "true" ]]; then
    ARGS+=( -e )
    if [[ -n "${EPG_URLS_JSON}" ]]; then
      ARGS+=( -m "${EPG_URLS_JSON}" )
    elif [[ -n "${EPG_URL}" ]]; then
      ARGS+=( -u "${EPG_URL}" )
    fi
    ARGS+=( -i "${EPG_INTERVAL_HOURS}" )
  fi

  # Remux
  if [[ "${ENABLE_REMUX,,}" == "1" || "${ENABLE_REMUX,,}" == "true" ]]; then
    ARGS+=( -r )
  fi

  # Directories
  ARGS+=( --recordings "${RECORDINGS_DIR}" --movies "${MOVIES_DIR}" --series "${SERIES_DIR}" )
}

# -----------------------------
# Cleanup on stop
# -----------------------------
cleanup () {
  log "shutting down ..."
  for f in /tmp/notify.pid /tmp/health_watcher.pid /tmp/https_watcher.pid /tmp/schedule_watcher.pid /tmp/log_monitor.pid; do
    [[ -f "$f" ]] && { kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; }
  done
  exit 0
}
trap cleanup SIGINT SIGTERM

# -----------------------------
# Boot sequence
# -----------------------------
# 1) Bring up notify first (so log monitor can post)
start_notify

# 2) Bring up the rest
start_helpers

# 3) Locate binary
SNAPPIER_BIN="/opt/SnappierServer/snappier-server-cli"
if [[ ! -x "${SNAPPIER_BIN}" ]]; then
  # try versioned fallback
  SNAPPIER_BIN="/opt/SnappierServer/snappier-server-cli-v${SNAPPIER_SERVER_VERSION:-}-$(uname -m || echo linux-x64)"
fi
if [[ ! -x "${SNAPPIER_BIN}" ]]; then
  log "ERROR: Snappier Server CLI not found in /opt/SnappierServer"
  ls -la /opt/SnappierServer/ || true
  exit 1
fi

# 4) Build args & launch
build_args
log "Launching: ${SNAPPIER_BIN} ${ARGS[*]}"
cd /opt/SnappierServer
exec "${SNAPPIER_BIN}" "${ARGS[@]}"
