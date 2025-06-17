from flask import Flask, request, jsonify
import json, os, time, requests, urllib.parse

app = Flask(__name__)

PO_USER  = os.environ.get('PUSHOVER_USER_KEY','')
PO_TOKEN = os.environ.get('PUSHOVER_APP_TOKEN','')
EPG_CACHE = os.environ.get('EPG_CACHE','/root/SnappierServer/epg/epg_cache.json')
SCHEDULES = os.environ.get('SCHEDULES','/root/SnappierServer/schedules.json')
TITLE_PREFIX = os.environ.get('NOTIFY_TITLE_PREFIX','🎬 Snappier')

PROBE_TIMEOUT = int(os.environ.get('HTTPS_PROBE_TIMEOUT','3'))
PROBE_METHOD  = os.environ.get('HTTPS_PROBE_METHOD','HEAD').upper()
SAFE_HTTP_HOSTS = set((os.environ.get('ALLOW_HTTP_HOSTS','localhost,127.0.0.1,snappier-server').split(',')))

SNAPPY_API_ENABLED = os.environ.get('SNAPPY_API_ENABLED','1') in ('1','true','True','yes','YES')
SNAPPY_API_BASE    = os.environ.get('SNAPPY_API_BASE','http://127.0.0.1:8000').rstrip("/")
SNAPPY_API_KEY     = os.environ.get('SNAPPY_API_KEY','')
SNAPPY_API_TIMEOUT = float(os.environ.get('SNAPPY_API_TIMEOUT','5'))

_https_support = {}

