#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/logs}"
LOG_FILE="${LOG:-$LOG_DIR/snappier.log}"
NOTIFY_URL="${NOTIFY_URL:-http://127.0.0.1:9080/notify}"   # POST target
STATE_FILE="${STATE_FILE:-/tmp/.logmon_seek}"
SELF_LOG="${SELF_LOG:-$LOG_DIR/log_monitor.log}"
SERIES_DIR="${SERIES_DIR:-/root/SnappierServer/TVSeries}"

# Derive a proper health URL from NOTIFY_URL's host:port
# e.g., http://127.0.0.1:9080/notify  ->  http://127.0.0.1:9080/health
HEALTH_URL="${NOTIFY_HEALTH_URL:-$(printf '%s\n' "$NOTIFY_URL" | sed -E 's#(https?://[^/]+).*#\1/health#')}"

mkdir -p "$LOG_DIR"
log(){ printf '[logmon] %s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SELF_LOG"; }

echo "======================================================================" >> "$SELF_LOG"
echo "👁️  LOG MONITOR STARTING" >> "$SELF_LOG"
echo "======================================================================" >> "$SELF_LOG"
echo "📁 Monitoring: $LOG_FILE" >> "$SELF_LOG"
echo "📫 Notify URL: $NOTIFY_URL" >> "$SELF_LOG"

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

# ──────────────────────────────────────────────────────────────────────
# Batched state updates to reduce disk I/O
# ──────────────────────────────────────────────────────────────────────
BATCH_COUNTER=0
BATCH_INTERVAL=100  # Update state file every 100 lines
LAST_BATCH_TIME=$(date +%s)

update_size(){
  BATCH_COUNTER=$((BATCH_COUNTER + 1))
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_BATCH_TIME))

  # Update if counter reaches interval OR 10 seconds have passed
  if [[ $BATCH_COUNTER -ge $BATCH_INTERVAL ]] || [[ $ELAPSED -ge 10 ]]; then
    wc -c <"$LOG_FILE" >"$STATE_FILE" 2>/dev/null || true
    BATCH_COUNTER=0
    LAST_BATCH_TIME=$NOW
  fi
}

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

  # Retry configuration
  local max_attempts="${NOTIFY_RETRY_ATTEMPTS:-3}"
  local retry_delay="${NOTIFY_RETRY_DELAY:-2}"
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    # Use -f to fail on HTTP errors, capture output and exit code
    # Increase timeout for movie/series/catchup actions (EPG/TMDB lookup takes time)
    local timeout=12  # Default 12s (uvicorn timeout-keep-alive is 30s)
    if [[ "$action" == movie_* || "$action" == series_* || "$action" == catchup_* ]]; then
      timeout=20  # Accommodate EPG/TMDB lookup + webhook processing, but avoid uvicorn timeout (30s)
      max_attempts=2  # Reduce retries since timeout is higher
    fi

    set +e  # Temporarily disable exit-on-error
    response=$(curl -fsS -m "$timeout" \
      -H 'Content-Type: application/json' \
      -X POST \
      --data "$body" \
      "$NOTIFY_URL" 2>&1)
    curl_exit=$?
    set -e

    if [[ $curl_exit -eq 0 ]]; then
      # Success
      echo "$response" | sed 's/^/[notify] /' >> "$SELF_LOG"
      log "POST succeeded (attempt $attempt/$max_attempts)"
      return 0
    else
      # Failed
      log "ERROR: POST failed (attempt $attempt/$max_attempts) with exit code $curl_exit"
      log "Response: $response"

      if [[ $attempt -lt $max_attempts ]]; then
        log "Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
        # Exponential backoff
        retry_delay=$((retry_delay * 2))
        attempt=$((attempt + 1))
      else
        log "ERROR: All $max_attempts attempts failed, giving up"
        return 1
      fi
    fi
  done
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

REGION_PREFIXES = {"US", "CA", "UK", "AU", "MX", "NZ"}

val = sys.argv[1]
if '|' in val:
    val = val.split('|', 1)[1]
val = val.strip()
val = val.replace('_', ' ')
val = re.sub(r'\.us\b', '', val, flags=re.IGNORECASE)
parts = val.split()
if len(parts) > 1 and parts[0].isalpha() and parts[0].isupper() and parts[0].upper() in REGION_PREFIXES:
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

final_media_path(){
  local ts_path="$1"
  local code="${2:-0}"
  local result="$ts_path"
  if [[ "$code" != "0" ]]; then
    printf '%s' "$result"
    return
  fi
  case "$ts_path" in
    *.ts|*.TS)
      local base="${ts_path%.[tT][sS]}"
      local cand=""
      for ext in mkv MKV mp4 MP4 m4v M4V; do
        cand="${base}.${ext}"
        if [[ -f "$cand" ]]; then
          printf '%s' "$cand"
          return
        fi
      done
      result="${base}.mkv"
      ;;
  esac
  printf '%s' "$result"
}

resolve_timestamp(){
  python3 - "$1" "${2:-}" <<'PY'
import sys
sys.path.insert(0, '/opt/scripts')
from timestamp_helpers import resolve

primary = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
fallback = (sys.argv[2] if len(sys.argv) > 2 else "").strip()
dt = resolve(primary, fallback)

if dt is not None:
    print(dt.isoformat())
elif primary:
    print(primary)
elif fallback:
    print(fallback)
else:
    print("")
PY
}

format_schedule_time(){
  python3 - "$1" "${2:-}" <<'PY'
import os, sys
sys.path.insert(0, '/opt/scripts')
from timestamp_helpers import resolve
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

primary = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
fallback = (sys.argv[2] if len(sys.argv) > 2 else "").strip()
dt = resolve(primary, fallback)

if dt is None:
    print("")
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
lower = name.lower()
for ext in ('.ts', '.mkv', '.mp4', '.m4v'):
    if lower.endswith(ext):
        name = name[: -len(ext)]
        lower = name.lower()
        break
parts = name.split('--')

def norm(s: str) -> str:
    s = (s or '').replace('_', ' ').strip()
    return re.sub(r'\s+', ' ', s)

kind = 'recording'
channel = ''
program = ''
start = ''
end = ''
uuid = ''

if parts and parts[0] == '':
    meaningful = [p for p in parts[1:] if p]
    kind = 'catchup'
    channel = ''
    program = norm(meaningful[0]) if len(meaningful) > 0 else ''
    start = meaningful[1] if len(meaningful) > 1 else ''
    uuid = meaningful[2] if len(meaningful) > 2 else ''
    end = ''
elif len(parts) == 2 and re.fullmatch(r'[A-Za-z0-9-]{8,}', parts[1] or ''):
    kind = 'movie'
    channel = ''
    program = norm(parts[0]) if parts else ''
    start = ''
    end = ''
    uuid = parts[1]
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
  local file_hint="${2:-}"
  python3 - "$job" "$file_hint" <<'PY'
import json, sys, os, glob
job = sys.argv[1]
file_hint = sys.argv[2] if len(sys.argv) > 2 else ""
program = channel = when = when_end = desc = year = movie_type = ""
paths = []
env_primary = os.environ.get("SCHEDULES_PATH")
env_secondary = os.environ.get("SCHEDULES")
for candidate in (env_primary, env_secondary,
                  "/root/SnappierServer/Recordings/schedules.json",
                  "/root/SnappierServer/schedules.json"):
    if not candidate:
        continue
    if candidate in paths:
        continue
    paths.append(candidate)

# First check schedules.json files
for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh) or {}
        info = data.get(job) or {}
        if info:
            program = info.get("programme_name", "") or info.get("program", "")
            channel = info.get("channel_name", "") or info.get("channel", "")
            # Don't use playlistName as channel - let EPG enrichment find the real channel
            when = info.get("start_time", "")
            when_end = info.get("end_time", "")
            desc = info.get("description", "") or info.get("desc", "")
            year = info.get("year", "") or info.get("releaseYear", "")
            movie_type = info.get("type", "")
            break
    except Exception:
        continue

