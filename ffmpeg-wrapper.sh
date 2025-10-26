#!/usr/bin/env bash
set -euo pipefail

# -------- Config (env tunables) --------
ALLOW_HTTP="${ALLOW_HTTP:-0}"
ALLOW_HTTP_HOSTS="${ALLOW_HTTP_HOSTS:-localhost,127.0.0.1,snappier-server}"
HTTPS_PROBE_TIMEOUT="${HTTPS_PROBE_TIMEOUT:-3}"
HTTPS_PROBE_METHOD="${HTTPS_PROBE_METHOD:-HEAD}"   # HEAD or GET

# Catch-up download extension
CATCHUP_EXTENSION_ENABLED="${CATCHUP_EXTENSION_ENABLED:-1}"
CATCHUP_BUFFER_SECONDS="${CATCHUP_BUFFER_SECONDS:-180}"  # 3 minutes default

# Network flags (applied only for http/https inputs)
NET_FLAGS=( -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 \
            -reconnect_on_network_error 1 -reconnect_on_http_error 4xx,5xx \
            -rw_timeout 15000000 -timeout 15000000 )
FFMPEG_REAL="${FFMPEG_REAL:-/usr/bin/ffmpeg.real}"

# Logging
LOG_FILE="${FFMPEG_WRAPPER_LOG:-/logs/ffmpeg_wrapper.log}"
log(){
  if [[ -n "${LOG_FILE}" ]]; then
    printf '[ffmpeg-wrapper] %s %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

# -------- Helpers --------
is_http_like(){ [[ "$1" == http://* || "$1" == https://* ]]; }
is_progress_flag(){ [[ "$1" == "-progress" || "$1" == "--progress" ]]; }

IFS="," read -r -a SAFE_HOSTS <<< "${ALLOW_HTTP_HOSTS}"

host_is_safe_http(){
  local host="$1"
  for h in "${SAFE_HOSTS[@]}"; do
    [[ "$host" == "$h" ]] && return 0
  done
  return 1
}

try_https(){
  local url="$1"
  local method="${HTTPS_PROBE_METHOD^^}"

  # Try a lightweight HEAD probe first unless GET is explicitly requested
  if [[ "$method" != "GET" ]]; then
    if curl -fsSIL --max-time "${HTTPS_PROBE_TIMEOUT}" "$url" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Fall back to a ranged GET probe. Some providers (e.g. Cloudflare) ignore range
  # requests and stream data indefinitely. Treat a timeout WITH bytes downloaded as success.
  local out status code size
  if out="$(curl -sSL --range 0-0 --max-time "${HTTPS_PROBE_TIMEOUT}" -o /dev/null -w '%{http_code} %{size_download}' "$url" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  code="$(printf '%s' "$out" | awk '{print $1}')"
  size="$(printf '%s' "$out" | awk '{print $2}')"

  if [[ "$status" -eq 0 && ( "$code" == "200" || "$code" == "206" ) && "${size:-0}" -ge 0 ]]; then
    return 0
  fi
  if [[ "$status" -eq 28 && "${size:-0}" -gt 0 ]]; then
    # Timeout but data flowed; assume HTTPS works
    return 0
  fi
  log "HTTPS probe details: status=${status} code=${code:-?} size=${size:-0} url=${url}"
  return 1
}

rewrite_arg(){
  local arg="$1"
  # only rewrite http://… inputs; never touch outputs or other args
  [[ "${arg}" != http://* ]] && { printf '%s\n' "${arg}"; return; }
  [[ "${ALLOW_HTTP}" == "1" ]] && { printf '%s\n' "${arg}"; return; }
  local rest="${arg#http://}"
  local host_port="${rest%%/*}"
  local path="${rest#*/}"
  [[ "${path}" == "${host_port}" ]] && path=""

  local host="${host_port%%:*}"
  local port=""
  if [[ "${host_port}" == *:* ]]; then
    port="${host_port##*:}"
  fi

  host_is_safe_http "${host}" && { printf '%s\n' "${arg}"; return; }

  local https_host="${host}"
  if [[ -n "${port}" && "${port}" != "${host}" ]]; then
    if [[ "${port}" == "80" ]]; then
      https_host="${host}"
    else
      https_host="${host}:${port}"
    fi
  fi

  local https_url="https://${https_host}"
  [[ -n "${path}" ]] && https_url="${https_url}/${path}"

  # Skip probe - trust HTTPS upgrade and let ffmpeg handle connection errors
  log "Upgraded stream to HTTPS: ${arg} -> ${https_url}"
  printf '%s\n' "${https_url}"
}

# -------- Catch-up detection --------
is_catchup_download(){
  # Catch-up files start with -- (no channel prefix)
  # Pattern: --Program--START--UUID.ts
  for arg in "$@"; do
    if [[ "$arg" == */--*.ts ]] || [[ "$arg" == */--*.mkv ]] || [[ "$arg" == */--*.mp4 ]]; then
      local filename="${arg##*/}"
      if [[ "$filename" == --* ]]; then
        return 0
      fi
    fi
  done
  return 1
}

extend_duration(){
  # Extend -t (duration) argument by CATCHUP_BUFFER_SECONDS
  local duration="$1"
  local buffer="${CATCHUP_BUFFER_SECONDS}"

  python3 - "$duration" "$buffer" <<'PY'
import sys, re

duration_str = sys.argv[1]
buffer_sec = int(sys.argv[2])

# Parse various duration formats:
# - Seconds: "3600"
# - HH:MM:SS: "01:00:00"
# - HH:MM:SS.mmm: "01:00:00.500"

# Try parsing as pure seconds first
try:
    duration_sec = float(duration_str)
    new_duration = duration_sec + buffer_sec
    print(f"{new_duration:.3f}")
    raise SystemExit(0)
except ValueError:
    pass

# Try parsing HH:MM:SS or HH:MM:SS.mmm
time_match = re.match(r'^(\d+):(\d+):(\d+)(?:\.(\d+))?$', duration_str)
if time_match:
    hours = int(time_match.group(1))
    minutes = int(time_match.group(2))
    seconds = int(time_match.group(3))
    milliseconds = int(time_match.group(4) or 0)

    total_sec = hours * 3600 + minutes * 60 + seconds + buffer_sec
    new_hours = total_sec // 3600
    new_minutes = (total_sec % 3600) // 60
    new_seconds = total_sec % 60

    if milliseconds:
        print(f"{new_hours:02d}:{new_minutes:02d}:{new_seconds:02d}.{milliseconds}")
    else:
        print(f"{new_hours:02d}:{new_minutes:02d}:{new_seconds:02d}")
    raise SystemExit(0)

# Couldn't parse, return original
print(duration_str)
PY
}

# Smooth remux: add bitstream filters and timestamp guards when copying TS -> MKV
run_ffmpeg(){
  if [[ "${SAW_NET_INPUT}" == "1" ]]; then
    "${FFMPEG_REAL}" "${NET_FLAGS[@]}" "$@"
  else
    "${FFMPEG_REAL}" "$@"
  fi
}

main(){
  START_TIME=$(date +%s%N)
  ARGS=()
  SAW_NET_INPUT=0
  IS_CATCHUP=0
  HAS_TS_INPUT=0
  HAS_MKV_OUTPUT=0
  PREV_ARG=""

  # Check if this is a catch-up download
  if [[ "${CATCHUP_EXTENSION_ENABLED}" == "1" ]] && is_catchup_download "$@"; then
    IS_CATCHUP=1
    log "Detected catch-up download, will extend duration by ${CATCHUP_BUFFER_SECONDS}s"
    log "Full command args: $*"
  fi

  for a in "$@"; do
    skip_https_rewrite=0

    if is_http_like "$a"; then
      if is_progress_flag "$PREV_ARG"; then
        skip_https_rewrite=1
      else
        SAW_NET_INPUT=1
      fi
    fi

    # Apply HTTPS rewrite
    if [[ "$skip_https_rewrite" == "1" ]]; then
      rewritten="$a"
      log "Keeping HTTP for progress callback: $a"
    else
      rewritten="$(rewrite_arg "$a")"
    fi

    if [[ "$PREV_ARG" == "-i" ]] && [[ "$rewritten" == *.ts ]]; then
      HAS_TS_INPUT=1
    fi
    if [[ "$rewritten" == *.mkv ]]; then
      HAS_MKV_OUTPUT=1
    fi

    # Extend duration for catch-up downloads
    if [[ "${IS_CATCHUP}" == "1" ]] && [[ "${PREV_ARG}" == "-t" ]]; then
      # Extend the -t (duration) argument
      log "Found -t duration argument: ${rewritten}"
      extended="$(extend_duration "$rewritten")"
      log "Extended duration from ${rewritten} to ${extended}"
      ARGS+=("$extended")
    else
      ARGS+=("$rewritten")
    fi

    PREV_ARG="$a"
  done

  if [[ "$HAS_TS_INPUT" == "1" && "$HAS_MKV_OUTPUT" == "1" ]]; then
    dest="${ARGS[-1]}"
    base_args=("${ARGS[@]:0:${#ARGS[@]}-1}")

    copy_args=("${base_args[@]}")
    copy_args+=(
      -fflags +discardcorrupt
      -err_detect ignore_err
      -copyts
      -avoid_negative_ts make_zero
      -bsf:a aac_adtstoasc
      -max_muxing_queue_size 4096
      "$dest"
    )

    if run_ffmpeg "${copy_args[@]}"; then
      exit 0
    fi

    status=$?
    log "Remux copy path failed (status=${status}), trying to preserve audio codec"

    # Fallback 1: Try to preserve original audio codec (AC3/E-AC3) with video copy
    preserve_args=()
    i=0
    while [[ $i -lt ${#base_args[@]} ]]; do
      token="${base_args[$i]}"
      next="${base_args[$((i+1))]:-}"
      if [[ "$token" == "-c" && "$next" == "copy" ]]; then
        preserve_args+=("-c:v" "copy" "-c:a" "copy")
        i=$((i+2))
        continue
      fi
      preserve_args+=("$token")
      i=$((i+1))
    done

    preserve_args+=(
      -fflags +discardcorrupt
      -err_detect ignore_err
      -copyts
      -avoid_negative_ts make_zero
      -max_muxing_queue_size 4096
      "$dest"
    )

    if run_ffmpeg "${preserve_args[@]}"; then
      log "Remux succeeded by preserving audio codec"
      exit 0
    fi

    status=$?
    log "Audio codec preservation failed (status=${status}), transcoding to AAC with channel layout preservation"

    # Fallback 2: Transcode audio to AAC while preserving channel layout
    transcode_args=()
    i=0
    while [[ $i -lt ${#base_args[@]} ]]; do
      token="${base_args[$i]}"
      next="${base_args[$((i+1))]:-}"
      if [[ "$token" == "-c" && "$next" == "copy" ]]; then
        transcode_args+=("-c:v" "copy")
        i=$((i+2))
        continue
      fi
      transcode_args+=("$token")
      i=$((i+1))
    done

    # Use higher bitrate for multichannel audio (384k for 5.1, fallback to 192k for stereo)
    AUDIO_BITRATE="${CATCHUP_AUDIO_BITRATE:-384k}"
    transcode_args+=(
      -fflags +discardcorrupt
      -err_detect ignore_err
      -copyts
      -avoid_negative_ts make_zero
      -max_muxing_queue_size 4096
      -af "aresample=async=1:first_pts=0"
      -c:a aac
      -b:a "${AUDIO_BITRATE}"
      "$dest"
    )

    run_ffmpeg "${transcode_args[@]}"
    exit $?
  fi

  # Only add network flags if there is at least one network input
  END_TIME=$(date +%s%N)
  DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  log "Wrapper initialization took ${DURATION_MS}ms before launching ffmpeg"

  # Run ffmpeg as child process (not exec) so wrapper stays alive
  # This allows Snappier to detect successful process spawn and log callbacks
  if [[ "${SAW_NET_INPUT}" == "1" ]]; then
    "${FFMPEG_REAL}" "${NET_FLAGS[@]}" "${ARGS[@]}"
    exit $?
  else
    # Pure file/local remux path: no extra flags at all
    "${FFMPEG_REAL}" "${ARGS[@]}"
    exit $?
  fi
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
