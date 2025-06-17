#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG:-/logs/snappier.log}"
NOTIFY_URL="${NOTIFY_URL:-http://127.0.0.1:9080/notify}"   # POST target
STATE_FILE="/tmp/.logmon_seek"
SELF_LOG="/logs/log_monitor.log"

# Derive a proper health URL from NOTIFY_URL's host:port
# e.g., http://127.0.0.1:9080/notify  ->  http://127.0.0.1:9080/health
HEALTH_URL="${NOTIFY_HEALTH_URL:-$(printf '%s\n' "$NOTIFY_URL" | sed -E 's#(https?://[^/]+).*#\1/health#')}"

mkdir -p /logs
log(){ printf '[logmon] %s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$SELF_LOG" >&2; }

echo "======================================================================" | tee -a "$SELF_LOG"
echo "👁️  LOG MONITOR STARTING" | tee -a "$SELF_LOG"
echo "======================================================================" | tee -a "$SELF_LOG"
echo "📁 Monitoring: $LOG_FILE" | tee -a "$SELF_LOG"
echo "📫 Notify URL: $NOTIFY_URL" | tee -a "$SELF_LOG"

# ──────────────────────────────────────────────────────────────────────
# Webhook health probe (use /health on the same host:port)
# ──────────────────────────────────────────────────────────────────────
for i in {1..30}; do
  curl -fsS -m 1 "$HEALTH_URL" >/dev/null 2>&1 && { log "notify_webhook is reachable ($HEALTH_URL)"; break; }
  sleep 0.5
done

# ──────────────────────────────────────────────────────────────────────
# Wait for logfile to exist (or create empty)
# ──────────────────────────────────────────────────────────────────────
for i in {1..40}; do
  if [[ -f "$LOG_FILE" ]]; then
    break
  fi
  sleep 0.25
done
[[ -f "$LOG_FILE" ]] || { log "Log file not found: $LOG_FILE (creating empty)"; : >"$LOG_FILE"; }

# ──────────────────────────────────────────────────────────────────────
# Resume read position if possible
# ──────────────────────────────────────────────────────────────────────
START_OPT=""
if [[ -f "$STATE_FILE" ]]; then
  LAST_SZ="$(cat "$STATE_FILE" || echo 0)"
  CUR_SZ="$(wc -c <"$LOG_FILE" || echo 0)"
  if [[ "$CUR_SZ" -gt "$LAST_SZ" ]]; then
    START_OPT="--bytes=+$((LAST_SZ+1))"
  fi
fi
update_size(){ wc -c <"$LOG_FILE" >"$STATE_FILE" 2>/dev/null || true; }

# ──────────────────────────────────────────────────────────────────────
# JSON helpers (Python is available in the image)
# ──────────────────────────────────────────────────────────────────────
post_kv(){  # build {"k":"v",...} safely
  python3 - "$@" <<'PY'
import json,sys
args=sys.argv[1:]
d={}
it=iter(args)
for k,v in zip(it,it):
    d[k]=v
print(json.dumps(d, ensure_ascii=False))
PY
}

post_action() {
  # $1 = action, remaining as k v k v ...
  action="$1"; shift || true
  body="$(post_kv action "$action" "$@")"
  log "POST → $NOTIFY_URL : $body"
  curl -sS -m 8 -H 'Content-Type: application/json' -X POST --data "$body" "$NOTIFY_URL" \
    | sed 's/^/[notify] /' | tee -a "$SELF_LOG" || log "WARN: POST failed"
}

trim(){ sed 's/^[[:space:]]*//;s/[[:space:]]*$//' ; }

# ──────────────────────────────────────────────────────────────────────
# Metadata derivation from TS filenames
# Patterns seen:
#   Recording:  Channel--Program--START--END--UUID.ts
#   Catch-up :  --Program--START--UUID.ts           (no channel segment)
# ──────────────────────────────────────────────────────────────────────
basename_noext(){
  local p="$1"
  p="${p##*/}"           # strip path
  p="${p%.ts}"           # strip extension
  printf '%s' "$p"
}

normalize_text(){
  # Replace sequences of underscores with spaces, collapse spaces, trim
  printf '%s' "$1" | sed -E 's/_+/ /g; s/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g'
}

clean_channel(){
  python3 - "$1" <<'PY'
import re, sys
val = sys.argv[1]
if '|' in val:
    val = val.split('|', 1)[1]
val = val.strip()
val = re.sub(r'\.us\b', '', val, flags=re.IGNORECASE)
parts = val.split()
if len(parts) > 1 and len(parts[0]) <= 2 and parts[0].isalpha() and parts[0].isupper():
    val = ' '.join(parts[1:])
val = re.sub(r'\s+', ' ', val)
print(val.strip())
PY
}

shorten_job(){
  local id="$1"
  [[ -z "$id" ]] && return
  if [[ "$id" =~ ^([a-f0-9]{8})- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif (( ${#id} > 12 )); then
    printf '%s…' "${id:0:12}"
  else
    printf '%s' "$id"
  fi
}

format_schedule_time(){
  python3 - "$1" <<'PY'
import os, sys
from datetime import datetime, timezone, timedelta
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

raw = (sys.argv[1] or "").strip()
if not raw:
    print("")
    raise SystemExit

dt = None
iso_candidate = raw.replace('Z', '+00:00')
try:
    dt = datetime.fromisoformat(iso_candidate)
except Exception:
    dt = None

if dt is None:
    parts = raw.split()
    base = parts[0]
    off = parts[1] if len(parts) > 1 else "+0000"
    try:
        dt = datetime.strptime(base, "%Y%m%d%H%M%S")
        sign = 1 if off.startswith('+') else -1
        hours = int(off[1:3])
        minutes = int(off[3:5])
        offset = timedelta(seconds=sign * (hours * 3600 + minutes * 60))
        dt = dt.replace(tzinfo=timezone(offset))
    except Exception:
        print(raw)
        raise SystemExit

tz_name = os.environ.get("TZ")
if tz_name and ZoneInfo is not None:
    try:
        dt = dt.astimezone(ZoneInfo(tz_name))
    except Exception:
        dt = dt.astimezone()
else:
    dt = dt.astimezone()

print(dt.strftime("%Y-%m-%d %I:%M %p %Z"))
PY
}

parse_ts_meta(){
  # echo 'key=value' lines for: kind, channel, program, start, end, uuid
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path

path = sys.argv[1]
name = Path(path).name
if name.lower().endswith('.ts'):
    name = name[:-3]
parts = name.split('--')

def norm(s: str) -> str:
    s = (s or '').replace('_', ' ').strip()
    return re.sub(r'\s+', ' ', s)

if parts and parts[0] == '':
    meaningful = [p for p in parts[1:] if p]
    kind = 'catchup'
    channel = ''
    program = norm(meaningful[0]) if len(meaningful) > 0 else ''
    start = meaningful[1] if len(meaningful) > 1 else ''
    uuid = meaningful[2] if len(meaningful) > 2 else ''
    end = ''
else:
    kind = 'recording'
    channel = norm(parts[0]) if parts else ''
    program = norm(parts[1]) if len(parts) > 1 else ''
    start = parts[2] if len(parts) > 2 else ''
    end = parts[3] if len(parts) > 3 else ''
    uuid = parts[4] if len(parts) > 4 else ''

for key, value in (
    ('kind', kind),
    ('channel', channel),
    ('program', program),
    ('start', start),
    ('end', end),
    ('uuid', uuid),
):
    print(f'{key}={value}')
PY
}

lookup_schedule(){
  local job="$1"
  python3 - "$job" <<'PY'
import json, sys, os
job = sys.argv[1]
path = "/root/SnappierServer/Recordings/schedules.json"
program = channel = when = ""
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    info = data.get(job) or {}
    program = info.get("programme_name", "") or info.get("program", "")
    channel = info.get("channel_name", "") or info.get("channel", "")
    when = info.get("start_time", "")
except Exception:
    pass
for key, value in (("program", program), ("channel", channel), ("start_time", when)):
    print(f"{key}={value}")
PY
}

recover_job_meta(){
  local job="$1"
  python3 - "$job" "$LOG_FILE" <<'PY'
import sys, re
job = sys.argv[1]
path = sys.argv[2]
program = ""
channel = ""

def norm(text):
    return re.sub(r"\s+", " ", text.replace("_", " ").strip())

try:
    with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
        lines = fh.readlines()
    for line in reversed(lines[-5000:]):
        if job not in line:
            continue
        if 'Download started:' in line or '.ts' in line:
            m = re.search(r'(/[^\s]+\.ts)', line)
            if m:
                core = m.group(1).split('/')[-1]
                if core.lower().endswith('.ts'):
                    core = core[:-3]
                parts = core.split('--')
                if parts and parts[0] == '':
                    if len(parts) > 1:
                        program = norm(parts[1]) or program
                else:
                    if parts:
                        channel = norm(parts[0]) or channel
                    if len(parts) > 1:
                        program = norm(parts[1]) or program
                if program or channel:
                    break
        if 'immediate branch' in line:
            m = re.search(r'for (.+) on (.+)$', line.strip())
            if m:
                program = norm(m.group(1)) or program
                channel = norm(m.group(2)) or channel
                break
        if 'recorded process for job-id' in line and '--' in line:
            parts = line.split('--')
            if parts:
                channel = norm(parts[0].split(':')[-1]) or channel
            if len(parts) > 1:
                program = norm(parts[1]) or program
            if program or channel:
                break
except Exception:
    pass

print(f"program={program}")
print(f"channel={channel}")
PY
}

# Keep minimal state to join events
declare -A JOB_KIND=()      # job_id -> catchup|recording (best effort)
declare -A JOB_PROGRAM=()   # job_id -> program
declare -A JOB_CHANNEL=()   # job_id -> channel

remember_job(){
  local job="$1" kind="$2" program="$3" channel="$4"
  if [[ -n "${kind}" ]]; then
    JOB_KIND["$job"]="$kind"
  fi
  if [[ -n "${program}" ]]; then
    JOB_PROGRAM["$job"]="$program"
  fi
  if [[ -n "${channel}" ]]; then
    JOB_CHANNEL["$job"]="$(clean_channel "$channel")"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────────────────────
while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    update_size
    continue
  fi

  # 1) SaveCatchup start (only record job id now; send START when we get the path)
  if [[ "$line" =~ \[/SaveCatchup\]\ starting\ catchup\ download\ \(job-id:\ ([a-f0-9-]+)\) ]]; then
    job="${BASH_REMATCH[1]}"
    remember_job "$job" "catchup" "" ""
    log "catchup job seen (start marker): $job"
    update_size; continue
  fi

  # 2) SaveCatchup finished
  if [[ "$line" =~ \[/SaveCatchup\]\ catchup\ download\ finished\ \(job-id:\ ([a-f0-9-]+)\)\ with\ code=([0-9-]+) ]]; then
    job="${BASH_REMATCH[1]}"; code="${BASH_REMATCH[2]}"
    kind="${JOB_KIND[$job]:-catchup}"
    program="${JOB_PROGRAM[$job]:-}"
    channel="${JOB_CHANNEL[$job]:-}"
    # Default to "catchup_completed" (maps to ACTION_MAP)
    action="catchup_completed"
    if [[ "$code" != "0" && "$code" != "" ]]; then
      action="catchup_failed"
    fi
    if [[ -n "$job" ]]; then
      post_action "$action" job_id "$(shorten_job "$job")" job_id_full "$job" exit_code "$code" program "$program" channel "$channel"
    else
      post_action "$action" exit_code "$code" program "$program" channel "$channel"
    fi
    update_size; continue
  fi

  # 3) FFmpeg download started -> has full path (good place to send catchup_started/recording_started)
  if [[ "$line" =~ \[saveWithFfmpeg\]\ Download\ started:\ (.+\.ts) ]]; then
    file="${BASH_REMATCH[1]}"
    # Parse filename into fields
    declare -A M=()
    while IFS='=' read -r k v; do M["$k"]="$v"; done < <(parse_ts_meta "$file")
    if [[ -n "${M[channel]:-}" ]]; then
      M[channel]="$(clean_channel "${M[channel]}")"
    fi

    # Try to backfill a job UUID if present in the name
    uuid="${M[uuid]:-}"
    if [[ -n "$uuid" ]]; then
      remember_job "$uuid" "${M[kind]:-}" "${M[program]:-}" "${M[channel]:-}"
      job_id="$uuid"
    else
      job_id=""
    fi

    if [[ "${M[kind]}" == "catchup" ]]; then
      if [[ -n "$job_id" ]]; then
        post_action "catchup_started" job_id "$(shorten_job "$job_id")" job_id_full "$job_id" program "${M[program]}" channel "${M[channel]}" file "$file"
      else
        post_action "catchup_started" program "${M[program]}" channel "${M[channel]}" file "$file"
      fi
    else
      # live/manual recording
      if [[ -n "$job_id" ]]; then
        post_action "recording_started" job_id "$(shorten_job "$job_id")" job_id_full "$job_id" program "${M[program]}" channel "${M[channel]}" file "$file"
      else
        post_action "recording_started" program "${M[program]}" channel "${M[channel]}" file "$file"
      fi
    fi
    update_size; continue
  fi

  # 4) Remux exit -> treat as completion for both catchup and recording
  if [[ "$line" =~ \[remux\]\ ffmpeg\ exited\ with\ code\ ([0-9]+)\ for\ (.+\.ts) ]]; then
    code="${BASH_REMATCH[1]}"; ts="${BASH_REMATCH[2]}"
    declare -A M=()
    while IFS='=' read -r k v; do M["$k"]="$v"; done < <(parse_ts_meta "$ts")
    if [[ -n "${M[channel]:-}" ]]; then
      M[channel]="$(clean_channel "${M[channel]}")"
    fi
    uuid="${M[uuid]:-}"

    # Try to infer final action by kind
    if [[ "${M[kind]}" == "catchup" ]]; then
      action="catchup_completed"
    else
      action="recording_completed"
    fi
    if [[ "$code" != "0" ]]; then
      action="${action%completed}failed"
    fi

    if [[ -n "$uuid" ]]; then
      post_action "$action" \
        job_id "$(shorten_job "$uuid")" \
        job_id_full "$uuid" \
        exit_code "$code" \
        program "${M[program]}" \
        channel "${M[channel]}" \
        file "$ts"
    else
      post_action "$action" \
        exit_code "$code" \
        program "${M[program]}" \
        channel "${M[channel]}" \
        file "$ts"
    fi
    update_size; continue
  fi

  # 5) Remux delete (not a user-visible event; keep for webhook enrichment if desired)
  if [[ "$line" =~ \[remux\]\ deleted:\ (.+\.ts) ]]; then
    ts="${BASH_REMATCH[1]}"
    # No-op for notifications; still record size and carry on
    update_size; continue
  fi

  # 6) Immediate schedule start (explicit program/channel in log)
  if [[ "$line" =~ \[/ScheduleRecording\]\ immediate\ branch:\ starting\ recording\ now\ for\ (.+)\ on\ (.+)$ ]]; then
    prog="$(echo "${BASH_REMATCH[1]}" | trim)"
    chan="$(echo "${BASH_REMATCH[2]}" | trim)"
    chan="$(clean_channel "$chan")"
    post_action "recording_live_started" program "$prog" channel "$chan"
    update_size; continue
  fi

  if [[ "$line" =~ \[/ScheduleRecording\]\ scheduled\ branch:\ scheduling\ start_([a-f0-9-]+)\ at\ ([^[:space:]]+) ]]; then
    job="${BASH_REMATCH[1]}"
    when="${BASH_REMATCH[2]}"
    declare -A S=()
    while IFS='=' read -r k v; do
      if [[ -n "$k" ]]; then
        S["$k"]="$v"
      fi
    done < <(lookup_schedule "$job")
    prog="$(printf '%s' "${S[program]:-Unknown}" | trim)"
    chan="$(printf '%s' "${S[channel]:-Unknown}" | trim)"
    chan="$(clean_channel "$chan")"
    when_raw="$(printf '%s' "${S[start_time]:-$when}" | trim)"
    formatted_when="$(format_schedule_time "$when_raw")"
    [[ -z "$formatted_when" ]] && formatted_when="$when_raw"
    remember_job "$job" "recording" "$prog" "$chan"
    post_action "recording_scheduled" job_id "$(shorten_job "$job")" job_id_full "$job" program "$prog" channel "$chan" scheduled_at "$formatted_when"
    update_size; continue
  fi

  if [[ "$line" =~ \[saveLiveWithFFmpeg\]\ suppressed\ exit\ for\ cancelled\ job\ ([A-Za-z0-9-]+),\ code=([0-9-]+) ]]; then
    job="${BASH_REMATCH[1]}"
    code="${BASH_REMATCH[2]}"
    program="${JOB_PROGRAM[$job]:-Unknown}"
    channel="${JOB_CHANNEL[$job]:-Unknown}"
    if [[ "$program" == "Unknown" || "$channel" == "Unknown" ]]; then
      declare -A BACK=()
      while IFS='=' read -r k v; do BACK["$k"]="$v"; done < <(recover_job_meta "$job")
      [[ "$program" == "Unknown" || -z "$program" ]] && program="${BACK[program]:-$program}"
      [[ "$channel" == "Unknown" || -z "$channel" ]] && channel="${BACK[channel]:-$channel}"
    fi
    channel="$(clean_channel "$channel")"
    remember_job "$job" "recording" "$program" "$channel"
    post_action "recording_cancelled" job_id "$(shorten_job "$job")" job_id_full "$job" exit_code "$code" program "$program" channel "$channel"
    update_size; continue
  fi

  # (Optional) You can add a matcher for a “scheduled successfully” future branch once you see its exact log text.
  # Example placeholder (disabled):
  # if [[ "$line" =~ \[/ScheduleRecording\]\ scheduled\ successfully\ for\ (.+)\ on\ (.+)\ at\ (.+)$ ]]; then
  #   prog="$(echo "${BASH_REMATCH[1]}" | trim)"
  #   chan="$(echo "${BASH_REMATCH[2]}" | trim)"
  #   when="$(echo "${BASH_REMATCH[3]}" | trim)"
  #   post_action "recording_scheduled" program "$prog" channel "$chan" scheduled_at "$when"
  #   update_size; continue
  # fi

  update_size
done < <(stdbuf -oL -eL tail -Fn0 $START_OPT "$LOG_FILE")