def load_json(path):
    try:
        with open(path,'r',encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None

def _host_from_url(url: str):
    try:
        return urllib.parse.urlparse(url).hostname
    except Exception:
        return None

def _probe_https_once(url_http: str) -> bool:
    if not url_http.startswith('http://'):
        return False
    https_url = 'https://' + url_http[len('http://'):]
    host = _host_from_url(https_url)
    if not host or host in SAFE_HTTP_HOSTS:
        return False
    if host in _https_support:
        return _https_support[host]
    try:
        if PROBE_METHOD == 'GET':
            r = requests.get(https_url, timeout=PROBE_TIMEOUT, stream=True)
        else:
            r = requests.head(https_url, timeout=PROBE_TIMEOUT, allow_redirects=True)
        ok = 200 <= r.status_code < 400
    except Exception:
        ok = False
    _https_support[host] = ok
    return ok

def _preflight_scan():
    try:
        for path in (SCHEDULES, EPG_CACHE):
            data = load_json(path)
            if not data: continue
            def walk(o, seen=0, limit=2000):
                if seen >= limit: return seen
                if isinstance(o, dict):
                    for _, v in o.items():
                        seen = walk(v, seen, limit)
                        if seen >= limit: break
                elif isinstance(o, list):
                    for v in o:
                        seen = walk(v, seen, limit)
                        if seen >= limit: break
                elif isinstance(o, str):
                    if o.startswith('http://'):
                        _probe_https_once(o)
                        seen += 1
                return seen
            walk(data, 0, 2000)
    except Exception:
        pass

def _api_headers():
    h = {'Accept': 'application/json'}
    if SNAPPY_API_KEY:
        h['Authorization'] = f'Bearer {SNAPPY_API_KEY}'
    return h

def api_search(title=None, channel=None, limit=10):
    if not SNAPPY_API_ENABLED:
        return None, {}
    try:
        params = {}
        if title:   params['title'] = title
        if channel: params['channel'] = channel
        if limit:   params['limit'] = str(limit)
        url = f"{SNAPPY_API_BASE}/epg/search"
        r = requests.get(url, params=params, headers=_api_headers(), timeout=SNAPPY_API_TIMEOUT)
        if not r.ok:
            return None, {}
        hits = r.json()
        meta = {'total': r.headers.get('X-Total-Results'), 'returned': r.headers.get('X-Returned-Results')}
        if isinstance(hits, list) and hits:
            return hits, meta
        return None, meta
    except Exception:
        return None, {}

def _coerce_event(ev):
    if not isinstance(ev, dict): return None
    title = ev.get('title') or ev.get('name') or ev.get('programTitle')
    subtitle = ev.get('subtitle') or ev.get('episodeTitle')
    desc = ev.get('desc') or ev.get('description')
    start = ev.get('start') or ev.get('start_ts') or ev.get('startTime')
    channel = ev.get('channel') or ev.get('channelName') or ev.get('ch')
    typ = ev.get('type')
    year = ev.get('year') or ev.get('releaseYear')
    return {'title': title, 'subtitle': subtitle, 'desc': desc, 'start': start, 'channel': channel, 'type': typ, 'year': year}

def _pick_best_from_list(lst, want_title=None):
    want = (want_title or '').strip().lower()
    best = None
    for ev in lst:
        cev = _coerce_event(ev)
        if not cev: continue
        if want and (cev.get('title','').lower() == want):
            return cev
        if best is None:
            best = cev
    return best

def api_find_program(channel=None, title=None):
    hits, meta = (None, {})
    if title and channel:
        hits, meta = api_search(title=title, channel=channel, limit=10)
        if hits: return _pick_best_from_list(hits, title), meta
    if title:
        hits, meta = api_search(title=title, limit=10)
        if hits: return _pick_best_from_list(hits, title), meta
    if channel:
        hits, meta = api_search(channel=channel, limit=10)
        if hits: return _pick_best_from_list(hits), meta
    return None, meta

def cache_find_program(channel=None, title=None, start_ts=None):
    epg = load_json(EPG_CACHE) or {}
    try:
        if channel and 'channels' in epg:
            ch = epg['channels'].get(channel) or epg['channels'].get(str(channel))
            if ch and 'events' in ch:
                if title:
                    for ev in ch['events']:
                        if title.lower() in (ev.get('title','').lower()):
                            return ev
                if start_ts:
                    for ev in ch['events']:
                        if int(ev.get('start',0)) == int(start_ts):
                            return ev
        if 'channels' in epg and title:
            for _, chdata in list(epg['channels'].items())[:100]:
                for ev in chdata.get('events',[])[:200]:
                    if title.lower() in ev.get('title','').lower():
                        return ev
    except Exception:
        pass
    return None

def pushover_send(title, message, url=None, url_title=None, priority=0):
    if not (PO_USER and PO_TOKEN):
        return {'ok': False, 'error':'Pushover not configured'}
    data = {'token': PO_TOKEN,'user': PO_USER,'title': title,'message': message,'priority': priority}
    if url: data['url'] = url
    if url_title: data['url_title'] = url_title
    r = requests.post('https://api.pushover.net/1/messages.json', data=data, timeout=15)
    try:
        return r.json()
    except Exception:
        return {'ok': r.ok, 'status': r.status_code}

_ACTION_MAP = {
    # canonical actions
    "catchup_started":      {"title": "Catch-Up Download Started 📥", "priority": 0},
    "catchup_completed":    {"title": "Catch-Up Download Completed ✅", "priority": 0},
    "catchup_failed":       {"title": "Catch-Up Download Failed ❗",   "priority": 1},
    "catchup_exit":         {"title": "Catch-Up Download Exited ⏹️",  "priority": 0},

    "movie_started":        {"title": "Movie Download Started 🎬",     "priority": 0},
    "movie_completed":      {"title": "Movie Download Completed ✅",   "priority": 0},
    "movie_failed":         {"title": "Movie Download Failed ❗",      "priority": 1},
    "movie_exit":           {"title": "Movie Download Exited ⏹️",      "priority": 0},

    "series_started":       {"title": "Series Download Started 🎞️",   "priority": 0},
    "series_completed":     {"title": "Series Download Completed ✅",  "priority": 0},
    "series_failed":        {"title": "Series Download Failed ❗",     "priority": 1},
    "series_exit":          {"title": "Series Download Exited ⏹️",     "priority": 0},

    "recording_scheduled":  {"title": "Recording Scheduled 🗓️",        "priority": 0},
    "recording_started":    {"title": "Recording Started 🔴",          "priority": 0},
    "recording_live_started": {"title": "Recording Started 🔴",        "priority": 0},
    "recording_completed":  {"title": "Recording Completed ✅",         "priority": 0},
    "recording_failed":     {"title": "Recording Failed ❗",           "priority": 1},
    "recording_cancelled":  {"title": "Recording Cancelled ❌",         "priority": 0},

    "health_warn":          {"title": "Health Warning ❗",             "priority": 1},
    "server_error":         {"title": "Server Error ❗",               "priority": 1},
    "server_failed":        {"title": "Server Failure ❗",             "priority": 1},
    "epg_match":            {"title": "EPG Match 📇",                  "priority": -2},
    "ffmpeg_retry":         {"title": "Stream Reconnected/Upgraded 🔁","priority": -1},

    # extra events emitted by the log monitor (low priority/noise)
    "remux_started":        {"title": "Remux Started 🧩",              "priority": -2},
    "remux_finished":       {"title": "Remux Finished ✅",             "priority": -2},
    "download_started":     {"title": "Download Started 📥",           "priority": -2},
    "cleanup_deleted_ts":   {"title": "Cleanup: TS Deleted 🧹",        "priority": -2},

    # synonyms for older emitters
    "catchup_finished":     {"title": "Catch-Up Download Completed ✅", "priority": 0},
}

def safe_trim(s: str, limit: int) -> str:
    s = (s or "").strip()
    return (s[:limit] + "…") if len(s) > limit else s

def _as_int(x, default=None):
    try: return int(x)
    except: return default

@app.route('/notify', methods=['POST'])
def notify():
    payload = None
    try:
        if request.is_json:
            payload = request.get_json(force=True, silent=True)
        else:
            raw = request.get_data(as_text=True) or ''
            try: payload = json.loads(raw)
            except Exception: payload = {'text': raw}
    except Exception:
        payload = {'text': request.get_data(as_text=True) or ''}

    channel = (payload or {}).get('channel') or (payload or {}).get('ch')
    title   = (payload or {}).get('title')   or (payload or {}).get('program')
    start   = (payload or {}).get('start')   or (payload or {}).get('ts')

    meta = None
    used_api = False
    if SNAPPY_API_ENABLED and (title or channel):
        meta, _ = api_find_program(channel=channel, title=title)
        used_api = bool(meta)
    if not meta:
        meta = cache_find_program(channel, title, start)

    action = (payload or {}).get('action', '').strip().lower()

    program_name = ((payload or {}).get("program") or (payload or {}).get("title") or (meta or {}).get("title") or "Unknown")
    job_id       = (payload or {}).get("job_id") or "Unknown"
    channel_name = (payload or {}).get("channel") or (meta or {}).get("channel") or "Unknown"

    kind = (payload or {}).get("type") or (meta or {}).get("type")
    year = (payload or {}).get("year") or (meta or {}).get("year")
    desc_raw = (payload or {}).get("desc") or (meta or {}).get("desc") or (meta or {}).get("description")

    duration_min = (payload or {}).get("duration_min")
    filepath     = (payload or {}).get("file")
    error_msg    = (payload or {}).get("error")
    exit_code    = _as_int((payload or {}).get("exit_code"))
    exit_reason  = (payload or {}).get("exit_reason")
    scheduled_at = (payload or {}).get("scheduled_at")

    # suppress noise for *_exit with code==0
    if action.endswith("_exit"):
        if exit_code is None or exit_code == 0:
            return jsonify({"ok": True, "suppressed": True, "reason": "exit_code==0", "action": action})

    DESC_LIMIT = int(os.environ.get("NOTIFY_DESC_LIMIT", "900"))
    desc = safe_trim(desc_raw, DESC_LIMIT)

    lines = []
    lines.append(f"📺 {program_name}")
    lines.append(f"🆔 Job ID: {job_id}")
    lines.append(f"📡 Channel: {channel_name}")

    if action == "recording_scheduled" and scheduled_at:
        lines.append(f"🗓️ Starts: {scheduled_at}")

    header_bits = []
    if kind: header_bits.append(kind)
    if year: header_bits.append(f"({year})")
    lines.append("\n📝 " + " ".join(header_bits) if header_bits else "\n📝")

    if desc:
        lines.append(desc)

    tail = []
    if action in ("recording_completed", "catchup_completed", "movie_completed", "series_completed"):
        if duration_min: tail.append(f"⏱️ {duration_min} min")
        if filepath:     tail.append(f"📁 {filepath}")

    if action.endswith("_failed") or action in ("server_error", "server_failed", "health_warn"):
        if error_msg:     tail.append(f"⚠️ {error_msg}")
        if exit_code is not None: tail.append(f"🔢 exit={exit_code}")
        if exit_reason:   tail.append(f"🧰 {exit_reason}")

    if action.endswith("_exit") and (exit_code is not None or exit_reason):
        if exit_code is not None: tail.append(f"🔢 exit={exit_code}")
        if exit_reason:   tail.append(f"🧰 {exit_reason}")

    if tail:
        lines.append("\n" + " • ".join(tail))

    body = "\n".join(lines).strip()

    default_title = (payload or {}).get("title") or program_name
    action_meta = _ACTION_MAP.get(action, {"title": default_title, "priority": 0})
    push_title = action_meta["title"]
    priority   = action_meta["priority"]

    res = pushover_send(
        title=f"{push_title}",
        message=body,
        url=None,
        url_title=None,
        priority=priority
    )

    return jsonify({
        "ok": True,
        "pushover": res,
        "enriched": bool(meta),
        "used_api": used_api,
        "action": action
    })

@app.route('/https-capabilities', methods=['GET'])
def https_caps():
    return jsonify({'hosts': _https_support})

@app.route('/health', methods=['GET'])
def health():
    return jsonify({'ok': True, 'ts': time.time(), 'api_enabled': SNAPPY_API_ENABLED})

__ = _preflight_scan()

if __name__ == '__main__':
    app.run(host=os.environ.get('NOTIFICATION_HTTP_BIND','127.0.0.1'),
            port=int(os.environ.get('NOTIFICATION_HTTP_PORT','9080')))
