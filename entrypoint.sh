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
GRACEFUL_SHUTDOWN_TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT:-10}"  # seconds to wait for processes to shutdown gracefully

RECORDINGS_DIR="${RECORDINGS_DIR:-/root/SnappierServer/Recordings}"
MOVIES_DIR="${MOVIES_DIR:-/root/SnappierServer/Movies}"
SERIES_DIR="${SERIES_DIR:-/root/SnappierServer/TVSeries}"

SNAP_LOG_FILE="${SNAP_LOG_FILE:-/root/SnappierServer/server.log}"
EPG_CACHE="${EPG_CACHE:-/root/SnappierServer/epg/epg_cache.json}"
SCHEDULES="${SCHEDULES:-/root/SnappierServer/Recordings/schedules.json}"

# Notify (FastAPI webhook)
NOTIFICATION_HTTP_PORT="${NOTIFICATION_HTTP_PORT:-9080}"
NOTIFICATION_BIND="${NOTIFICATION_BIND:-0.0.0.0}"
NOTIFICATION_SSE_PATH="${NOTIFICATION_SSE_PATH:-/events}"

# HTTPS upgrade configuration
# Hosts that are safe to use HTTP (won't be upgraded to HTTPS)
ALLOW_HTTP_HOSTS="${ALLOW_HTTP_HOSTS:-localhost,127.0.0.1,snappier-server,pro.business-cdn.me}"
export ALLOW_HTTP_HOSTS

# Health monitor helpers
HEALTH_INTERVAL_SEC="${HEALTH_INTERVAL_SEC:-30}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/serverStats}"
SNAPPY_API_BASE="${SNAPPY_API_BASE:-http://127.0.0.1:8000}"

LOG_ROOT="${LOG_ROOT:-/logs}"

# -----------------------------
# Layout / directories
# -----------------------------
mkdir -p "${LOG_ROOT}" /root/SnappierServer/epg || true
mkdir -p "${RECORDINGS_DIR}" "${MOVIES_DIR}" "${SERIES_DIR}" || true
: > "${SNAP_LOG_FILE}" || true

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
  local LOCK_FILE="/tmp/notify.lock"
  local PID_FILE="/tmp/notify.pid"

  # Acquire exclusive lock to prevent race conditions
  exec 200>"${LOCK_FILE}"
  if ! flock -n 200; then
    log "Another instance is managing notify_webhook startup, waiting..."
    flock 200  # Wait for lock
    # Check if webhook is now running
    if curl -fsS "${HEALTH}" >/dev/null 2>&1; then
      log "notify_webhook is running (started by another instance)"
      return
    fi
  fi

  # Check if existing process is alive and valid
  if [[ -f "${PID_FILE}" ]]; then
    local existing_pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      # Process exists, verify it's actually the webhook
      local cmd=$(ps -p "${existing_pid}" -o comm= 2>/dev/null || echo "")
      if [[ "$cmd" == "python3" ]] || [[ "$cmd" == python* ]]; then
        # Double-check via health endpoint
        if curl -fsS -m 2 "${HEALTH}" >/dev/null 2>&1; then
          log "notify_webhook already running at ${URL} (PID ${existing_pid})"
          flock -u 200
          return
        else
          log "WARN: Process ${existing_pid} exists but health check failed, restarting"
        fi
      else
        log "WARN: Stale PID file points to non-Python process (${cmd}), cleaning up"
        rm -f "${PID_FILE}"
      fi
    else
      log "Stale PID file found, starting fresh"
      rm -f "${PID_FILE}"
    fi
  fi

  : > "${LOG_ROOT}/notify.log" || true
  log "starting notify_webhook on ${NOTIFICATION_BIND}:${NOTIFICATION_HTTP_PORT} ..."

  (
    export NOTIFICATION_HTTP_BIND="${NOTIFICATION_BIND}"
    export WEBHOOK_LOG_LEVEL="${WEBHOOK_LOG_LEVEL:-DEBUG}"
    cd /opt/notify
    exec uvicorn \
      --host="${NOTIFICATION_BIND}" \
      --port="${NOTIFICATION_HTTP_PORT}" \
      --workers=4 \
      --timeout-keep-alive=30 \
      --log-level=info \
      enhanced_webhook:app >>"${LOG_ROOT}/notify.log" 2>&1
  ) &

  local new_pid=$!
  echo "$new_pid" > "${PID_FILE}"
  log "Started notify_webhook with PID ${new_pid}"

  # Release lock after starting (but keep waiting for health check)
  flock -u 200

  # Wait until healthy (or time out)
  local i=0
  until curl -fsS -m 2 "${HEALTH}" >/dev/null 2>&1; do
    # Check if process is still alive
    if ! kill -0 "${new_pid}" 2>/dev/null; then
      log "ERROR: notify_webhook process ${new_pid} died during startup"
      tail -n 200 "${LOG_ROOT}/notify.log" || true
      return 1
    fi
    sleep 0.5; i=$((i+1))
    if [[ $((i/2)) -ge ${WAIT_SECS} ]]; then
      log "WARN: notify_webhook did not come up after ${WAIT_SECS}s; recent log lines:"
      tail -n 200 "${LOG_ROOT}/notify.log" || true
      break
    fi
  done

  if curl -fsS -m 2 "${HEALTH}" >/dev/null 2>&1; then
    log "notify_webhook is up at ${URL} (PID ${new_pid})"
  else
    log "WARN: notify_webhook may not be healthy"
  fi
}

