#!/usr/bin/env bash
set -euo pipefail

# -------- Config (env tunables) --------
ALLOW_HTTP="${ALLOW_HTTP:-0}"
ALLOW_HTTP_HOSTS="${ALLOW_HTTP_HOSTS:-localhost,127.0.0.1,snappier-server}"
HTTPS_PROBE_TIMEOUT="${HTTPS_PROBE_TIMEOUT:-3}"
HTTPS_PROBE_METHOD="${HTTPS_PROBE_METHOD:-HEAD}"   # HEAD or GET

# Network flags (applied only for http/https inputs)
NET_FLAGS=( -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 \
            -reconnect_on_network_error 1 -reconnect_on_http_error 4xx,5xx \
            -rw_timeout 15000000 -timeout 15000000 )

# -------- Helpers --------
is_http_like(){ [[ "$1" == http://* || "$1" == https://* ]]; }

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
  curl -fsSIL --max-time "${HTTPS_PROBE_TIMEOUT}" "$url" >/dev/null 2>&1 && return 0
  [[ "${HTTPS_PROBE_METHOD}" == "GET" ]] && \
    curl -fsSL --range 0-0 --max-time "${HTTPS_PROBE_TIMEOUT}" "$url" >/dev/null 2>&1 && return 0
  return 1
}

rewrite_arg(){
  local arg="$1"
  # only rewrite http://… inputs; never touch outputs or other args
  [[ "${arg}" != http://* ]] && { printf '%s\n' "${arg}"; return; }
  [[ "${ALLOW_HTTP}" == "1" ]] && { printf '%s\n' "${arg}"; return; }
  local rest="${arg#http://}"
  local host="${rest%%/*}"
  host_is_safe_http "${host}" && { printf '%s\n' "${arg}"; return; }
  local https_url="https://${rest}"
  if try_https "${https_url}"; then
    printf '%s\n' "${https_url}"
  else
    printf '%s\n' "${arg}"
  fi
}

# -------- Build final argv --------
ARGS=()
SAW_NET_INPUT=0
for a in "$@"; do
  if is_http_like "$a"; then
    SAW_NET_INPUT=1
  fi
  ARGS+=("$(rewrite_arg "$a")")
done

# Only add network flags if there is at least one network input
if [[ "${SAW_NET_INPUT}" == "1" ]]; then
  exec /usr/local/bin/ffmpeg.real "${NET_FLAGS[@]}" "${ARGS[@]}"
else
  # Pure file/local remux path: no extra flags at all
  exec /usr/local/bin/ffmpeg.real "${ARGS[@]}"
fi
