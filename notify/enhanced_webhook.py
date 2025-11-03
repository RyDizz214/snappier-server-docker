from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
import json, os, time, urllib.parse, re, logging, sys
from datetime import datetime, timezone, timedelta
from collections import OrderedDict
import httpx
import asyncio
import aiofiles

# Structured logging setup
class StructuredLogger:
    """Structured logging with levels for better observability"""
    def __init__(self, name):
        self.name = name
        self.log_level = os.environ.get('WEBHOOK_LOG_LEVEL', 'INFO').upper()
        self.levels = {'DEBUG': 0, 'INFO': 1, 'WARNING': 2, 'ERROR': 3}
        self.current_level = self.levels.get(self.log_level, 1)

    def _format(self, level, msg, extra=None):
        ts = datetime.now(timezone.utc).isoformat()
        parts = [f"[{ts}]", f"[{self.name}]", f"[{level}]", msg]
        if extra:
            parts.append(f"| {extra}")
        return " ".join(parts)

    def debug(self, msg, extra=None):
        if self.levels.get('DEBUG', 0) >= self.current_level:
            print(self._format("DEBUG", msg, extra), flush=True)

    def info(self, msg, extra=None):
        if self.levels.get('INFO', 1) >= self.current_level:
            print(self._format("INFO", msg, extra), flush=True)

    def warning(self, msg, extra=None):
        if self.levels.get('WARNING', 2) >= self.current_level:
            print(self._format("WARNING", msg, extra), file=sys.stderr, flush=True)

    def error(self, msg, extra=None):
        if self.levels.get('ERROR', 3) >= self.current_level:
            print(self._format("ERROR", msg, extra), file=sys.stderr, flush=True)

logger = StructuredLogger("webhook")

# Import TMDB helper
try:
    from tmdb_helper import enrich_movie_metadata, enrich_series_metadata
    TMDB_AVAILABLE = True
except ImportError:
    TMDB_AVAILABLE = False
    logger.warning("TMDB helper not available", "Movie/series metadata enrichment disabled")

# Notification deduplication cache (TTL-based)
# Prevents duplicate notifications from being processed within a 60-second window
import hashlib
_notification_cache = OrderedDict()  # Track recent notifications with timestamp
NOTIFICATION_DEDUP_WINDOW = 60  # seconds

def _check_and_record_notification(action, job_id_full, file_path):
    """
    Check if notification was recently sent, and record it if not.
    Returns: (is_duplicate, time_since_last)
    """
    # Create dedup key from action + full job ID + file path
    dedup_key = hashlib.md5(
        f"{action}:{job_id_full}:{file_path}".encode()
    ).hexdigest()

    current_time = time.time()

    # Check if we've seen this notification recently
    if dedup_key in _notification_cache:
        last_sent = _notification_cache[dedup_key]
        elapsed = current_time - last_sent

        if elapsed < NOTIFICATION_DEDUP_WINDOW:
            return (True, elapsed)  # Is a duplicate

        # Remove old entry if outside window
        del _notification_cache[dedup_key]

    # Record this notification
    _notification_cache[dedup_key] = current_time

    # Keep cache size bounded (remove oldest entries if > 1000)
    while len(_notification_cache) > 1000:
        _notification_cache.popitem(last=False)

    return (False, 0)  # Not a duplicate

app = FastAPI(title="Snappier Webhook", version="1.0")

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

# Cache limits
EPG_INDEX_MAX_SIZE = int(os.environ.get('EPG_INDEX_MAX_SIZE', '50000'))
HTTPS_CACHE_MAX_SIZE = int(os.environ.get('HTTPS_CACHE_MAX_SIZE', '1000'))

# Bounded LRU cache implementation
class BoundedDict(OrderedDict):
    """LRU cache with maximum size limit"""
    def __init__(self, max_size):
        super().__init__()
        self.max_size = max_size

    def __getitem__(self, key):
        # Move to end on access (LRU behavior)
        value = super().__getitem__(key)
        self.move_to_end(key)
        return value

    def __setitem__(self, key, value):
        if key in self:
            # Move to end (mark as recently used)
            del self[key]
        super().__setitem__(key, value)
        # Evict oldest if over limit
        while len(self) > self.max_size:
            oldest = next(iter(self))
            del self[oldest]

_https_support = BoundedDict(HTTPS_CACHE_MAX_SIZE)
_epg_cache_data = None
_epg_cache_mtime = None
_epg_index = None
_epg_channel_display = {}
_cache_stats = {'epg_hits': 0, 'epg_misses': 0, 'https_probes': 0, 'memory_warnings': 0}

_OFFSET_PATTERN = re.compile(r'^[+-]\d{4}$')

def clean_channel_name(value):
    """
    Normalize channel names that often include region codes, IDs, or suffixes.
    Mirrors the behaviour from the log monitor (bash) with a few extra guards.
    """
    if not value:
        return ""
    val = str(value).strip()
    if not val:
        return ""

    if '|' in val:
        pieces = [p.strip() for p in val.split('|') if p.strip()]
        if pieces:
            val = pieces[-1]

    val = val.replace('_', ' ')
    val = re.sub(r'\.(us|ca|uk|au|mx|tv)\b', '', val, flags=re.IGNORECASE)
    val = val.replace('/', ' / ')
    val = re.sub(r'\s+', ' ', val).strip()

    # Remove region prefixes (handle both "US " and "US:" formats)
    region_prefixes = {"US", "CA", "UK", "AU", "MX", "NZ"}
    for prefix in region_prefixes:
        # Match prefix with colon or space (e.g., "US:", "US ", "US: ")
        if val.upper().startswith(prefix):
            remainder = val[len(prefix):].lstrip(': ')
            if remainder:  # Only remove prefix if there's content after it
                val = remainder
                break

    return val.strip(' -:')