# -----------------------------
# Helpers: other background jobs
# -----------------------------
start_helpers () {
  # health_watcher.py
  if [[ -f /opt/scripts/health_watcher.py ]]; then
    log "Starting health_watcher ..."
    ( exec python3 -u /opt/scripts/health_watcher.py >>"${LOG_ROOT}/health_watcher.log" 2>&1 ) & echo $! > /tmp/health_watcher.pid
  fi

  # schedule_watcher.py
  if [[ -f /opt/scripts/schedule_watcher.py ]]; then
    log "Starting schedule_watcher ..."
    ( exec python3 -u /opt/scripts/schedule_watcher.py >>"${LOG_ROOT}/schedule_watcher.log" 2>&1 ) & echo $! > /tmp/schedule_watcher.pid
  fi

  # log_monitor.sh — starts AFTER notify so it can post to /notify
  if [[ -x /opt/scripts/log_monitor.sh && "${NOTIFICATION_HTTP_PORT}" != "0" ]]; then
    local notify_host="127.0.0.1"
    if [[ "${NOTIFICATION_BIND}" =~ ^(127\.0\.0\.1|localhost)$ ]]; then
      notify_host="${NOTIFICATION_BIND}"
    fi
    local NOTIFY_URL="http://${notify_host}:${NOTIFICATION_HTTP_PORT}/notify"
    log "Starting log_monitor ..."
    (
      export NOTIFY_URL="${NOTIFY_URL}"
      export LOG_DIR="${LOG_ROOT}"
      export LOG="${SNAP_LOG_FILE}"
      export SCHEDULES_PATH="${SCHEDULES}"
      exec /opt/scripts/log_monitor.sh >>"${LOG_ROOT}/log_monitor.log" 2>&1
    ) & echo $! > /tmp/log_monitor.pid
  fi

  # log_rotate.sh — keep log files bounded
  if [[ -x /opt/scripts/log_rotate.sh ]]; then
    log "Starting log_rotate ..."
    (
      export LOG_DIR="${LOG_ROOT}"
      export SNAP_LOG_FILE="${SNAP_LOG_FILE}"
      exec /opt/scripts/log_rotate.sh >>"${LOG_ROOT}/log_rotate_runner.log" 2>&1
    ) & echo $! > /tmp/log_rotate.pid
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

  # Give log_monitor extra time to process pending remux completion events
  # This is critical for catch-ups with remux enabled - they wait for [remux] deleted event
  # to send the catchup_completed notification
  if [[ -f /tmp/log_monitor.pid ]]; then
    local log_monitor_pid=$(cat /tmp/log_monitor.pid 2>/dev/null)
    if [[ -n "$log_monitor_pid" ]] && kill -0 "$log_monitor_pid" 2>/dev/null; then
      log "Allowing log_monitor ($log_monitor_pid) to process pending events before shutdown (waiting 10 seconds)..."
      # Wait for log_monitor to catch up with the log file
      # This allows remux completion events to be properly processed
      sleep 10  # Give time for final log entries to be written and processed
      log "Proceeding with graceful shutdown of all processes (timeout: ${GRACEFUL_SHUTDOWN_TIMEOUT}s)..."
    fi
  fi

  # Kill all background processes with graceful shutdown
  for f in /tmp/notify.pid /tmp/health_watcher.pid /tmp/schedule_watcher.pid /tmp/log_monitor.pid /tmp/log_rotate.pid; do
    if [[ -f "$f" ]]; then
      local pid=$(cat "$f" 2>/dev/null)
      if [[ -n "$pid" ]]; then
        # Try graceful shutdown first (SIGTERM)
        if kill -0 "$pid" 2>/dev/null; then
          log "Shutting down process $pid gracefully..."
          kill -TERM "$pid" 2>/dev/null || true

          # Wait up to GRACEFUL_SHUTDOWN_TIMEOUT seconds for graceful shutdown
          # to allow remux operations to complete and be logged
          local max_iterations=$((GRACEFUL_SHUTDOWN_TIMEOUT * 2))  # 0.5s per iteration
          local count=0
          while kill -0 "$pid" 2>/dev/null && [[ $count -lt $max_iterations ]]; do
            sleep 0.5
            count=$((count + 1))
          done

          # Force kill if still running
          if kill -0 "$pid" 2>/dev/null; then
            log "Process $pid did not shutdown gracefully, forcing kill..."
            kill -9 "$pid" 2>/dev/null || true
          fi
        fi
      fi
      rm -f "$f"
    fi
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
  ALT_BIN="/opt/SnappierServer/snappier-server"
  if [[ -x "${ALT_BIN}" ]]; then
    SNAPPIER_BIN="${ALT_BIN}"
  fi
fi
if [[ ! -x "${SNAPPIER_BIN}" ]]; then
  ALT_MATCH="$(find /opt/SnappierServer -maxdepth 1 -type f -name 'snappier-server*' | head -n1)"
  if [[ -n "${ALT_MATCH}" && -x "${ALT_MATCH}" ]]; then
    SNAPPIER_BIN="${ALT_MATCH}"
  fi
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
