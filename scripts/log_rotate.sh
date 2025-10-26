#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/logs}"
SNAP_LOG_FILE="${SNAP_LOG_FILE:-/root/SnappierServer/server.log}"
LOG_ROTATE_ENABLED="${LOG_ROTATE_ENABLED:-1}"
LOG_ROTATE_PATTERN="${LOG_ROTATE_PATTERN:-*.log}"
LOG_ROTATE_MAX_MB="${LOG_ROTATE_MAX_MB:-50}"
LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-5}"
LOG_ROTATE_INTERVAL_SEC="${LOG_ROTATE_INTERVAL_SEC:-60}"
LOG_ROTATE_EXTRA="${LOG_ROTATE_EXTRA:-}"
SELF_LOG="${LOG_ROTATE_LOG:-${LOG_DIR}/log_rotate.log}"

log(){
  printf '[logrotate] %s %s\n' "$(date -u +%FT%TZ)" "$*" >>"${SELF_LOG}"
}

if [[ "${LOG_ROTATE_ENABLED}" == "0" ]]; then
  exit 0
fi

mkdir -p "${LOG_DIR}" || true
: > "${SELF_LOG}" || true

# Resolve the maximum file size (bytes) before rotation.
MAX_BYTES=$(python3 - <<'PY' "${LOG_ROTATE_MAX_MB}"
import sys
raw = sys.argv[1]
try:
    size = float(raw)
except ValueError:
    print(-1)
    raise SystemExit(1)
if size <= 0:
    print(-1)
    raise SystemExit(1)
print(int(size * 1024 * 1024))
PY
) || {
  log "invalid LOG_ROTATE_MAX_MB='${LOG_ROTATE_MAX_MB}' (using default 52428800 bytes)"
  MAX_BYTES=$((50 * 1024 * 1024))
}

if [[ "${MAX_BYTES}" -le 0 ]]; then
  log "LOG_ROTATE_MAX_MB produced invalid byte limit (${MAX_BYTES}); defaulting to 50MB"
  MAX_BYTES=$((50 * 1024 * 1024))
fi

KEEP_LIMIT="${LOG_ROTATE_KEEP}"
if [[ ! "${KEEP_LIMIT}" =~ ^[0-9]+$ ]] || [[ "${KEEP_LIMIT}" -lt 1 ]]; then
  log "LOG_ROTATE_KEEP='${LOG_ROTATE_KEEP}' invalid; forcing to 5"
  KEEP_LIMIT=5
fi

INTERVAL_SEC="${LOG_ROTATE_INTERVAL_SEC}"
if [[ ! "${INTERVAL_SEC}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL_SEC}" -lt 5 ]]; then
  log "LOG_ROTATE_INTERVAL_SEC='${LOG_ROTATE_INTERVAL_SEC}' invalid; forcing to 60"
  INTERVAL_SEC=60
fi

declare -a EXTRA_TARGETS=()
if [[ -n "${LOG_ROTATE_EXTRA}" ]]; then
  read -r -a EXTRA_TARGETS <<<"${LOG_ROTATE_EXTRA}"
fi

rotate_file(){
  local file="$1"
  local ts
  ts="$(date -u +%Y%m%d-%H%M%S)"
  local rotated="${file}.${ts}"

  if cp "${file}" "${rotated}" 2>/dev/null; then
    : > "${file}" || true
    log "rotated ${file} -> ${rotated}"
  else
    log "failed to copy ${file}; skipping rotation"
    return
  fi

  # Enforce retention count
  local IFS=$'\n'
  local candidates=($(ls -1t -- "${file}".* 2>/dev/null || true))
  unset IFS
  if ((${#candidates[@]} > KEEP_LIMIT)); then
    for ((idx=KEEP_LIMIT; idx<${#candidates[@]}; idx++)); do
      rm -f -- "${candidates[idx]}" 2>/dev/null || true
    done
  fi
}

collect_targets(){
  declare -a raw_targets=()

  if [[ -n "${SNAP_LOG_FILE}" ]]; then
    raw_targets+=("${SNAP_LOG_FILE}")
  fi

  if [[ -d "${LOG_DIR}" ]]; then
    while IFS= read -r -d '' candidate; do
      raw_targets+=("${candidate}")
    done < <(find "${LOG_DIR}" -maxdepth 1 -type f -name "${LOG_ROTATE_PATTERN}" -print0 2>/dev/null || true)
  fi

  if ((${#EXTRA_TARGETS[@]} > 0)); then
    for extra in "${EXTRA_TARGETS[@]}"; do
      raw_targets+=("${extra}")
    done
  fi

  declare -A seen=()
  TARGETS=()
  for file in "${raw_targets[@]}"; do
    [[ -n "${file}" ]] || continue
    [[ -f "${file}" ]] || continue
    [[ "${file}" == "${SELF_LOG}" ]] && continue
    if [[ -z "${seen[$file]:-}" ]]; then
      TARGETS+=("${file}")
      seen["$file"]=1
    fi
  done
}

log "log rotation enabled (limit=${MAX_BYTES} bytes, keep=${KEEP_LIMIT}, interval=${INTERVAL_SEC}s)"

declare -a TARGETS=()
while true; do
  collect_targets
  for file in "${TARGETS[@]}"; do
    if [[ ! -f "${file}" ]]; then
      continue
    fi
    size=$(stat -c%s -- "${file}" 2>/dev/null || echo 0)
    if (( size > MAX_BYTES )); then
      rotate_file "${file}"
    fi
  done
  sleep "${INTERVAL_SEC}" || sleep 60
done