def _pick_channel_name(*values):
    for val in values:
        cleaned = clean_channel_name(val)
        if cleaned:
            return cleaned
    return ""

def _parse_timestamp(raw):
    if not raw:
        return None
    text = str(raw).strip()
    if not text:
        return None

    if text.endswith('Z'):
        try:
            return datetime.fromisoformat(text.replace('Z', '+00:00'))
        except Exception:
            pass

    sanitized = text.replace('T', '')
    base = sanitized
    offset = None
    for idx in range(8, len(sanitized)):
        ch = sanitized[idx]
        if ch in '+-':
            base = sanitized[:idx]
            offset = sanitized[idx:]
            break

    digits = re.sub(r'[^0-9]', '', base)
    if len(digits) < 6:
        return None
    if len(digits) < 14:
        digits = digits.ljust(14, '0')
    else:
        digits = digits[:14]

    try:
        dt = datetime.strptime(digits, "%Y%m%d%H%M%S")
    except ValueError:
        return None

    tz = timezone.utc
    if offset:
        offset = offset.strip().replace(':', '')  # Strip whitespace before checking pattern
        if _OFFSET_PATTERN.match(offset):
            sign = 1 if offset[0] == '+' else -1
            hours = int(offset[1:3])
            minutes = int(offset[3:5])
            delta = timedelta(hours=hours, minutes=minutes)
            if sign < 0:
                delta = -delta
            tz = timezone(delta)

    return dt.replace(tzinfo=tz)

def _normalize_start(raw):
    dt = _parse_timestamp(raw)
    if dt is None:
        return None
    try:
        return int(dt.timestamp())
    except Exception:
        return None

async def _load_epg_cache():
    global _epg_cache_data, _epg_cache_mtime, _epg_index, _epg_channel_display
    path = EPG_CACHE
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = None

    if _epg_cache_data is None or mtime != _epg_cache_mtime:
        _epg_cache_data = await load_json(path) or {}
        _epg_cache_mtime = mtime
        _epg_index = None
        _epg_channel_display = {}

    return _epg_cache_data