# If not found in schedules, try metadata files (for movies)
if not program and file_hint:
    # Try to find metadata file matching the job ID
    metadata_dirs = [
        "/root/SnappierServer/Movies/metaData",
        "/root/SnappierServer/Movies/metadata",
        "/root/SnappierServer/Recordings/metaData",
        "/root/SnappierServer/Recordings/metadata",
        "/root/SnappierServer/TVSeries/metaData",
        "/root/SnappierServer/TVSeries/metadata",
    ]
    for meta_dir in metadata_dirs:
        try:
            # Look for metadata file with matching job ID
            pattern = f"{meta_dir}/*{job}*.meta.json"
            matches = glob.glob(pattern)
            if matches:
                with open(matches[0], "r", encoding="utf-8") as fh:
                    meta = json.load(fh) or {}
                program = meta.get("programme_name", "") or meta.get("program", "")
                channel = meta.get("channel_name", "") or meta.get("channel", "")
                # Don't use playlistName as channel - let EPG enrichment find the real channel
                when = meta.get("start_time", "")
                when_end = meta.get("end_time", "")
                desc = meta.get("description", "") or meta.get("desc", "")
                year = meta.get("year", "") or meta.get("releaseYear", "")
                movie_type = meta.get("type", "")
                break
        except Exception:
            continue

for key, value in (("program", program), ("channel", channel), ("start_time", when), ("end_time", when_end), ("description", desc), ("year", year), ("type", movie_type)):
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

resolve_job_meta(){
  local job="$1"
  local program="${JOB_PROGRAM[$job]:-}"
  local channel="${JOB_CHANNEL[$job]:-}"

  if [[ -z "$program" || -z "$channel" ]]; then
    declare -A S=()
    while IFS='=' read -r k v; do
      if [[ -n "$k" ]]; then
        S["$k"]="$v"
      fi
    done < <(lookup_schedule "$job")
    [[ -z "$program" ]] && program="${S[program]:-$program}"
    [[ -z "$channel" ]] && channel="${S[channel]:-$channel}"
  fi

  if [[ -z "$program" || -z "$channel" ]]; then
    declare -A BACK=()
    while IFS='=' read -r k v; do
      if [[ -n "$k" ]]; then
        BACK["$k"]="$v"
      fi
    done < <(recover_job_meta "$job")
    [[ -z "$program" ]] && program="${BACK[program]:-$program}"
    [[ -z "$channel" ]] && channel="${BACK[channel]:-$channel}"
  fi

  printf 'program=%s\n' "$program"
  printf 'channel=%s\n' "$channel"
}

find_live_job(){
  local prog="$1" channel="$2"
  python3 - "$prog" "$channel" <<'PY'
import json, os, sys, time, re
from datetime import datetime, timezone, timedelta

REGION_PREFIXES = {"US", "CA", "UK", "AU", "MX", "NZ"}

def norm(text):
    if not text:
        return ""
    text = text.replace('_', ' ').strip()
    text = re.sub(r"\.(us|ca|uk|au|mx|nz)\b", "", text, flags=re.IGNORECASE)
    parts = text.split()
    if len(parts) > 1 and parts[0].isalpha() and parts[0].isupper() and parts[0].upper() in REGION_PREFIXES:
        text = ' '.join(parts[1:])
    text = re.sub(r"\s+", " ", text)
    return text.lower()

target_prog = norm(sys.argv[1])
target_chan = norm(sys.argv[2])

env_primary = os.environ.get("SCHEDULES_PATH")
env_secondary = os.environ.get("SCHEDULES")
candidate_paths = []
for candidate in (env_primary, env_secondary,
                  "/root/SnappierServer/Recordings/schedules.json",
                  "/root/SnappierServer/schedules.json"):
    if not candidate:
        continue
    if candidate in candidate_paths:
        continue
    candidate_paths.append(candidate)

data = {}
for candidate in candidate_paths:
    try:
        with open(candidate, "r", encoding="utf-8") as fh:
            payload = json.load(fh) or {}
        if payload:
            data = payload
            break
    except Exception:
        continue

best = None
best_diff = None
best_score = None
now = time.time()

def parse_start(raw):
    if not raw:
        return None
    raw_str = str(raw).strip()
    if not raw_str:
        return None
    try:
        iso_candidate = raw_str.replace(" ", "T", 1) if " " in raw_str and "T" not in raw_str else raw_str
        iso_candidate = iso_candidate.replace("Z", "+00:00")
        return datetime.fromisoformat(iso_candidate).timestamp()
    except Exception:
        pass
    digits = "".join(ch for ch in raw_str if ch.isdigit())
    if len(digits) < 12:
        return None
    digits = (digits + "0" * 14)[:14]
    try:
        base = datetime.strptime(digits, "%Y%m%d%H%M%S")
    except Exception:
        return None
    offset_match = re.search(r'([+-]\d{2}:?\d{2})', raw_str)
    tzinfo = timezone.utc
    if offset_match:
        off = offset_match.group(1).replace(":", "")
        sign = 1 if off[0] == "+" else -1
        hours = int(off[1:3])
        minutes = int(off[3:5])
        delta = timedelta(hours=hours, minutes=minutes)
        if sign < 0:
            delta = -delta
        tzinfo = timezone(delta)
    aware = base.replace(tzinfo=tzinfo)
    return aware.timestamp()

def collect(entry, *keys):
    values = []
    seen = set()
    for key in keys:
        val = entry.get(key)
        if not isinstance(val, str):
            continue
        normed = norm(val)
        if not normed or normed in seen:
            continue
        seen.add(normed)
        values.append(normed)
    return values

def score_match(target, candidates, exact_weight=100, prefix_weight=70, partial_weight=55, token_weight=8):
    if not target or not candidates:
        return 0
    target_tokens = [tok for tok in target.split() if tok]
    best_local = 0
    for cand in candidates:
        if not cand:
            continue
        if cand == target:
            best_local = max(best_local, exact_weight)
            continue
        if cand.startswith(target) or target.startswith(cand):
            best_local = max(best_local, prefix_weight)
            continue
        if target in cand or cand in target:
            best_local = max(best_local, partial_weight)
            continue
        cand_tokens = [tok for tok in cand.split() if tok]
        overlap = len(set(target_tokens) & set(cand_tokens))
        if overlap:
            best_local = max(best_local, token_weight * overlap)
    return best_local

for job_id, entry in data.items():
    prog_candidates = collect(entry, "programme_name", "program", "programme_title", "title")
    chan_candidates = collect(entry, "channel_name", "channel", "device_name", "channel_display")

    chan_score = score_match(target_chan, chan_candidates, exact_weight=120, prefix_weight=90, partial_weight=70, token_weight=12)
    prog_score = score_match(target_prog, prog_candidates)
    combined_score = chan_score * 10 + prog_score  # weight channel higher to avoid cross-channel collisions

    if combined_score == 0:
        continue

    start_raw = entry.get("start_time") or ""
    start_ts = parse_start(start_raw)
    diff = abs(now - start_ts) if start_ts is not None else None

    better_score = best_score is None or combined_score > best_score
    same_score_better_time = (combined_score == (best_score or 0)) and diff is not None and (best_diff is None or diff < best_diff)

    if better_score or same_score_better_time:
        best = (job_id, start_raw)
        best_score = combined_score
        best_diff = diff

if best:
    job_id, start_raw = best
    print(f"job_id={job_id}")
    print(f"start={start_raw}")
PY
}

