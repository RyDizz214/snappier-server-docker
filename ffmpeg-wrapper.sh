#!/usr/bin/env bash
set -euo pipefail

# -------- Config (env tunables) --------

# Catch-up download extension
CATCHUP_EXTENSION_ENABLED="${CATCHUP_EXTENSION_ENABLED:-1}"
CATCHUP_BUFFER_MINUTES="${CATCHUP_BUFFER_MINUTES:-5}"

# Network flags (only flags snappier-server doesn't already pass)
# Snappier natively sets: -reconnect 1, -reconnect_streamed 1, -reconnect_at_eof 1, -reconnect_delay_max 2
# We only add: network error recovery + timeouts
NET_FLAGS=( -reconnect_on_network_error 1 -reconnect_on_http_error 4xx,5xx \
            -rw_timeout 15000000 -timeout 15000000 )
FFMPEG_REAL="${FFMPEG_REAL:-/usr/bin/ffmpeg.real}"

# Logging
LOG_FILE="${FFMPEG_WRAPPER_LOG:-/logs/ffmpeg_wrapper.log}"
LOG_MAX_BYTES="${FFMPEG_WRAPPER_LOG_MAX:-52428800}"  # 50MB default
_log_rotate_checked=0
log(){
  if [[ -n "${LOG_FILE}" ]]; then
    # Rotate if > 50MB (check once per ffmpeg invocation to avoid stat overhead)
    if [[ "${_log_rotate_checked}" == "0" && -f "${LOG_FILE}" ]]; then
      _log_rotate_checked=1
      local size
      size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
      if [[ "$size" -gt "${LOG_MAX_BYTES}" ]]; then
        mv "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
      fi
    fi
    printf '[ffmpeg-wrapper] %s %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

# Warn loudly if the pre-2.0.0 name is still set. Falling back to the default
# silently would quietly change every catch-up download length.
if [[ -n "${CATCHUP_BUFFER_SECONDS:-}" ]]; then
  log "WARNING: CATCHUP_BUFFER_SECONDS is no longer read (removed in 2.0.0)." \
      "Use CATCHUP_BUFFER_MINUTES instead — currently ${CATCHUP_BUFFER_MINUTES} minute(s)."
fi

# -------- Helpers --------
is_http_like(){ [[ "$1" == http://* || "$1" == https://* ]]; }
is_progress_flag(){ [[ "$1" == "-progress" || "$1" == "--progress" ]]; }

# -------- HLS live-playback optimisation --------
# Snappier >= 1.5 transcodes ALL live streams (libx264/libfdk_aac) for dashboard
# HLS playback.  For H.264 sources we switch to -c copy (near-zero CPU) since
# the source is already browser-playable.  Non-H.264 sources keep Snappier's
# transcode args unchanged.
HLS_OPTIMIZE_ENABLED="${HLS_OPTIMIZE_ENABLED:-1}"
# Use the ffprobe shim (not FFPROBE_REAL which points to the raw host binary
# that can't run without ld-linux wrapper)
FFPROBE_CMD="/usr/local/bin/ffprobe"

is_hls_live_playback(){
  local has_net_input=0 has_hls_fmt=0 prev=""
  for arg in "$@"; do
    if [[ "$prev" == "-i" ]] && is_http_like "$arg"; then has_net_input=1; fi
    if [[ "$prev" == "-f" && "$arg" == "hls" ]]; then has_hls_fmt=1; fi
    prev="$arg"
  done
  [[ "$has_net_input" == "1" && "$has_hls_fmt" == "1" ]]
}

# Extract the -i URL from ARGS
get_input_url(){
  local prev=""
  for arg in "${ARGS[@]}"; do
    if [[ "$prev" == "-i" ]] && is_http_like "$arg"; then
      echo "$arg"; return 0
    fi
    prev="$arg"
  done
  return 1
}

# Probe source: returns "codec_name,height" (e.g. "h264,1080" or "hevc,2160").
# Timeout keeps startup snappy.
probe_video_stream(){
  local url="$1"
  "${FFPROBE_CMD}" -v quiet -select_streams v:0 \
    -show_entries stream=codec_name,height -of csv=p=0 \
    -rw_timeout 5000000 -timeout 5000000 \
    "$url" 2>/dev/null | head -1
}

# Rewrite for H.264 source: copy video, transcode audio to AAC (browsers can't
# decode AC3/E-AC3 in HLS).  Audio transcoding is near-zero CPU.
rewrite_hls_to_copy(){
  local new_args=()
  local i=0
  while [[ $i -lt ${#ARGS[@]} ]]; do
    local arg="${ARGS[$i]}"
    case "$arg" in
      -c:v)  new_args+=("-c:v" "copy"); i=$((i+2)); continue ;;
      -c:a)  new_args+=("-c:a" "libfdk_aac" "-b:a" "192k" "-ac" "2"); i=$((i+2)); continue ;;
      # Drop video-encode-only flags (not needed with -c:v copy)
      -pix_fmt|-sc_threshold|-force_key_frames|-b:v|-preset|-tune|-profile:v|-level)
        i=$((i+2)); continue ;;
      # Drop original audio params (we set our own above)
      -b:a|-ar|-af|-ac)
        i=$((i+2)); continue ;;
      *)  new_args+=("$arg") ;;
    esac
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

# Safety net for transcode-to-libx264 paths: when Snappier emits a barebones
# transcode command (no -preset, no -vf scale), inject sane defaults so ffmpeg
# can keep up with high-resolution sources.  Without this, cold-start cases
# where Snappier hasn't yet identified the source codec produce a libx264
# transcode at the default "medium" preset, which can't keep up with 4K HEVC
# inputs — segments don't appear in time and the browser sees a manifest error.
# scale=-2:'min(1080,ih)' caps height at 1080 without ever upscaling.
ensure_transcode_safety_flags(){
  local has_preset=0 has_scale=0 has_libx264=0
  local i=0
  while [[ $i -lt ${#ARGS[@]} ]]; do
    [[ "${ARGS[$i]}" == "-preset" ]] && has_preset=1
    [[ "${ARGS[$i]}" == "-vf" ]] && has_scale=1
    [[ "${ARGS[$i]}" == "-c:v" && "${ARGS[$((i+1))]:-}" == "libx264" ]] && has_libx264=1
    i=$((i+1))
  done

  [[ "$has_libx264" == "0" ]] && return 0
  [[ "$has_preset" == "1" && "$has_scale" == "1" ]] && return 0

  local new_args=()
  i=0
  while [[ $i -lt ${#ARGS[@]} ]]; do
    local arg="${ARGS[$i]}"
    local next="${ARGS[$((i+1))]:-}"
    new_args+=("$arg")
    if [[ "$arg" == "-c:v" && "$next" == "libx264" ]]; then
      new_args+=("$next")
      [[ "$has_preset" == "0" ]] && new_args+=("-preset" "ultrafast")
      [[ "$has_scale" == "0" ]] && new_args+=("-vf" "scale=-2:'min(1080,ih)':flags=fast_bilinear")
      i=$((i+2))
      continue
    fi
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

# -------- Catch-up detection --------
is_catchup_download(){
  # Detect catch-up/timeshift downloads by checking for /timeshift/ in input URL
  local prev_arg=""
  for arg in "$@"; do
    if [[ "$prev_arg" == "-i" ]] && [[ "$arg" == *"/timeshift/"* ]]; then
      return 0
    fi
    prev_arg="$arg"
  done
  return 1
}

# Modify timeshift URL to request more minutes for catch-up buffer
# Format: .../timeshift/.../MINUTES/DATE-TIME/segment.ts
# Changes: /MINUTES/ -> /(MINUTES + BUFFER_MINUTES)/
extend_timeshift_url(){
  local url="$1"

  # Match and extract the duration minutes from the URL pattern
  if [[ "$url" =~ /timeshift/([^/]+)/([^/]+)/([0-9]+)/ ]]; then
    local user="${BASH_REMATCH[1]}"
    local uuid="${BASH_REMATCH[2]}"
    local minutes="${BASH_REMATCH[3]}"
    local new_minutes=$((minutes + CATCHUP_BUFFER_MINUTES))

    # Replace the old duration with new duration in the URL
    local modified_url="${url/\/timeshift\/${user}\/${uuid}\/${minutes}\//\/timeshift\/${user}\/${uuid}\/${new_minutes}\/}"
    echo "$modified_url"
    log "Extended timeshift: ${minutes}m -> ${new_minutes}m (added ${CATCHUP_BUFFER_MINUTES}m buffer)"
    return 0
  fi

  # If no match, return original URL unchanged
  echo "$url"
  return 1
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
    log "Detected catch-up download, extending timeshift buffer by ${CATCHUP_BUFFER_MINUTES}m"
  fi

  for a in "$@"; do
    if is_http_like "$a"; then
      if ! is_progress_flag "$PREV_ARG"; then
        SAW_NET_INPUT=1
      fi
    fi

    if [[ "$PREV_ARG" == "-i" ]] && [[ "$a" == *.ts ]] && ! is_http_like "$a"; then
      HAS_TS_INPUT=1
    fi
    if [[ "$a" == *.mkv ]]; then
      HAS_MKV_OUTPUT=1
    fi

    # Modify timeshift URL for catch-up downloads (extend minutes parameter in URL)
    rewritten="$a"
    if [[ "${IS_CATCHUP}" == "1" ]] && [[ "$PREV_ARG" == "-i" ]]; then
      rewritten="$(extend_timeshift_url "$a")"
    fi

    ARGS+=("$rewritten")
    PREV_ARG="$a"
  done

  # HLS live playback: probe source codec+height and decide copy vs transcode
  if [[ "${HLS_OPTIMIZE_ENABLED}" == "1" ]] && is_hls_live_playback "${ARGS[@]}"; then
    INPUT_URL="$(get_input_url)" || true
    if [[ -n "${INPUT_URL}" ]]; then
      PROBE_RESULT="$(probe_video_stream "${INPUT_URL}")" || true
      SOURCE_CODEC="${PROBE_RESULT%%,*}"
      SOURCE_HEIGHT="${PROBE_RESULT##*,}"
      # If probe returned a single value (no comma), height is unknown
      [[ "$SOURCE_CODEC" == "$SOURCE_HEIGHT" ]] && SOURCE_HEIGHT=0
      log "HLS live playback — source codec: ${SOURCE_CODEC:-unknown}, height: ${SOURCE_HEIGHT:-unknown}"

      case "${SOURCE_CODEC}" in
        h264)
          log "H.264 source — switching to -c copy (remux only)"
          rewrite_hls_to_copy
          ;;
        "")
          log "Probe failed — applying transcode safety flags as a precaution"
          ensure_transcode_safety_flags
          ;;
        *)
          log "Non-H.264 source (${SOURCE_CODEC} ${SOURCE_HEIGHT}p) — ensuring transcode safety flags"
          ensure_transcode_safety_flags
          ;;
      esac
      log "Final HLS args: ${ARGS[*]}"
    fi
  fi

  if [[ "$HAS_TS_INPUT" == "1" && "$HAS_MKV_OUTPUT" == "1" ]]; then
    dest="${ARGS[-1]}"
    base_args=("${ARGS[@]:0:${#ARGS[@]}-1}")

    # Log remux start
    REMUX_START_TIME=$(date +%s)
    log "Starting remux operation: $(basename "${base_args[-1]}" .ts) -> $(basename "$dest")"

    # Check available disk space before starting remux
    dest_dir="$(dirname "$dest")"
    available_space=$(df "$dest_dir" 2>/dev/null | awk 'NR==2 {print $4}')  # Available in 1K blocks
    available_gb=$((available_space / 1024 / 1024))  # Convert to GB

    if [[ -n "$available_space" && "$available_gb" -lt 5 ]]; then
      log "ERROR: Insufficient disk space for remux: only ${available_gb}GB available, need at least 5GB"
      log "Remux cannot proceed - destination directory: $dest_dir"
      exit 1
    elif [[ -n "$available_gb" ]]; then
      log "Disk space check: ${available_gb}GB available for remux"
    fi

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

    # Run with 30-minute timeout for remux operation
    # Note: Must inline ffmpeg call instead of using run_ffmpeg() function,
    # because timeout cannot execute shell functions (only binary executables)
    if [[ "${SAW_NET_INPUT}" == "1" ]]; then
      log "Executing remux (strategy 1): timeout 1800 ${FFMPEG_REAL} ${NET_FLAGS[*]} ... ${copy_args[-1]}"
      set +e
      timeout 1800 "${FFMPEG_REAL}" "${NET_FLAGS[@]}" "${copy_args[@]}" >> "${LOG_FILE}" 2>&1
      strategy1_status=$?
      set -e
    else
      log "Executing remux (strategy 1): timeout 1800 ${FFMPEG_REAL} ... ${copy_args[-1]}"
      set +e
      timeout 1800 "${FFMPEG_REAL}" "${copy_args[@]}" >> "${LOG_FILE}" 2>&1
      strategy1_status=$?
      set -e
    fi

    if [[ $strategy1_status -eq 0 ]]; then
      REMUX_END_TIME=$(date +%s)
      REMUX_DURATION=$((REMUX_END_TIME - REMUX_START_TIME))
      log "Remux strategy 1 (copy) succeeded in ${REMUX_DURATION}s"
      exit 0
    fi

    status=$strategy1_status
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

    if [[ "${SAW_NET_INPUT}" == "1" ]]; then
      log "Executing remux (strategy 2): timeout 1800 ${FFMPEG_REAL} ${NET_FLAGS[*]} ... ${preserve_args[-1]}"
      set +e
      timeout 1800 "${FFMPEG_REAL}" "${NET_FLAGS[@]}" "${preserve_args[@]}" >> "${LOG_FILE}" 2>&1
      strategy2_status=$?
      set -e
    else
      log "Executing remux (strategy 2): timeout 1800 ${FFMPEG_REAL} ... ${preserve_args[-1]}"
      set +e
      timeout 1800 "${FFMPEG_REAL}" "${preserve_args[@]}" >> "${LOG_FILE}" 2>&1
      strategy2_status=$?
      set -e
    fi

    if [[ $strategy2_status -eq 0 ]]; then
      REMUX_END_TIME=$(date +%s)
      REMUX_DURATION=$((REMUX_END_TIME - REMUX_START_TIME))
      log "Remux strategy 2 (preserve audio) succeeded in ${REMUX_DURATION}s"
      exit 0
    fi

    status=$strategy2_status
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

    if [[ "${SAW_NET_INPUT}" == "1" ]]; then
      log "Executing remux (strategy 3): timeout 1800 ${FFMPEG_REAL} ${NET_FLAGS[*]} ... ${transcode_args[-1]}"
    else
      log "Executing remux (strategy 3): timeout 1800 ${FFMPEG_REAL} ... ${transcode_args[-1]}"
    fi

    set +e
    if [[ "${SAW_NET_INPUT}" == "1" ]]; then
      timeout 1800 "${FFMPEG_REAL}" "${NET_FLAGS[@]}" "${transcode_args[@]}" >> "${LOG_FILE}" 2>&1
    else
      timeout 1800 "${FFMPEG_REAL}" "${transcode_args[@]}" >> "${LOG_FILE}" 2>&1
    fi
    remux_exit_code=$?
    set -e
    REMUX_END_TIME=$(date +%s)
    REMUX_DURATION=$((REMUX_END_TIME - REMUX_START_TIME))
    if [[ $remux_exit_code -eq 0 ]]; then
      log "Remux strategy 3 (transcode audio) succeeded in ${REMUX_DURATION}s"
    else
      log "Remux strategy 3 (transcode audio) failed with code=$remux_exit_code after ${REMUX_DURATION}s"
    fi
    exit $remux_exit_code
  fi

  # Only add network flags if there is at least one network input
  END_TIME=$(date +%s%N)
  DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  log "Wrapper initialization took ${DURATION_MS}ms before launching ffmpeg"

  # For catch-up downloads, add -readrate 0 to download at full speed
  # (ffmpeg 8.0+ defaults to ~1x real-time for MPEG-TS network streams)
  READRATE_FLAGS=()
  if [[ "${IS_CATCHUP}" == "1" ]]; then
    READRATE_FLAGS=( -readrate 0 )
    log "Adding -readrate 0 for full-speed catch-up download"
  fi

  # Run ffmpeg as child process (not exec) so wrapper stays alive
  # This allows Snappier to detect successful process spawn and log callbacks
  if [[ "${SAW_NET_INPUT}" == "1" ]]; then
    log "Executing: ${FFMPEG_REAL} ${READRATE_FLAGS[*]} ${NET_FLAGS[*]} ${ARGS[*]}"
    "${FFMPEG_REAL}" "${READRATE_FLAGS[@]}" "${NET_FLAGS[@]}" "${ARGS[@]}"
    exit $?
  else
    # Pure file/local remux path: no extra flags at all
    log "Executing: ${FFMPEG_REAL} ${ARGS[*]}"
    "${FFMPEG_REAL}" "${ARGS[@]}"
    exit $?
  fi
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