async def _ensure_epg_index():
    global _epg_index, _epg_channel_display, _cache_stats
    data = await _load_epg_cache()
    if _epg_index is not None:
        _cache_stats['epg_hits'] += 1
        return data, _epg_index

    _cache_stats['epg_misses'] += 1
    programmes = data.get('programmes') or []
    by_start = {}
    by_title = {}
    total_entries = 0

    for ev in programmes:
        start_key = _normalize_start(ev.get('start'))
        if start_key is not None:
            by_start.setdefault(start_key, []).append(ev)
            total_entries += 1
        title = (ev.get('title') or '').strip().lower()
        if title:
            bucket = by_title.setdefault(title, [])
            if len(bucket) < 50:
                bucket.append(ev)
                total_entries += 1

    # Enforce size limits by keeping most recent/relevant entries
    if total_entries > EPG_INDEX_MAX_SIZE:
        _cache_stats['memory_warnings'] += 1
        # Keep only recent timestamps in by_start
        if len(by_start) > EPG_INDEX_MAX_SIZE // 2:
            sorted_keys = sorted(by_start.keys(), reverse=True)[:EPG_INDEX_MAX_SIZE // 2]
            by_start = {k: by_start[k] for k in sorted_keys}

        # Keep most populated titles in by_title
        if len(by_title) > EPG_INDEX_MAX_SIZE // 2:
            sorted_titles = sorted(by_title.items(), key=lambda x: len(x[1]), reverse=True)[:EPG_INDEX_MAX_SIZE // 2]
            by_title = dict(sorted_titles)

    display = {}
    channels = data.get('channels') or {}
    for key, meta in channels.items():
        if not isinstance(meta, dict):
            continue
        chan_id = meta.get('id') or key
        disp = meta.get('displayName') or meta.get('name')
        if not disp:
            continue
        for variant in (key, chan_id, clean_channel_name(chan_id), clean_channel_name(disp)):
            if variant:
                display.setdefault(variant, disp)

    _epg_channel_display = display
    _epg_index = {'by_start': by_start, 'by_title': by_title}
    return data, _epg_index

async def load_json(path, timeout_sec=5):
    """Load JSON from file asynchronously"""
    try:
        async with aiofiles.open(path, 'r', encoding='utf-8') as f:
            content = await f.read()
            result = json.loads(content)
        return result
    except FileNotFoundError:
        logger.debug(f"File not found: {path}")
        return None
    except json.JSONDecodeError as e:
        logger.warning(f"Invalid JSON in {path}", str(e))
        return None
    except Exception as e:
        logger.error(f"Failed to load {path}", str(e))
        return None

def _host_from_url(url: str):
    try:
        return urllib.parse.urlparse(url).hostname
    except Exception:
        return None

async def _probe_https_once(url_http: str) -> bool:
    global _cache_stats
    if not url_http.startswith('http://'):
        return False
    https_url = 'https://' + url_http[len('http://'):]
    host = _host_from_url(https_url)
    if not host or host in SAFE_HTTP_HOSTS:
        return False
    if host in _https_support:
        return _https_support[host]

    _cache_stats['https_probes'] += 1
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            if PROBE_METHOD == 'GET':
                r = await client.get(https_url, follow_redirects=True)
            else:
                r = await client.head(https_url, follow_redirects=True)
            ok = 200 <= r.status_code < 400
    except Exception:
        ok = False
    _https_support[host] = ok  # BoundedDict will handle eviction
    return ok

async def _preflight_scan():
    try:
        for path in (SCHEDULES, EPG_CACHE):
            data = await load_json(path)
            if not data: continue
            async def walk(o, seen=0, limit=2000):
                if seen >= limit: return seen
                if isinstance(o, dict):
                    for _, v in o.items():
                        seen = await walk(v, seen, limit)
                        if seen >= limit: break
                elif isinstance(o, list):
                    for v in o:
                        seen = await walk(v, seen, limit)
                        if seen >= limit: break
                elif isinstance(o, str):
                    if o.startswith('http://'):
                        await _probe_https_once(o)
                        seen += 1
                return seen
            await walk(data, 0, 2000)
    except Exception:
        pass

def _api_headers():
    h = {'Accept': 'application/json'}
    if SNAPPY_API_KEY:
        h['Authorization'] = f'Bearer {SNAPPY_API_KEY}'
    return h

async def api_search(title=None, channel=None, limit=10):
    if not SNAPPY_API_ENABLED:
        return None, {}
    try:
        params = {}
        if title:   params['title'] = title
        if channel: params['channel'] = channel
        if limit:   params['limit'] = str(limit)
        url = f"{SNAPPY_API_BASE}/epg/search"
        async with httpx.AsyncClient(timeout=SNAPPY_API_TIMEOUT) as client:
            r = await client.get(url, params=params, headers=_api_headers())
            if not r.is_success:
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

def _pick_best_from_list(lst, want_title=None, want_start=None):
    want = (want_title or '').strip().lower()
    want_start_key = _normalize_start(want_start)
    best = None
    best_score = -1

    for ev in lst:
        cev = _coerce_event(ev)
        if not cev:
            continue

        score = 0
        ev_title = (cev.get('title') or '').strip().lower()
        if want:
            if ev_title == want:
                score += 10
            elif want in ev_title:
                score += 4

        if want_start_key is not None:
            ev_start_key = _normalize_start(cev.get('start'))
            if ev_start_key is not None:
                diff = abs(ev_start_key - want_start_key)
                if diff <= 60:
                    score += 8
                elif diff <= 300:
                    score += 5
                elif diff <= 900:
                    score += 3

        if score == 0 and best is not None:
            continue

        if score > best_score:
            best_score = score
            best = cev

    if best is None and lst:
        for ev in lst:
            cev = _coerce_event(ev)
            if cev:
                return cev
    return best

async def api_find_program(channel=None, title=None, start=None):
    hits, meta = (None, {})
    if title and channel:
        hits, meta = await api_search(title=title, channel=channel, limit=10)
        if hits: return _pick_best_from_list(hits, title, start), meta
    if title:
        hits, meta = await api_search(title=title, limit=10)
        if hits: return _pick_best_from_list(hits, title, start), meta
    if channel:
        hits, meta = await api_search(channel=channel, limit=10)
        if hits: return _pick_best_from_list(hits, want_start=start), meta
    return None, meta

async def cache_find_program(channel=None, title=None, start_ts=None, prefer_past=False):
    data, index = await _ensure_epg_index()
    if not data:
        return None

    start_key = _normalize_start(start_ts)
    # Normalize title by removing punctuation for better matching
    title_key = (title or '').strip().lower()
    title_key_norm = re.sub(r'[^\w\s]', '', title_key).strip()  # Remove punctuation
    channel_clean = clean_channel_name(channel)

    candidates = []
    seen = set()

    # For catch-ups, prioritize title search over timestamp search
    # since catch-ups can be requested hours after the original airing
    if prefer_past and title_key_norm:
        # Search all programs and match with normalized title comparison
        # (can't rely on index since payload may not have punctuation like "gutfeld" vs "gutfeld!")
        for ev in data.get('programmes', []):
            ev_title = (ev.get('title') or '').strip().lower()
            ev_title_norm = re.sub(r'[^\w\s]', '', ev_title).strip()

            # Match if normalized titles are equal or very similar
            if ev_title_norm == title_key_norm or title_key_norm in ev_title_norm:
                marker = id(ev)
                if marker in seen:
                    continue
                candidates.append(ev)
                seen.add(marker)
                # Limit to 100 candidates for performance
                if len(candidates) >= 100:
                    break
    elif start_key is not None:
        # For live recordings, search by timestamp with narrow window
        for delta in (0, -60, 60, -120, 120):
            bucket = index['by_start'].get(start_key + delta)
            if not bucket:
                continue
            for ev in bucket:
                marker = id(ev)
                if marker in seen:
                    continue
                candidates.append(ev)
                seen.add(marker)

    if title_key and not prefer_past:
        # Search by exact lowercase title
        for ev in index['by_title'].get(title_key, []):
            marker = id(ev)
            if marker in seen:
                continue
            candidates.append(ev)
            seen.add(marker)

        # Also search by normalized title (without punctuation)
        if title_key_norm and title_key_norm != title_key:
            for ev in index['by_title'].get(title_key_norm, []):
                marker = id(ev)
                if marker in seen:
                    continue
                candidates.append(ev)
                seen.add(marker)

    if not candidates and title_key:
        for ev in data.get('programmes', []):
            ev_title = (ev.get('title') or '').strip().lower()
            ev_title_norm = re.sub(r'[^\w\s]', '', ev_title).strip()
            if ev_title == title_key or ev_title_norm == title_key_norm:
                candidates.append(ev)
                if len(candidates) >= 10:  # Limit fallback search
                    break

    if not candidates and channel_clean:
        for ev in data.get('programmes', []):
            ev_chan_clean = clean_channel_name(ev.get('channel'))
            if ev_chan_clean and ev_chan_clean.lower() == channel_clean.lower():
                candidates.append(ev)
                break

    best = None
    best_score = -1
    debug_scores = []
    for ev in candidates:
        score = 0
        score_breakdown = {}
        ev_title = (ev.get('title') or '').strip().lower()
        ev_title_norm = re.sub(r'[^\w\s]', '', ev_title).strip()  # Normalize for comparison
        if title_key and ev_title:
            # Compare normalized titles (without punctuation)
            if ev_title_norm == title_key_norm:
                score += 6
                score_breakdown['title_exact'] = 6
            elif title_key_norm in ev_title_norm or ev_title_norm in title_key_norm:
                score += 4
                score_breakdown['title_normalized_match'] = 4
            elif title_key in ev_title:
                score += 3
                score_breakdown['title_partial'] = 3

        if start_key is not None:
            ev_start_key = _normalize_start(ev.get('start'))
            if ev_start_key is not None:
                diff = abs(ev_start_key - start_key)
                time_offset = ev_start_key - start_key  # Positive = future, Negative = past

                if diff == 0:
                    score += 20  # Exact match is very strong signal
                    score_breakdown['time_exact'] = 20
                elif diff <= 60:
                    score += 10
                    score_breakdown['time_1min'] = 10
                elif diff <= 180:
                    score += 5
                    score_breakdown['time_3min'] = 5
                elif diff <= 600:
                    score += 2
                    score_breakdown['time_10min'] = 2

                # For catch-ups only: prefer entries that aired in the PAST
                # Catch-ups are always for content that already aired, not upcoming shows
                if prefer_past:
                    # Apply distance-based scoring: prefer airings closest to payload time
                    # This is important for daily shows (e.g., Gutfeld) to select right episode
                    if diff <= 86400:  # Within 24 hours is reasonable
                        # Closer to payload = higher score
                        # Linear decay: 24h diff = 3 points, 0h diff covered by exact/close matches above
                        hours_diff = diff / 3600
                        distance_bonus = max(0, 3 - (hours_diff / 8))  # Decreases from 3 to 0 over 24 hours
                        score += distance_bonus
                        score_breakdown['distance_bonus'] = round(distance_bonus, 1)

                    if time_offset < -3600:  # More than 1 hour in the past
                        # This aired well in the past, give bonus
                        score += 5
                        score_breakdown['past_bonus'] = 5
                    elif time_offset > 3600:  # More than 1 hour in the future
                        # This is upcoming/future content, heavily penalize for catch-ups
                        score -= 15
                        score_breakdown['future_penalty'] = -15

        if channel_clean:
            ev_chan_clean = clean_channel_name(ev.get('channel'))
            if ev_chan_clean:
                if ev_chan_clean.lower() == channel_clean.lower():
                    score += 4
                    score_breakdown['channel_exact'] = 4
                elif channel_clean.lower() in ev_chan_clean.lower():
                    score += 2
                    score_breakdown['channel_partial'] = 2

        # Prefer major US networks over specialty channels
        ev_channel = (ev.get('channel') or '').upper()
        if 'FOXNEWS' in ev_channel or 'FOX NEWS' in ev_channel:
            score += 5  # Strong preference for Fox News
            score_breakdown['network_foxnews'] = 5
        elif 'NBC' in ev_channel or 'CBS' in ev_channel or 'ABC' in ev_channel or 'FOX' in ev_channel:
            score += 3  # Preference for major broadcast networks
            score_breakdown['network_major'] = 3
        elif 'AMC' in ev_channel or 'TNT' in ev_channel or 'USA' in ev_channel or 'TBS' in ev_channel or 'BRAVO' in ev_channel or 'FX' in ev_channel or 'HULU' in ev_channel:
            score += 4  # Preference for major cable networks
            score_breakdown['network_cable'] = 4
        elif 'AFN' in ev_channel or 'MILITARY' in ev_channel:
            score -= 10  # Strongly deprioritize military/specialty channels
            score_breakdown['network_afn_penalty'] = -10

        priority = ev.get('priority')
        if isinstance(priority, int):
            bonus = max(0, min(priority, 3))
            score += bonus
            score_breakdown['priority'] = bonus

        debug_scores.append({
            'channel': ev.get('channel'),
            'title': ev.get('title'),
            'score': score,
            'breakdown': score_breakdown
        })

        # Update best if score is higher, OR if score is tied but this entry aired earlier
        # (for catch-ups, earlier airings are more likely to be originals vs reruns)
        should_update = False
        if score > best_score:
            should_update = True
        elif score == best_score and best is not None and prefer_past:
            # Tie-breaker: prefer earlier airing for catch-ups
            ev_start_key = _normalize_start(ev.get('start'))
            best_start_key = _normalize_start(best.get('start'))
            if ev_start_key is not None and best_start_key is not None:
                if ev_start_key < best_start_key:  # Earlier = smaller timestamp
                    should_update = True
                    score_breakdown['earlier_tiebreaker'] = 'preferred'

        if should_update:
            best_score = score
            best = ev
            if score >= 12:
                break

    # Log top 3 candidates for debugging
    if debug_scores:
        sorted_scores = sorted(debug_scores, key=lambda x: x['score'], reverse=True)[:3]
        logger.debug(f"Top 3 EPG matches for '{title_key}'")
        for i, entry in enumerate(sorted_scores):
            breakdown_str = ", ".join([f"{k}={v}" for k, v in entry['breakdown'].items()])
            logger.debug(f"  Match {i+1}: {entry['channel']} - {entry['title']}", f"score={entry['score']} [{breakdown_str}]")

    if not best:
        if candidates:
            best = candidates[0]
        else:
            return None

    meta = dict(best)
    chan_key = meta.get('channel')
    display = None
    if chan_key:
        display = _epg_channel_display.get(chan_key)
        if not display:
            display = _epg_channel_display.get(clean_channel_name(chan_key))
    if display:
        meta.setdefault('channelName', display)
    if chan_key:
        meta.setdefault('channelClean', clean_channel_name(chan_key))
    return meta

async def pushover_send(title, message, url=None, url_title=None, priority=0, attachment_path=None):
    if not (PO_USER and PO_TOKEN):
        logger.error("Pushover not configured", f"PO_USER={'*' * 8 if PO_USER else 'missing'} PO_TOKEN={'*' * 8 if PO_TOKEN else 'missing'}")
        return {'ok': False, 'error':'Pushover not configured'}

    data = {'token': PO_TOKEN,'user': PO_USER,'title': title,'message': message,'priority': priority}
    if url: data['url'] = url
    if url_title: data['url_title'] = url_title

    # Retry logic with exponential backoff
    max_retries = int(os.environ.get('NOTIFY_RETRY_ATTEMPTS', '3'))
    retry_delay = float(os.environ.get('NOTIFY_RETRY_DELAY', '2'))

    for attempt in range(max_retries):
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                # Handle attachment - read into memory to avoid file handle leak
                if attachment_path and os.path.isfile(attachment_path):
                    try:
                        # Read file into memory asynchronously
                        async with aiofiles.open(attachment_path, 'rb') as fh:
                            file_data = await fh.read()
                        # File handle is now closed, safe to pass data to httpx
                        files = {'attachment': (os.path.basename(attachment_path), file_data, 'image/gif')}
                        r = await client.post('https://api.pushover.net/1/messages.json', data=data, files=files)
                    except (OSError, IOError) as e:
                        # Log the error and fall back to message without attachment
                        logger.warning(f"Failed to read attachment {attachment_path}", str(e))
                        r = await client.post('https://api.pushover.net/1/messages.json', data=data)
                else:
                    # No attachment
                    r = await client.post('https://api.pushover.net/1/messages.json', data=data)

                # Check if request was successful
                if r.status_code == 200:
                    try:
                        result = r.json()
                        if result.get('status') == 1 or result.get('ok'):
                            logger.debug(f"Pushover sent successfully (attempt {attempt + 1})")
                            return result
                    except Exception:
                        pass

                # If we got here, request failed
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)  # Exponential backoff: 2s, 4s, 8s
                    logger.warning(f"Pushover request failed", f"status={r.status_code}, retry in {wait_time}s (attempt {attempt + 1}/{max_retries})")
                    await asyncio.sleep(wait_time)
                else:
                    logger.error(f"Pushover request failed after {max_retries} attempts", f"status={r.status_code}")
                    return r.json() if r.status_code == 200 else {'ok': r.is_success, 'status': r.status_code}

        except httpx.TimeoutException:
            if attempt < max_retries - 1:
                wait_time = retry_delay * (2 ** attempt)
                logger.warning(f"Pushover request timeout", f"retry in {wait_time}s (attempt {attempt + 1}/{max_retries})")
                await asyncio.sleep(wait_time)
            else:
                logger.error(f"Pushover request timeout after {max_retries} attempts")
                return {'ok': False, 'error': 'timeout'}
        except httpx.RequestError as e:
            if attempt < max_retries - 1:
                wait_time = retry_delay * (2 ** attempt)
                logger.warning(f"Pushover request error", f"{type(e).__name__}, retry in {wait_time}s (attempt {attempt + 1}/{max_retries})")
                await asyncio.sleep(wait_time)
            else:
                logger.error(f"Pushover request error after {max_retries} attempts", str(e))
                return {'ok': False, 'error': str(e)}

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

@app.post('/notify')
async def notify(request: Request):
    payload = None
    try:
        # Read body once - it can't be re-read in FastAPI
        body = await request.body()
        if body:
            body_str = body.decode('utf-8', errors='replace')
            try:
                payload = json.loads(body_str)
            except json.JSONDecodeError:
                # If JSON parsing fails, treat as raw text
                payload = {'text': body_str}
        else:
            payload = {}
    except Exception as e:
        logger.error("Failed to parse request body", str(e))
        payload = {'text': ''}

    # Preserve empty strings instead of converting to None via 'or' operator
    # This is important for catchups where channel may legitimately be empty
    channel_hint = payload.get('channel') if payload and 'channel' in payload else payload.get('ch') if payload else None
    channel_clean = clean_channel_name(channel_hint)
    if not channel_clean:
        channel_clean = None
    title   = (payload or {}).get('title')   or (payload or {}).get('program')
    start   = (payload or {}).get('start')   or (payload or {}).get('ts')
    start_local = (payload or {}).get('start_local') or (payload or {}).get('start_local_formatted')
    end     = (payload or {}).get('end')     or (payload or {}).get('end_time')
    end_local = (payload or {}).get('end_local') or (payload or {}).get('end_local_formatted')

    # Extract action early so we can use it for EPG lookup logic
    action = (payload or {}).get('action', '').strip().lower()

    # Validate that action is present and non-empty
    if not action:
        error_msg = "Missing or empty 'action' field in webhook payload"
        logger.error(error_msg, f"payload={json.dumps(payload, default=str)[:300]}")
        return JSONResponse({"ok": False, "error": error_msg}, status_code=400)

    # Extract job_id and file for deduplication check
    job_id_full = (payload or {}).get("job_id_full") or (payload or {}).get("job_id") or ""
    file_path = (payload or {}).get("file") or ""

    # Check for duplicate notifications within TTL window
    is_duplicate, elapsed = _check_and_record_notification(action, job_id_full, file_path)
    if is_duplicate:
        logger.warning(
            f"Duplicate notification suppressed",
            f"action={action}, job={job_id_full[:8] if job_id_full else 'unknown'}..., elapsed={elapsed:.1f}s"
        )
        return JSONResponse({
            "ok": True,
            "deduplicated": True,
            "elapsed_since_last": f"{elapsed:.1f}s",
            "action": action
        })

    meta = None
    used_api = False

    # Determine if this is a catch-up (will need prefer_past=True)
    is_catchup = action.startswith('catchup_') if action else False

    # Normalize title for catch-ups: replace " s " with "'s " (e.g., "Freddy s Revenge" -> "Freddy's Revenge")
    # This fixes titles parsed from filenames where underscores replaced apostrophes
    if is_catchup and title:
        title = re.sub(r' s\b', "'s", title, flags=re.IGNORECASE)

    # Debug logging for catchups with empty channel
    if is_catchup and not channel_hint:
        logger.debug("Catchup event with empty channel", f"action={action}, title={title}, start={start}")

    # Prefer cache lookup when we have a start time but no channel (e.g., catchups)
    # For catchups: search by title primarily, but use the start time to disambiguate multiple airings
    # For recordings: use the timestamp to find the exact program
    if start and not channel_hint and not channel_clean:
        if is_catchup:
            # For catch-ups: search by title, but pass start time to prefer the right airing
            # (there may be multiple airings/reruns of the same program)
            meta = await cache_find_program(None, title, start, prefer_past=True)
            logger.debug(f"Catchup EPG lookup by title with timestamp preference", f"title={title}, start={start}")
        else:
            meta = await cache_find_program(None, title, start, prefer_past=is_catchup)
    elif SNAPPY_API_ENABLED and (title or channel_hint or channel_clean):
        meta, _ = await api_find_program(channel=channel_hint, title=title, start=start)
        used_api = bool(meta)
        if not meta and channel_clean and channel_clean != channel_hint:
            alt_meta, _ = await api_find_program(channel=channel_clean, title=title, start=start)
            if alt_meta:
                meta = alt_meta
            used_api = used_api or bool(alt_meta)
    if not meta:
        # For fallback search: use timestamp for both catch-ups and recordings to find the right airing
        meta = await cache_find_program(channel_hint or channel_clean, title, start, prefer_past=is_catchup)

    # Debug: log EPG metadata found for catch-ups
    if is_catchup and meta:
        logger.debug(f"Catchup EPG metadata retrieved", f"channel={meta.get('channel')}, channelName={meta.get('channelName')}, title={meta.get('title')}, start={meta.get('start')}")

    # For catch-ups, prefer EPG start time over payload start time (payload may be download time, not air time)
    if action.startswith('catchup_') and meta and meta.get('start'):
        epg_start = meta.get('start')
        if epg_start and epg_start != start:
            logger.info("Overriding catch-up start time", f"{start} -> {epg_start}")
            start = epg_start
            # Recalculate local time from EPG timestamp
            start_dt = _parse_timestamp(epg_start)
            if start_dt:
                try:
                    from datetime import timezone
                    try:
                        from zoneinfo import ZoneInfo
                    except ImportError:
                        ZoneInfo = None

                    tz_name = os.environ.get('TZ')
                    if tz_name and ZoneInfo is not None:
                        try:
                            local_dt = start_dt.astimezone(ZoneInfo(tz_name))
                        except Exception:
                            local_dt = start_dt.astimezone()
                    else:
                        local_dt = start_dt.astimezone()

                    start_local = local_dt.strftime("%Y-%m-%d %I:%M %p %Z")
                    logger.debug("Recalculated start_local", start_local)
                except Exception as e:
                    logger.warning("Failed to recalculate start_local", str(e))

    # Use normalized title if available (important for catch-ups where apostrophes were replaced with spaces)
    program_name = title or (meta or {}).get("title") or "Unknown"
    job_id       = (payload or {}).get("job_id") or (payload or {}).get("job_id_full") or "Unknown"
    channel_name = _pick_channel_name(
        (payload or {}).get("channel"),
        (payload or {}).get("ch"),
        (payload or {}).get("channel_name"),
        (payload or {}).get("channelClean"),
        (meta or {}).get("channelName"),
        (meta or {}).get("displayName"),
        (meta or {}).get("channel"),
        channel_hint,
        channel_clean,
    ) or "Unknown"

    # Debug: log channel selection for catch-ups
    if is_catchup:
        logger.debug(f"Catchup channel selection", f"selected={channel_name}, payload_channel={payload.get('channel') if payload else None}, meta_channel={meta.get('channel') if meta else None}, meta_displayName={meta.get('displayName') if meta else None}")

    kind = (payload or {}).get("type") or (meta or {}).get("type")
    year = (payload or {}).get("year") or (meta or {}).get("year")
    desc_raw = (payload or {}).get("desc") or (meta or {}).get("desc") or (meta or {}).get("description")
    desc_body = desc_raw

    # Debug: log what we got from EPG
    if is_catchup and meta:
        logger.debug("Catchup EPG metadata returned", f"keys={list(meta.keys())}, desc={desc_raw is not None}")

    # TMDB enrichment for movie actions
    tmdb_meta = None
    if TMDB_AVAILABLE and action.startswith("movie_"):
        try:
            tmdb_meta = enrich_movie_metadata(program_name, (payload or {}).get("file"))
            if tmdb_meta:
                # Enrich with TMDB data - prioritize TMDB descriptions for movies
                if tmdb_meta.get('overview'):
                    desc_raw = tmdb_meta['overview']
                if not year and tmdb_meta.get('release_date'):
                    year = tmdb_meta['release_date'][:4]  # Extract year from YYYY-MM-DD
                if not kind:
                    genres = tmdb_meta.get('genres', [])
                    kind = ', '.join(genres[:3]) if genres else None  # First 3 genres
                # Store additional TMDB info for later use
                payload['tmdb_rating'] = tmdb_meta.get('vote_average')
                payload['tmdb_votes'] = tmdb_meta.get('vote_count')
                payload['tmdb_id'] = tmdb_meta.get('tmdb_id')
        except Exception as e:
            logger.warning("TMDB enrichment failed", str(e))

    # TMDB enrichment for series actions
    if TMDB_AVAILABLE and action.startswith("series_"):
        try:
            tmdb_meta = enrich_series_metadata(program_name)
            if tmdb_meta:
                # Enrich with TMDB data - prioritize TMDB descriptions for TV series
                if tmdb_meta.get('overview'):
                    desc_raw = tmdb_meta['overview']
                if not year and tmdb_meta.get('first_air_date'):
                    year = tmdb_meta['first_air_date'][:4]  # Extract year from YYYY-MM-DD
                if not kind:
                    genres = tmdb_meta.get('genres', [])
                    kind = ', '.join(genres[:3]) if genres else None  # First 3 genres
                # Store additional TMDB info for later use
                payload['tmdb_rating'] = tmdb_meta.get('vote_average')
                payload['tmdb_votes'] = tmdb_meta.get('vote_count')
                payload['tmdb_id'] = tmdb_meta.get('tmdb_id')
        except Exception as e:
            logger.warning("TMDB series enrichment failed", str(e))

    # If enrichment filled in a description after we captured desc_body,
    # make sure the body mirrors the latest value so notifications include it.
    desc_body = desc_raw

    duration_min = (payload or {}).get("duration_min")

    # Calculate duration from start/end timestamps if not provided (common for catch-ups)
    if not duration_min and start and end:
        try:
            start_dt = _parse_timestamp(start)
            end_dt = _parse_timestamp(end)
            if start_dt and end_dt:
                duration_sec = (end_dt - start_dt).total_seconds()
                if duration_sec > 0:
                    duration_min = int(duration_sec / 60)
        except Exception:
            pass  # If calculation fails, leave duration_min as None

    filepath     = (payload or {}).get("file")
    error_msg    = (payload or {}).get("error")
    exit_code    = _as_int((payload or {}).get("exit_code"))
    exit_reason  = (payload or {}).get("exit_reason")
    scheduled_at = (payload or {}).get("scheduled_at")

    # suppress noise for *_exit with code==0
    if action.endswith("_exit"):
        if exit_code is None or exit_code == 0:
            return JSONResponse({"ok": True, "suppressed": True, "reason": "exit_code==0", "action": action})

    DESC_LIMIT = int(os.environ.get("NOTIFY_DESC_LIMIT", "900"))

    # Special handling for health warnings - keep them simple
    if action == "health_warn":
        lines = []
        if desc_raw:
            lines.append(desc_raw)
        if error_msg:
            lines.append(f"⚠️ {error_msg}")
        if exit_reason:
            lines.append(f"🧰 {exit_reason}")
        body = "\n".join(lines).strip() or "Server health check failed"
    else:
        lines = []
        lines.append(f"📺 {program_name}")

        # Add episode info for series (VOD) or extract from EPG description for scheduled/live recordings
        episode = (payload or {}).get("episode")
        if action.startswith("series_") and episode:
            lines.append(f"📋 Episode: {episode}")
        elif action in ("recording_scheduled", "recording_started", "recording_live_started") and desc_raw:
            # Split description into first line (episode header) and remainder
            if '\n' in desc_raw:
                first_line, remainder = desc_raw.split('\n', 1)
            else:
                first_line, remainder = desc_raw, ""

            match = re.match(r'^(S\d+E\d+)\s*(?:[-:]\s*)?(.*)$', first_line.strip())
            if match:
                episode_num = match.group(1).strip()
                episode_title = match.group(2).strip()
                if episode_title:
                    lines.append(f"📋 Episode: {episode_num} - {episode_title}")
                else:
                    lines.append(f"📋 Episode: {episode_num}")
                desc_body = remainder.strip()

        desc = safe_trim(desc_body, DESC_LIMIT)

        lines.append(f"🆔 Job ID: {job_id}")
        # Don't show channel for VOD items (movies, series) or when channel is Unknown
        if not (action.startswith("movie_") or action.startswith("series_")) and channel_name != "Unknown":
            lines.append(f"📡 Channel: {channel_name}")

        # Show timing info for recording-related actions
        if action in ("recording_scheduled", "recording_started", "recording_live_started"):
            if action == "recording_scheduled" and scheduled_at:
                lines.append(f"🗓️ Starts: {scheduled_at}")
            elif action in ("recording_started", "recording_live_started"):
                # For started recordings, show when it began
                if start_local:
                    lines.append(f"🕘 Started: {start_local}")
                elif scheduled_at:
                    lines.append(f"🕘 Started: {scheduled_at}")

            # Show end time if available
            if end_local:
                lines.append(f"🏁 Ends: {end_local}")

            # Calculate and display duration if both start and end times are available
            if start and end:
                try:
                    start_dt = _parse_timestamp(start)
                    end_dt = _parse_timestamp(end)
                    if start_dt and end_dt:
                        duration_sec = (end_dt - start_dt).total_seconds()
                        if duration_sec > 0:
                            duration_min = int(duration_sec / 60)
                            hours = duration_min // 60
                            minutes = duration_min % 60
                            if hours > 0:
                                lines.append(f"⏱️ Duration: {hours}h {minutes}m")
                            else:
                                lines.append(f"⏱️ Duration: {minutes}m")
                except Exception:
                    pass
        # Only show "Aired" for catchup and TV series (past content with original air dates)
        if action.startswith("catchup_") or action.startswith("series_"):
            aired_label = start_local or None
            if not aired_label:
                start_candidate = start
                if start_candidate:
                    aired_label = start_candidate
            if aired_label:
                lines.append(f"🕘 Aired: {aired_label}")

        header_bits = []
        if kind: header_bits.append(kind)
        if year: header_bits.append(f"({year})")
        lines.append("\n📝 " + " ".join(header_bits) if header_bits else "\n📝")

        if desc:
            lines.append(desc)

        # Add TMDB rating for movies and TV series
        if (action.startswith("movie_") or action.startswith("series_")) and tmdb_meta:
            rating = tmdb_meta.get('vote_average')
            votes = tmdb_meta.get('vote_count')
            if rating:
                rating_str = f"⭐ TMDB: {rating:.1f}/10"
                if votes:
                    rating_str += f" ({votes:,} votes)"
                lines.append(f"\n{rating_str}")

        tail = []
        if action in ("recording_completed", "catchup_completed", "movie_completed", "series_completed"):
            if duration_min: tail.append(f"⏱️ {duration_min} min")
            if filepath:     tail.append(f"📁 {filepath}")

        if action.endswith("_failed") or action in ("server_error", "server_failed"):
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

    attachment_path = None

    res = await pushover_send(
        title=f"{push_title}",
        message=body,
        url=None,
        url_title=None,
        priority=priority,
        attachment_path=attachment_path
    )

    # Defensive fallback: ensure action is always valid in response
    # This should never happen due to validation above, but guards against edge cases
    response_action = action if action else "unknown"

    return JSONResponse({
        "ok": True,
        "pushover": res,
        "enriched": bool(meta),
        "used_api": used_api,
        "action": response_action
    })

@app.get('/https-capabilities')
async def https_caps():
    return JSONResponse({'hosts': _https_support})

@app.get('/health')
async def health():
    return JSONResponse({
        'ok': True,
        'ts': time.time(),
        'api_enabled': SNAPPY_API_ENABLED,
        'cache_stats': {
            'epg_hits': _cache_stats['epg_hits'],
            'epg_misses': _cache_stats['epg_misses'],
            'https_cache_size': len(_https_support),
            'https_cache_max': HTTPS_CACHE_MAX_SIZE,
            'https_probes_total': _cache_stats['https_probes'],
            'memory_warnings': _cache_stats['memory_warnings'],
            'epg_index_max': EPG_INDEX_MAX_SIZE
        }
    })

def validate_pushover_config():
    """Validate Pushover credentials are set and working"""
    if not PO_USER:
        logger.error("PUSHOVER_USER_KEY not set", "Notifications will fail")
        return False
    if not PO_TOKEN:
        logger.error("PUSHOVER_APP_TOKEN not set", "Notifications will fail")
        return False

    logger.info("Pushover credentials configured", f"user={PO_USER[:4]}...{PO_USER[-4:] if len(PO_USER) > 8 else ''}")
    return True

@app.on_event("startup")
async def startup_event():
    """Run initialization tasks on application startup"""
    # Validate configuration on startup
    validate_pushover_config()

    # Run preflight scan asynchronously
    await _preflight_scan()
    logger.debug("Preflight HTTPS scan completed")

    # Log API configuration
    if SNAPPY_API_ENABLED:
        logger.info("Snappy API enabled", f"base={SNAPPY_API_BASE}, timeout={SNAPPY_API_TIMEOUT}s")
    else:
        logger.info("Snappy API disabled")

    # Show final startup message
    logger.info("Application startup complete.")

if __name__ == '__main__':
    import uvicorn
    host = os.environ.get('NOTIFICATION_HTTP_BIND', '0.0.0.0')
    port = int(os.environ.get('NOTIFICATION_HTTP_PORT', '9080'))

    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level="info"
    )