# Keep minimal state to join events
declare -A JOB_KIND=()        # job_id -> catchup|recording (best effort)
declare -A JOB_PROGRAM=()     # job_id -> program
declare -A JOB_CHANNEL=()     # job_id -> channel
declare -A JOB_FILE=()        # job_id -> file path
declare -A JOB_STATUS=()      # job_id -> last known lifecycle state
declare -A JOB_SCHEDULED_AT=()  # job_id -> formatted scheduled_at string
declare -A JOB_START_RAW=()     # job_id -> original start timestamp
declare -A JOB_START_LOCAL=()   # job_id -> formatted local start
declare -A JOB_END_RAW=()       # job_id -> original end timestamp
declare -A JOB_END_LOCAL=()     # job_id -> formatted local end
declare -A JOB_DESC=()          # job_id -> description/overview (if known)
declare -A JOB_YEAR=()          # job_id -> release year for movies
declare -A JOB_TYPE=()          # job_id -> content type/genre for movies
declare -A REMUX_EXIT_CODE=()   # ts_filename -> exit code from [remux] ffmpeg exited event

PENDING_LIVE_PROGRAM=""
PENDING_LIVE_CHANNEL=""
PENDING_LIVE_TS=0
declare -A JOB_LIVE_SENT=()  # job_id -> already notified for live start

remember_job(){
  local job="$1" kind="$2" program="$3" channel="$4"
  if [[ -n "${kind}" ]]; then
    JOB_KIND["$job"]="$kind"
  fi
  if [[ -n "${program}" && "${program,,}" != "unknown" ]]; then
    JOB_PROGRAM["$job"]="$program"
  fi
  if [[ -n "${channel}" && "${channel,,}" != "unknown" ]]; then
    JOB_CHANNEL["$job"]="$(clean_channel "$channel")"
  fi
}

delete_schedule_entry(){
  local job="$1"
  [[ -n "$job" ]] || return
  python3 - "$job" <<'PY'
import json, os, sys
job = sys.argv[1]
paths = []
for candidate in (
    os.environ.get("SCHEDULES_PATH"),
    os.environ.get("SCHEDULES"),
    "/root/SnappierServer/Recordings/schedules.json",
    "/root/SnappierServer/schedules.json",
):
    if candidate and candidate not in paths:
        paths.append(candidate)

removed = False
for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh) or {}
    except Exception:
        continue
    if job not in data:
        continue
    try:
        del data[job]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
        removed = True
    except Exception:
        continue

if removed:
    print("removed")
PY
}

set_job_status(){
  local job="$1" status="$2"
  if [[ -z "$job" || -z "$status" ]]; then
    return
  fi
  JOB_STATUS["$job"]="$status"
}

get_job_status(){
  local job="$1"
  if [[ -z "$job" ]]; then
    return
  fi
  printf '%s' "${JOB_STATUS[$job]:-}"
}

# ──────────────────────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────────────────────
while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    update_size
    continue
  fi

  line_lower="${line,,}"

  # 1) SaveCatchup start (only record job id now; send START when we get the path from FFmpeg)
  if [[ "$line" =~ \[/SaveCatchup\]\ starting\ catchup\ download\ \(job-id:\ ([A-Fa-f0-9-]+)\) ]]; then
    job="${BASH_REMATCH[1]}"
    remember_job "$job" "catchup" "" ""
    # Don't set status here - let FFmpeg download started handler send the notification
    log "catchup job seen (start marker): $job"
    update_size; continue
  fi

  # 2) SaveCatchup finished
  if [[ "$line" =~ \[/SaveCatchup\]\ catchup\ download\ finished\ \(job-id:\ ([A-Fa-f0-9-]+)\)\ with\ code=([0-9-]+) ]]; then
    job="${BASH_REMATCH[1]}"; code="${BASH_REMATCH[2]}"
    kind="${JOB_KIND[$job]:-catchup}"

    # If remux is enabled, skip notification here - remux completion will send it with the final .mkv file
    if [[ "${ENABLE_REMUX:-0}" == "1" ]] || [[ "${ENABLE_REMUX:-0}" == "true" ]]; then
      log "Catch-up download finished (job: $job), waiting for remux completion to send notification"
      update_size; continue
    fi

    # If remux is disabled, send completion notification now
    program="${JOB_PROGRAM[$job]:-}"
    channel="${JOB_CHANNEL[$job]:-}"
    file="${JOB_FILE[$job]:-}"
    start_raw="${JOB_START_RAW[$job]:-}"
    start_local="${JOB_START_LOCAL[$job]:-}"

    # Default to "catchup_completed" (maps to ACTION_MAP)
    action="catchup_completed"
    if [[ "$code" != "0" && "$code" != "" ]]; then
      action="catchup_failed"
    fi

    if [[ -n "$job" ]]; then
      declare -a payload_args=(job_id "$(shorten_job "$job")" job_id_full "$job" exit_code "$code")
      if [[ -n "$program" ]]; then
        payload_args+=(program "$program")
      fi
      if [[ -n "$channel" ]]; then
        payload_args+=(channel "$channel")
      fi
      if [[ -n "$file" ]]; then
        payload_args+=(file "$file")
      fi
      if [[ -n "$start_raw" ]]; then
        payload_args+=(start "$start_raw")
      fi
      if [[ -n "$start_local" ]]; then
        payload_args+=(start_local "$start_local")
      fi
      post_action "$action" "${payload_args[@]}"
      set_job_status "$job" "$action"
    else
      post_action "$action" exit_code "$code" program "$program" channel "$channel"
    fi
    update_size; continue
  fi

  # 3) FFmpeg download started -> has full path (good place to send catchup_started/recording_started)
  if [[ "$line" =~ \[saveWithFfmpeg\]\ Download\ started:\ ([^[:space:]]+\.(ts|TS|mkv|MKV|mp4|MP4|m4v|M4V)) ]]; then
    file="${BASH_REMATCH[1]}"
    # Parse filename into fields
    declare -A M=()
    while IFS='=' read -r k v; do M["$k"]="$v"; done < <(parse_ts_meta "$file")

    # Determine job/uuid and supplement metadata from schedules when possible
    uuid="${M[uuid]:-}"
    if [[ -z "$uuid" && "$file" =~ --([A-Za-z0-9-]{8,}) ]]; then
      uuid="${BASH_REMATCH[1]}"
      M[uuid]="$uuid"
    fi

    declare -A S=()
    if [[ -n "$uuid" ]]; then
      while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        S["$k"]="$v"
      done < <(lookup_schedule "$uuid" "$file")
    fi

    kind="${M[kind]:-recording}"
    if [[ "$file" == */Movies/* ]]; then
      kind="movie"
    elif [[ "$file" == */TVSeries/* ]]; then
      kind="series"
    fi
    program="${M[program]:-}"
    channel="${M[channel]:-}"

    # For movies and series, ALWAYS prefer schedule name over filename
    # (filenames can't have colons, proper punctuation, etc.)
    if [[ "$kind" == "movie" || "$kind" == "series" ]]; then
      if [[ -n "${S[program]:-}" ]]; then
        program="${S[program]}"
      fi
    elif [[ -z "$program" || "${program,,}" == "unknown" ]]; then
      program="${S[program]:-$program}"
    fi
    if [[ -z "$channel" || "${channel,,}" == "unknown" ]]; then
      channel="${S[channel]:-$channel}"
    fi
    if [[ "$kind" == "movie" ]]; then
      channel=""
    fi
    if [[ -z "$program" ]]; then
      program="Unknown"
    fi
    if [[ -z "$channel" ]]; then
      case "$kind" in
        movie|catchup) channel="" ;;
        *) channel="Unknown" ;;
      esac
    fi
    if [[ -n "$channel" ]]; then
      channel="$(clean_channel "$channel")"
    fi

    # Resolve start time with preference for schedule data on catch-ups (for accurate EPG lookup)
    if [[ "$kind" == "catchup" ]]; then
      start_raw="$(resolve_timestamp "${S[start_time]:-}" "${M[start]:-}")"
    else
      start_raw="$(resolve_timestamp "${M[start]:-}" "${S[start_time]:-}")"
    fi
    log "DEBUG: M[start]='${M[start]:-}' S[start_time]='${S[start_time]:-}' start_raw='$start_raw'"

    # Resolve end time (prefer schedule data over filename, as schedule is more reliable)
    end_raw="$(resolve_timestamp "${S[end_time]:-}" "${M[end]:-}")"
    log "DEBUG: M[end]='${M[end]:-}' S[end_time]='${S[end_time]:-}' end_raw='$end_raw'"

    if [[ -n "$uuid" ]]; then
      remember_job "$uuid" "$kind" "$program" "$channel"
      JOB_FILE["$uuid"]="$file"
      if [[ -n "$start_raw" ]]; then
        JOB_START_RAW["$uuid"]="$start_raw"
        start_fmt="$(format_schedule_time "$start_raw" "${M[start]:-${S[start_time]:-}}")"
        if [[ -n "$start_fmt" ]]; then
          JOB_START_LOCAL["$uuid"]="$start_fmt"
          JOB_SCHEDULED_AT["$uuid"]="$start_fmt"
        fi
      elif [[ -n "${S[start_time]:-}" ]]; then
        when_fmt="$(format_schedule_time "${S[start_time]}" "${M[start]:-}")"
        if [[ -n "$when_fmt" ]]; then
          JOB_SCHEDULED_AT["$uuid"]="$when_fmt"
          JOB_START_LOCAL["$uuid"]="$when_fmt"
        fi
      fi
      if [[ -n "$end_raw" ]]; then
        JOB_END_RAW["$uuid"]="$end_raw"
        end_fmt="$(format_schedule_time "$end_raw" "${M[end]:-${S[end_time]:-}}")"
        if [[ -n "$end_fmt" ]]; then
          JOB_END_LOCAL["$uuid"]="$end_fmt"
        fi
      fi
    fi

    job_id=""
    job_id_full=""
    if [[ -n "$uuid" ]]; then
      job_id_full="$uuid"
      job_id="$(shorten_job "$uuid")"
    fi

    action="recording_started"
    case "$kind" in
      catchup) action="catchup_started" ;;
      movie)   action="movie_started" ;;
      series)  action="series_started" ;;
      recording|live) action="recording_started" ;;
      *) action="recording_started" ;;
    esac

    desc="${S[description]:-${S[desc]:-}}"
    year="${S[year]:-${S[releaseYear]:-}}"
    movie_type="${S[type]:-}"
    if [[ -n "$job_id_full" ]]; then
      if [[ -n "$desc" ]]; then
        JOB_DESC["$job_id_full"]="$desc"
      fi
      if [[ -n "$year" ]]; then
        JOB_YEAR["$job_id_full"]="$year"
      fi
      if [[ -n "$movie_type" ]]; then
        JOB_TYPE["$job_id_full"]="$movie_type"
      fi
    fi
    start_raw=""
    if [[ -n "$job_id_full" ]]; then
      current_status="$(get_job_status "$job_id_full")"
      if [[ "$current_status" == "$action" ]]; then
        log "Skipping duplicate action '$action' for job $job_id_full"
        update_size; continue
      fi
      start_raw="${JOB_START_RAW[$job_id_full]:-}"
    fi
    if [[ -z "$start_raw" ]]; then
      if [[ "$kind" == "catchup" ]]; then
        start_raw="$(resolve_timestamp "${S[start_time]:-}" "${M[start]:-}")"
      else
        start_raw="$(resolve_timestamp "${M[start]:-}" "${S[start_time]:-}")"
      fi
    fi

    declare -a payload_args=()
    if [[ -n "$job_id_full" ]]; then
      payload_args+=(job_id "$job_id" job_id_full "$job_id_full")
    fi
    payload_args+=(program "$program")
    if [[ "$kind" != "movie" && -n "$channel" ]]; then
      payload_args+=(channel "$channel")
    fi
    start_fmt=""
    if [[ "$kind" != "movie" && -n "$start_raw" ]]; then
      payload_args+=(start "$start_raw")
      start_fmt="$(format_schedule_time "$start_raw" "${M[start]:-${S[start_time]:-}}")"
      if [[ -n "$start_fmt" ]]; then
        payload_args+=(start_local "$start_fmt")
        if [[ -n "$job_id_full" ]]; then
          JOB_START_LOCAL["$job_id_full"]="$start_fmt"
          JOB_SCHEDULED_AT["$job_id_full"]="$start_fmt"
        fi
      fi
      if [[ -n "$job_id_full" ]]; then
        JOB_START_RAW["$job_id_full"]="$start_raw"
      fi
    fi
    # Add end time to payload if available
    end_raw=""
    if [[ -n "$job_id_full" ]]; then
      end_raw="${JOB_END_RAW[$job_id_full]:-}"
    fi
    if [[ "$kind" != "movie" && -n "$end_raw" ]]; then
      payload_args+=(end "$end_raw")
      end_local="${JOB_END_LOCAL[$job_id_full]:-}"
      if [[ -n "$end_local" ]]; then
        payload_args+=(end_local "$end_local")
      fi
    fi
    if [[ -n "$desc" ]]; then
      payload_args+=(desc "$desc")
    fi
    if [[ "$kind" == "movie" ]]; then
      if [[ -n "$year" ]]; then
        payload_args+=(year "$year")
      fi
      if [[ -n "$movie_type" ]]; then
        payload_args+=(type "$movie_type")
      fi
    fi
    payload_args+=(file "$file")

    if [[ "$action" == "recording_started" && -n "$job_id_full" ]]; then
      if [[ -z "${JOB_LIVE_SENT[$job_id_full]:-}" ]]; then
        now_epoch="$(date +%s)"
        if [[ "$PENDING_LIVE_TS" -gt 0 && $((now_epoch - PENDING_LIVE_TS)) -gt 600 ]]; then
          PENDING_LIVE_PROGRAM=""
          PENDING_LIVE_CHANNEL=""
          PENDING_LIVE_TS=0
        fi
        if [[ -n "$PENDING_LIVE_PROGRAM" ]]; then
          prog_lower="${program,,}"
          pending_prog_lower="${PENDING_LIVE_PROGRAM,,}"
          chan_lower="${channel,,}"
          pending_chan_lower="${PENDING_LIVE_CHANNEL,,}"
          chan_match=0
          if [[ -z "$PENDING_LIVE_CHANNEL" ]]; then
            chan_match=1
          elif [[ "$chan_lower" == "$pending_chan_lower" ]]; then
            chan_match=1
          elif [[ "$chan_lower" == "unknown" ]]; then
            chan_match=1
          fi
          if [[ "$prog_lower" == "$pending_prog_lower" && "$chan_match" -eq 1 ]]; then
            when_fmt="${JOB_SCHEDULED_AT[$job_id_full]:-}"
            if [[ -z "$when_fmt" ]]; then
              if [[ -n "$start_fmt" ]]; then
                when_fmt="$start_fmt"
              elif [[ -n "$start_raw" ]]; then
                when_fmt="$(format_schedule_time "$start_raw" "${M[start]:-${S[start_time]:-}}")"
                [[ -z "$when_fmt" ]] && when_fmt="$start_raw"
              fi
            fi
            declare -a live_args=(job_id "$job_id" job_id_full "$job_id_full" program "$program")
            if [[ -n "$channel" ]]; then
              live_args+=(channel "$channel")
            fi
            if [[ -n "$when_fmt" ]]; then
              live_args+=(scheduled_at "$when_fmt")
            fi
            post_action "recording_live_started" "${live_args[@]}"
            set_job_status "$job_id_full" "recording_live_started"
            JOB_LIVE_SENT["$job_id_full"]=1
            PENDING_LIVE_PROGRAM=""
            PENDING_LIVE_CHANNEL=""
            PENDING_LIVE_TS=0
          fi
        fi
      fi
    fi

    post_action "$action" "${payload_args[@]}"
    if [[ -n "$job_id_full" ]]; then
      set_job_status "$job_id_full" "$action"
    fi
    update_size; continue
  fi

  # 4) Remux exit -> track status but don't send notification (remux delete will handle success case)
  if [[ "$line" =~ \[remux\]\ ffmpeg\ exited\ with\ code\ ([0-9]+)\ for\ (.+\.ts) ]]; then
    code="${BASH_REMATCH[1]}"; ts="${BASH_REMATCH[2]}"
    declare -A M=()
    while IFS='=' read -r k v; do M["$k"]="$v"; done < <(parse_ts_meta "$ts")
    uuid="${M[uuid]:-}"
    kind="${M[kind]:-recording}"

    # Skip remux notifications for movies - they'll be handled by SaveMovie event
    if [[ "$ts" == */Movies/* ]]; then
      kind="movie"
    fi
    if [[ "$kind" == "movie" ]]; then
      log "Skipping remux exit notification for movie (will use SaveMovie event): $ts"
      update_size; continue
    fi

    # Store exit code for potential failure notification, but don't send success notification yet
    # (remux delete will handle success; we only notify on failure here)

    program="${M[program]:-}"
    channel="${M[channel]:-}"

    if [[ -n "$uuid" ]]; then
      if [[ -z "$program" || "${program,,}" == "unknown" ]]; then
        program="${JOB_PROGRAM[$uuid]:-$program}"
      fi
      if [[ "$kind" == "movie" ]]; then
        channel=""
      elif [[ -z "$channel" || "${channel,,}" == "unknown" ]]; then
        channel="${JOB_CHANNEL[$uuid]:-$channel}"
      fi
    fi

    if [[ -n "$channel" ]]; then
      channel="$(clean_channel "$channel")"
    fi

    declare -A REMUX_SCHED=()
    if [[ -n "$uuid" ]]; then
      while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        REMUX_SCHED["$k"]="$v"
      done < <(lookup_schedule "$uuid")
    fi

    if [[ -n "$uuid" ]]; then
      remember_job "$uuid" "$kind" "$program" "$channel"
    fi

    # Store the remux exit code for validation when we see the delete event
    REMUX_EXIT_CODE["$ts"]="$code"

    # Only send notification on FAILURE (code != 0)
    # Success notifications will be sent by remux delete handler
    if [[ "$code" == "0" ]]; then
      log "Remux succeeded for $ts (code=$code), will wait for delete event to send notification"
      if [[ -n "$uuid" ]]; then
        remember_job "$uuid" "$kind" "$program" "$channel"
      fi
      update_size; continue
    fi

    # Failure case - send notification immediately
    final_file="$(final_media_path "$ts" "$code")"

    # Determine failure action by kind
    if [[ "$kind" == "catchup" ]]; then
      action="catchup_failed"
    elif [[ "$kind" == "movie" ]]; then
      action="movie_failed"
    elif [[ "$kind" == "series" ]]; then
      action="series_failed"
    else
      action="recording_failed"
    fi

    if [[ -n "$uuid" ]]; then
      desc="${REMUX_SCHED[description]:-${REMUX_SCHED[desc]:-}}"
      start_raw="${JOB_START_RAW[$uuid]:-${REMUX_SCHED[start_time]:-}}"
      if [[ -z "$start_raw" ]]; then
        start_raw="$(resolve_timestamp "${REMUX_SCHED[start_time]:-}" "${M[start]:-}")"
      fi
      start_local="${JOB_START_LOCAL[$uuid]:-${REMUX_SCHED[start_local]:-}}"

      declare -a args=(job_id "$(shorten_job "$uuid")" job_id_full "$uuid" exit_code "$code" program "$program")
      if [[ "$kind" != "movie" && -n "$channel" ]]; then
        args+=(channel "$channel")
      fi
      if [[ -n "$desc" ]]; then
        args+=(desc "$desc")
      fi
      if [[ "$kind" != "movie" && -n "$start_raw" ]]; then
        args+=(start "$start_raw")
        if [[ -z "$start_local" ]]; then
          start_local="$(format_schedule_time "$start_raw" "${REMUX_SCHED[start_time]:-${JOB_START_RAW[$uuid]:-}}")"
        fi
        JOB_START_RAW["$uuid"]="$start_raw"
      fi
      if [[ -n "$start_local" ]]; then
        args+=(start_local "$start_local")
        JOB_START_LOCAL["$uuid"]="$start_local"
        JOB_SCHEDULED_AT["$uuid"]="$start_local"
      fi
      args+=(file "$final_file")
      post_action "$action" "${args[@]}"
      set_job_status "$uuid" "$action"
    else
      declare -a args=(exit_code "$code" program "$program")
      if [[ -n "$channel" ]]; then
        args+=(channel "$channel")
      fi
      args+=(file "$final_file")
      post_action "$action" "${args[@]}"
    fi
    update_size; continue
  fi

  # 5) Remux delete -> send completion notification with .mkv file (but not for movies - they use SaveMovie event)
  if [[ "$line" =~ \[remux\]\ deleted:\ (.+\.ts) ]]; then
    ts="${BASH_REMATCH[1]}"

    # Parse metadata from .ts filename
    declare -A M=()
    while IFS='=' read -r k v; do M["$k"]="$v"; done < <(parse_ts_meta "$ts")
    uuid="${M[uuid]:-}"
    kind="${M[kind]:-recording}"

    # Validate the remux exit code - should have already seen a successful exit event
    prior_exit_code="${REMUX_EXIT_CODE["$ts"]:-}"
    if [[ -z "$prior_exit_code" ]]; then
      log "WARNING: Delete event for $ts but no prior exit event in logs"
    elif [[ "$prior_exit_code" != "0" ]]; then
      log "WARNING: Delete event for $ts but prior exit had code=$prior_exit_code (non-zero failure)"
    fi

    # Skip remux delete notifications for movies - they'll be handled by SaveMovie event
    if [[ "$ts" == */Movies/* ]]; then
      kind="movie"
    fi
    if [[ "$kind" == "movie" ]]; then
      log "Skipping remux delete notification for movie (will use SaveMovie event): $ts"
      update_size; continue
    fi

    program="${M[program]:-}"
    channel="${M[channel]:-}"

    # Get stored metadata
    if [[ -n "$uuid" ]]; then
      if [[ -z "$program" || "${program,,}" == "unknown" ]]; then
        program="${JOB_PROGRAM[$uuid]:-$program}"
      fi
      if [[ -z "$channel" || "${channel,,}" == "unknown" ]]; then
        channel="${JOB_CHANNEL[$uuid]:-$channel}"
      fi
    fi

    if [[ -n "$channel" ]]; then
      channel="$(clean_channel "$channel")"
    fi

    # Remux success assumed (deleted means successful remux)
    code="0"
    final_file="$(final_media_path "$ts" "$code")"

    # Validate that the .mkv file exists and is not empty before marking as success
    if [[ ! -f "$final_file" ]]; then
      log "ERROR: Remux delete event for $ts but .mkv file missing: $final_file"
      code="1"
    elif [[ ! -s "$final_file" ]]; then
      log "ERROR: Remux delete event for $ts but .mkv file is empty: $final_file"
      code="1"
    else
      # Log successful remux with file size
      file_size_bytes=$(stat -c%s "$final_file" 2>/dev/null || echo "unknown")
      log "Remux completed successfully: $final_file (size: $file_size_bytes bytes)"
    fi

    # Determine action based on success/failure
    if [[ "$code" != "0" ]]; then
      # Remux failed (file missing or empty)
      if [[ "$kind" == "catchup" ]]; then
        action="catchup_failed"
      elif [[ "$kind" == "movie" ]]; then
        action="movie_failed"
      elif [[ "$kind" == "series" ]]; then
        action="series_failed"
      else
        action="recording_failed"
      fi
    else
      # Remux succeeded
      if [[ "$kind" == "catchup" ]]; then
        action="catchup_completed"
      elif [[ "$kind" == "movie" ]]; then
        action="movie_completed"
      elif [[ "$kind" == "series" ]]; then
        action="series_completed"
      else
        action="recording_completed"
      fi
    fi

    # Send notification with complete metadata
    if [[ -n "$uuid" ]]; then
      # Use filename timestamp if available (more reliable than schedule data)
      start_raw="${JOB_START_RAW[$uuid]:-${M[start]:-}}"
      if [[ "$kind" == "movie" ]]; then
        start_raw=""
        start_local=""
      else
        if [[ -z "$start_raw" ]]; then
          start_raw="$(resolve_timestamp "${M[start]:-}" "${REMUX_SCHED[start_time]:-}")"
        fi
        start_local="${JOB_START_LOCAL[$uuid]:-}"
        if [[ -z "$start_local" && -n "$start_raw" ]]; then
          start_local="$(format_schedule_time "$start_raw" "${M[start]:-${REMUX_SCHED[start_time]:-${JOB_START_RAW[$uuid]:-}}}")"
        fi
      fi

      declare -a args=(job_id "$(shorten_job "$uuid")" job_id_full "$uuid" exit_code "$code" program "$program")
      if [[ "$kind" != "movie" && -n "$channel" ]]; then
        args+=(channel "$channel")
      fi
      if [[ "$kind" != "movie" && -n "$start_raw" ]]; then
        args+=(start "$start_raw")
      fi
      if [[ "$kind" != "movie" && -n "$start_local" ]]; then
        args+=(start_local "$start_local")
      fi
      args+=(file "$final_file")
      post_action "$action" "${args[@]}"
      set_job_status "$uuid" "$action"
    fi

    update_size; continue
  fi

  # 6) Immediate schedule start (explicit program/channel in log)
  if [[ "$line" =~ \[/ScheduleRecording\]\ immediate\ branch:\ starting\ recording\ now\ for\ (.+)\ on\ (.+)$ ]]; then
    log "immediate branch matched: $line"
    prog="$(echo "${BASH_REMATCH[1]}" | trim)"
    chan_raw="$(echo "${BASH_REMATCH[2]}" | trim)"
    chan="$(clean_channel "$chan_raw")"

    job_info="$(find_live_job "$prog" "$chan")"
    declare -A LIVE=()
    if [[ -n "$job_info" ]]; then
      while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        LIVE["$k"]="$v"
      done <<< "$job_info"
    fi

    job_uuid="${LIVE[job_id]:-}"
    sched_raw="${LIVE[start]:-}"

    if [[ -n "$job_uuid" ]]; then
      remember_job "$job_uuid" "recording" "$prog" "$chan"
      JOB_LIVE_SENT["$job_uuid"]=1
    when_resolved="$(resolve_timestamp "$sched_raw" "${JOB_START_RAW[$job_uuid]:-${JOB_SCHEDULED_AT[$job_uuid]:-}}")"
    when_fmt="$(format_schedule_time "$when_resolved" "$sched_raw")"
      [[ -z "$when_fmt" ]] && when_fmt="$sched_raw"
      post_action "recording_live_started" \
        job_id "$(shorten_job "$job_uuid")" \
        job_id_full "$job_uuid" \
        program "$prog" \
        channel "$chan" \
        scheduled_at "$when_fmt"
      set_job_status "$job_uuid" "recording_live_started"
      PENDING_LIVE_PROGRAM=""
      PENDING_LIVE_CHANNEL=""
      PENDING_LIVE_TS=0
    else
      PENDING_LIVE_PROGRAM="$prog"
      PENDING_LIVE_CHANNEL="$chan"
      PENDING_LIVE_TS="$(date +%s)"
      log "deferring live start notification until job-id is known (program='$prog', channel='$chan')"
    fi
    update_size; continue
  fi

  if [[ "$line" =~ \[/ScheduleRecording\]\ scheduling\ stop_([A-Fa-f0-9-]+)\ at\ ([^[:space:]]+) ]]; then
    log "scheduling stop matched: $line"
    job_uuid="${BASH_REMATCH[1]}"
    when="${BASH_REMATCH[2]}"

    declare -A INFO=()
    while IFS='=' read -r k v; do
      if [[ -n "$k" ]]; then
        INFO["$k"]="$v"
      fi
    done < <(resolve_job_meta "$job_uuid")

    prog="${PENDING_LIVE_PROGRAM:-${INFO[program]:-Unknown}}"
    chan="${PENDING_LIVE_CHANNEL:-${INFO[channel]:-Unknown}}"
    prog="$(printf '%s' "$prog" | trim)"
    chan="$(printf '%s' "$chan" | trim)"
    chan="$(clean_channel "$chan")"

    remember_job "$job_uuid" "recording" "$prog" "$chan"

    when_resolved="$(resolve_timestamp "$when" "${JOB_START_RAW[$job_uuid]:-${JOB_SCHEDULED_AT[$job_uuid]:-}}")"
    when_fmt="$(format_schedule_time "$when_resolved" "$when")"
    [[ -z "$when_fmt" ]] && when_fmt="$when_resolved"

    JOB_SCHEDULED_AT["$job_uuid"]="$when_fmt"
    if [[ "$(get_job_status "$job_uuid")" != "recording_scheduled" ]]; then
      set_job_status "$job_uuid" "recording_scheduled"
    fi

    PENDING_LIVE_PROGRAM=""
    PENDING_LIVE_CHANNEL=""
    update_size; continue
  fi

  if [[ "$line" =~ \[/ScheduleRecording\]\ scheduled\ branch:\ scheduling\ start_([A-Fa-f0-9-]+)\ at\ ([^[:space:]]+) ]]; then
    log "scheduled branch matched: $line"
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
    when_resolved="$(resolve_timestamp "$when_raw" "${JOB_SCHEDULED_AT[$job]:-${JOB_START_RAW[$job]:-}}")"
    formatted_when="$(format_schedule_time "$when_resolved" "$when_raw")"
    [[ -z "$formatted_when" ]] && formatted_when="$when_resolved"

    # Process end time if available
    end_raw="$(printf '%s' "${S[end_time]:-}" | trim)"
    end_resolved=""
    formatted_end=""
    if [[ -n "$end_raw" ]]; then
      end_resolved="$(resolve_timestamp "$end_raw" "")"
      formatted_end="$(format_schedule_time "$end_resolved" "$end_raw")"
      [[ -z "$formatted_end" ]] && formatted_end="$end_resolved"
    fi

    remember_job "$job" "recording" "$prog" "$chan"
    JOB_SCHEDULED_AT["$job"]="$formatted_when"
    JOB_START_RAW["$job"]="$when_resolved"
    if [[ -n "$end_resolved" ]]; then
      JOB_END_RAW["$job"]="$end_resolved"
      JOB_END_LOCAL["$job"]="$formatted_end"
    fi

    # Send notification with both raw timestamp (for EPG lookup) and formatted time (for display)
    log "DEBUG: when_raw='$when_raw' when_resolved='$when_resolved' formatted_when='$formatted_when'"
    log "DEBUG: end_raw='$end_raw' end_resolved='$end_resolved' formatted_end='$formatted_end'"
    declare -a sched_args=(job_id "$(shorten_job "$job")" job_id_full "$job" program "$prog" channel "$chan")
    if [[ -n "$when_resolved" ]]; then
      sched_args+=(start "$when_resolved")
      log "DEBUG: Added start=$when_resolved to notification"
    else
      log "DEBUG: when_resolved is empty, cannot add start timestamp"
    fi
    if [[ -n "$formatted_when" ]]; then
      sched_args+=(scheduled_at "$formatted_when")
    fi
    if [[ -n "$end_resolved" ]]; then
      sched_args+=(end "$end_resolved")
      log "DEBUG: Added end=$end_resolved to notification"
    fi
    if [[ -n "$formatted_end" ]]; then
      sched_args+=(end_local "$formatted_end")
      log "DEBUG: Added end_local=$formatted_end to notification"
    fi
    post_action "recording_scheduled" "${sched_args[@]}"
    set_job_status "$job" "recording_scheduled"
    update_size; continue
  fi

  if [[ "$line" =~ \[saveLiveWithFFmpeg\]\ suppressed\ exit\ for\ cancelled\ job\ ([A-Za-z0-9-]+),\ code=([0-9-]+) ]]; then
    job="${BASH_REMATCH[1]}"
    code="${BASH_REMATCH[2]}"
    if [[ "$code" == "0" ]]; then
      log "skipping cancellation notice for job $job (exit code=0)"
      update_size; continue
    fi
    status="$(get_job_status "$job")"
    if [[ "$status" == "recording_completed" || "$status" == "recording_failed" ]]; then
      log "suppressing cancellation notice for completed job $job (code=$code)"
      update_size; continue
    fi
    if [[ "$status" == "recording_cancelled" ]]; then
      log "deduplicating cancellation notice for job $job"
      update_size; continue
    fi
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
    set_job_status "$job" "recording_cancelled"
    update_size; continue
  fi

  if [[ "$line" =~ \[/?SaveMovie\]\ process\ closed\ for\ job\ ([A-Za-z0-9-]+):\ code=([0-9-]+),\ signal=([^,]*),\ filename=([^,]+),\ programme_name=(.+)$ ]] || \
     [[ "$line" =~ \[[^]]+\]\ \[/?SaveMovie\]\ process\ closed\ for\ job\ ([A-Za-z0-9-]+):\ code=([0-9-]+),\ signal=([^,]*),\ filename=([^,]+),\ programme_name=(.+)$ ]]; then
    job="${BASH_REMATCH[1]}"
    code="${BASH_REMATCH[2]}"
    file="${BASH_REMATCH[4]}"
    program_raw="${BASH_REMATCH[5]}"
    program="$(printf '%s' "$program_raw" | trim)"

    current_status="$(get_job_status "$job")"
    if [[ "$current_status" == "movie_completed" || "$current_status" == "movie_failed" ]]; then
      log "Skipping duplicate SaveMovie notification for job $job (already $current_status)"
      if [[ "$code" == "0" ]]; then
        delete_schedule_entry "$job"
      fi
      update_size; continue
    fi

    declare -A SCHED=()
    while IFS='=' read -r k v; do
      [[ -z "$k" ]] && continue
      SCHED["$k"]="$v"
    done < <(lookup_schedule "$job" "$file")

    if [[ -z "$program" || "${program,,}" == "unknown" ]]; then
      program="${SCHED[program]:-$program}"
    fi
    [[ -z "$program" ]] && program="Unknown"

    channel=""

    remember_job "$job" "movie" "$program" "$channel"
    if [[ -n "${SCHED[start_time]:-}" ]]; then
      when_resolved="$(resolve_timestamp "${SCHED[start_time]}" "${JOB_START_RAW[$job]:-}")"
      when_fmt="$(format_schedule_time "$when_resolved" "${SCHED[start_time]}")"
      [[ -n "$when_fmt" ]] && JOB_SCHEDULED_AT["$job"]="$when_fmt"
    fi

    action="movie_completed"
    [[ "$code" != "0" ]] && action="movie_failed"

    if [[ "$file" != /* ]]; then
      file="/root/SnappierServer/Movies/$file"
    fi

    desc="${SCHED[description]:-${SCHED[desc]:-}}"
    year="${SCHED[year]:-${SCHED[releaseYear]:-}}"
    movie_type="${SCHED[type]:-}"

    if [[ -n "$desc" ]]; then
      JOB_DESC["$job"]="$desc"
    fi
    if [[ -n "$year" ]]; then
      JOB_YEAR["$job"]="$year"
    fi
    if [[ -n "$movie_type" ]]; then
      JOB_TYPE["$job"]="$movie_type"
    fi

    declare -a args=(job_id "$(shorten_job "$job")" job_id_full "$job" exit_code "$code" program "$program")
    if [[ -n "$channel" ]]; then
      args+=(channel "$channel")
    fi
    if [[ -n "$desc" ]]; then
      args+=(desc "$desc")
    fi
    if [[ -n "$year" ]]; then
      args+=(year "$year")
    fi
    if [[ -n "$movie_type" ]]; then
      args+=(type "$movie_type")
    fi
    args+=(file "$file")

    post_action "$action" "${args[@]}"
    set_job_status "$job" "$action"
    if [[ "$code" == "0" ]]; then
      delete_schedule_entry "$job"
    fi
    update_size; continue
  fi

  # ============ SaveTVSeries starting handler ============
  # Example: [/SaveTVSeries] starting TV series "Tulsa King (2022)" episode "S1E5 - Token Joe" download (job-id: 78bdbbac-8937-469c-ae95-d731a74e78e9)
  if [[ "$line" =~ \[/SaveTVSeries\]\ starting\ TV\ series\ \"([^\"]+)\"\ episode\ \"([^\"]+)\"\ download\ \(job-id:\ ([A-Za-z0-9-]+)\) ]]; then
    series_name="${BASH_REMATCH[1]}"
    episode="${BASH_REMATCH[2]}"
    job="${BASH_REMATCH[3]}"

    log "SaveTVSeries starting: series='$series_name' episode='$episode' job=$job"

    # Build args array - no channel for VOD items
    args=(job_id "$(shorten_job "$job")" job_id_full "$job" program "$series_name" episode "$episode")

    post_action "series_started" "${args[@]}"
    set_job_status "$job" "series_started"
    update_size; continue
  fi

  # ============ SaveTVSeries finished handler ============
  # Example: [/SaveTVSeries] TV series "Tulsa King (2022)" episode "S1E2 - Center of the Universe" download finished (job-id: 3b0d1008-ba5d-4005-8604-961a44b83fbf) with code=0, signal=null
  if [[ "$line" =~ \[/SaveTVSeries\]\ TV\ series\ \"([^\"]+)\"\ episode\ \"([^\"]+)\"\ download\ finished\ \(job-id:\ ([A-Za-z0-9-]+)\)\ with\ code=([0-9-]+) ]]; then
    series_name="${BASH_REMATCH[1]}"
    episode="${BASH_REMATCH[2]}"
    job="${BASH_REMATCH[3]}"
    code="${BASH_REMATCH[4]}"

    log "SaveTVSeries event: series='$series_name' episode='$episode' job=$job code=$code"

    action="series_completed"
    if [[ "$code" != "0" ]]; then
      action="series_failed"
    fi

    # Try to find the series file
    file=""
    if [[ -d "$SERIES_DIR" ]]; then
      # Look for files with this job ID (exclude metadata files)
      found=$(find "$SERIES_DIR" -type f -name "*${job}*" ! -name "*.meta.json" 2>/dev/null | head -1)
      if [[ -n "$found" ]]; then
        file="$found"
        log "Found series file: $file"
      fi
    fi

    # Lookup schedule metadata
    declare -A META=()
    while IFS='=' read -r k v; do
      if [[ -n "$k" ]]; then
        META["$k"]="$v"
      fi
    done < <(lookup_schedule "$job" "$file")

    # For series, Snappier stores series name in channel and episode in program
    # Use channel as the series name if available, otherwise use parsed series_name
    program="${META[channel]:-$series_name}"

    # Build args array - no channel for VOD items
    args=(job_id "$(shorten_job "$job")" job_id_full "$job" program "$program" episode "$episode")
    if [[ -n "$file" ]]; then
      args+=(file "$file")
    fi
    if [[ "$code" != "0" ]]; then
      args+=(exit_code "$code")
    fi

    post_action "$action" "${args[@]}"
    set_job_status "$job" "$action"
    if [[ "$code" == "0" ]]; then
      delete_schedule_entry "$job"
    fi
    update_size; continue
  fi

  # Match "scheduled job callback: starting" messages (when scheduled recording actually begins in v1.3.1+)
  if [[ "$line" =~ \[/ScheduleRecording\]\ scheduled\ job\ callback:\ starting[[:space:]]*([^[:space:]].*?)?\ on\ (.+)\ \(job-id:\ ([A-Za-z0-9-]+)\) ]]; then
    prog="${BASH_REMATCH[1]}"
    chan_raw="${BASH_REMATCH[2]}"
    job="${BASH_REMATCH[3]}"

    log "scheduled job callback matched for job $job"
    prog="$(printf '%s' "$prog" | trim)"
    chan="$(printf '%s' "$chan_raw" | trim)"
    chan="$(clean_channel "$chan")"

    # Send recording_started notification with scheduled time info
    when_fmt="${JOB_SCHEDULED_AT[$job]:-}"
    start_raw="${JOB_START_RAW[$job]:-}"

    # Prefer schedule/job metadata when callback line omits program/channel
    if [[ -z "$prog" || "${prog,,}" == "unknown" ]]; then
      fallback_prog="${JOB_PROGRAM[$job]:-}"
      if [[ -n "$fallback_prog" ]]; then
        prog="$(printf '%s' "$fallback_prog" | trim)"
      else
        prog="Unknown"
      fi
    fi
    if [[ -z "$chan" || "${chan,,}" == "unknown" ]]; then
      fallback_chan="${JOB_CHANNEL[$job]:-}"
      if [[ -n "$fallback_chan" ]]; then
        chan="$(printf '%s' "$fallback_chan" | trim)"
      fi
      chan="$(clean_channel "$chan")"
      [[ -z "$chan" ]] && chan="Unknown"
    fi
    remember_job "$job" "recording" "$prog" "$chan"

    declare -a args=(job_id "$(shorten_job "$job")" job_id_full "$job" program "$prog" channel "$chan")
    if [[ -n "$start_raw" ]]; then
      args+=(start "$start_raw")
    fi
    if [[ -n "$when_fmt" ]]; then
      args+=(start_local "$when_fmt")
    fi

    post_action "recording_started" "${args[@]}"
    set_job_status "$job" "recording_started"
    update_size; continue
  fi

  if [[ "$line_lower" == *"scheduled job start_"* ]]; then
    if [[ "$line" =~ start_([A-Za-z0-9-]+) ]]; then
      job="${BASH_REMATCH[1]}"

      # Don't send notification here if we already sent recording_live_started
      if [[ -n "${JOB_LIVE_SENT[$job]:-}" ]]; then
        log "Skipping scheduled job notification - already sent recording_live_started for job $job"
        update_size; continue
      fi

      declare -A INFO=()
      while IFS='=' read -r k v; do
        if [[ -n "$k" ]]; then
          INFO["$k"]="$v"
        fi
      done < <(resolve_job_meta "$job")
      program="$(printf '%s' "${INFO[program]:-Unknown}" | trim)"
      channel="$(printf '%s' "${INFO[channel]:-Unknown}" | trim)"

      if [[ -z "$program" || "${program,,}" == "unknown" ]]; then
        fallback_prog="${JOB_PROGRAM[$job]:-}"
        if [[ -n "$fallback_prog" ]]; then
          program="$(printf '%s' "$fallback_prog" | trim)"
        else
          program="Unknown"
        fi
      fi
      if [[ -z "$channel" || "${channel,,}" == "unknown" ]]; then
        fallback_chan="${JOB_CHANNEL[$job]:-}"
        if [[ -n "$fallback_chan" ]]; then
          channel="$(printf '%s' "$fallback_chan" | trim)"
        fi
      fi
      channel="$(clean_channel "$channel")"
      [[ -z "$channel" ]] && channel="Unknown"
      remember_job "$job" "recording" "$program" "$channel"

      if [[ "$line_lower" == *"start successfully"* ]]; then
        # Send recording_started notification (not recording_job_started)
        # This is the actual recording beginning
        when_fmt="${JOB_SCHEDULED_AT[$job]:-}"
        start_raw="${JOB_START_RAW[$job]:-}"

        declare -a args=(job_id "$(shorten_job "$job")" job_id_full "$job" program "$program" channel "$channel")
        if [[ -n "$start_raw" ]]; then
          args+=(start "$start_raw")
        fi
        if [[ -n "$when_fmt" ]]; then
          args+=(start_local "$when_fmt")
        fi

        post_action "recording_started" "${args[@]}"
        set_job_status "$job" "recording_started"
        update_size; continue
      fi

      if [[ "$line_lower" == *"completed successfully"* ]]; then
        # This is just job scheduling completion, not recording completion
        # Don't send a notification for this
        log "Scheduled job completed successfully (job setup): $job"
        update_size; continue
      fi
    fi
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
