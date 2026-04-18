#!/usr/bin/env python3
"""
metadata_fixer.py — Fix catch-up .meta.json files.

1. Fix bare time strings: snappier-server sometimes writes bare 12-hour time strings
   like "11:00 PM" instead of full timestamps like "20260223040000 +0000".
2. Enrich missing channel_name and logo: catch-up downloads have no channel in the
   filename, so snappier-server writes empty channel_name and logo. This script looks
   up the programme title in the EPG cache to fill them in.
"""

import glob
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

METADATA_DIR = os.environ.get(
    "METADATA_DIR",
    "/root/SnappierServer/Recordings/metaData",
)
# Directories where actual recording files live
RECORDING_DIRS = [
    os.environ.get("RECORDINGS_DIR", "/root/SnappierServer/Recordings"),
    os.environ.get("MOVIES_DIR", "/root/SnappierServer/Movies"),
    os.environ.get("SERIES_DIR", "/root/SnappierServer/TVSeries"),
]
EPG_CACHE_PATH = os.environ.get(
    "EPG_CACHE",
    "/root/SnappierServer/epg/epg_cache.json",
)
SCAN_INTERVAL = int(os.environ.get("METADATA_FIX_INTERVAL", "60"))

# Matches bare 12-hour time like "11:00 PM", "1:30 AM"
BARE_TIME_RE = re.compile(r"^\d{1,2}:\d{2}\s*[AP]M$", re.IGNORECASE)

# Extract datetime from catch-up filename
# e.g. --Bar_Rescue--20260223T012427-0500----928027ca-...ts.meta.json
FILENAME_DATE_RE = re.compile(
    r"--(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})([+-]\d{4})----"
)


def parse_bare_time(bare):
    """Parse '11:00 PM' -> (hour, minute) in 24-hour clock."""
    for fmt in ("%I:%M %p", "%I:%M%p"):
        try:
            t = datetime.strptime(bare.strip(), fmt)
            return t.hour, t.minute
        except ValueError:
            continue
    return None


def parse_filename_datetime(filename):
    """Extract download datetime (with tz offset) from the filename."""
    m = FILENAME_DATE_RE.search(filename)
    if not m:
        return None
    year, mon, day, hour, minute, sec, tz_str = m.groups()
    tz_sign = 1 if tz_str[0] == "+" else -1
    tz_hours = int(tz_str[1:3])
    tz_mins = int(tz_str[3:5])
    tz_offset = timezone(
        timedelta(hours=tz_sign * tz_hours, minutes=tz_sign * tz_mins)
    )
    return datetime(
        int(year), int(mon), int(day),
        int(hour), int(minute), int(sec),
        tzinfo=tz_offset,
    )


def format_utc(dt):
    """Format datetime as 'YYYYMMDDHHMMSS +0000' in UTC."""
    utc = dt.astimezone(timezone.utc)
    return utc.strftime("%Y%m%d%H%M%S") + " +0000"


# ── EPG cache for channel enrichment ──────────────────────────────────────
_epg_channels = {}
_epg_by_title = {}  # normalized_title -> [programme, ...]
_epg_mtime = 0.0


_epg_by_channel = {}

def _load_epg_cache():
    """Load (or reload) EPG cache JSON, building title and channel indexes for fast lookup."""
    global _epg_channels, _epg_by_title, _epg_by_channel, _epg_mtime
    try:
        mt = os.path.getmtime(EPG_CACHE_PATH)
    except OSError:
        return {}, {}, {}
    if _epg_by_title and mt == _epg_mtime:
        return _epg_channels, _epg_by_title, _epg_by_channel
    try:
        with open(EPG_CACHE_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
        _epg_channels = raw.get("channels") or {}
        programmes = raw.get("programmes") or []
        _epg_by_title = {}
        _epg_by_channel = {}
        for prog in programmes:
            t = _normalize_title(prog.get("title"))
            if t:
                _epg_by_title.setdefault(t, []).append(prog)
            chan = (prog.get("channel") or "").lower()
            if chan:
                _epg_by_channel.setdefault(chan, []).append(prog)
        _epg_mtime = mt
        print(f"[metadata_fixer] Loaded EPG cache ({len(_epg_channels)} channels, {len(programmes)} programmes, {len(_epg_by_title)} unique titles, {len(_epg_by_channel)} channel IDs)")
        sys.stdout.flush()
    except Exception as e:
        print(f"[metadata_fixer] WARN: cannot load EPG cache: {e}")
        sys.stdout.flush()
        return {}, {}, {}
    return _epg_channels, _epg_by_title, _epg_by_channel


def _normalize_title(title):
    """Lowercase, strip unicode superscripts/tags, collapse whitespace."""
    if not title:
        return ""
    # Handle dict-style titles from EPG: {"_": "Title Text", "lang": "en"}
    if isinstance(title, dict):
        title = title.get("_") or title.get("text") or ""
        if not title:
            return ""
    if not isinstance(title, str):
        return ""
    # Remove common unicode superscript/modifier markers (e.g. ᴸᶦᵛᵉ, ᴺᵉʷ)
    # Covers: Spacing Modifier Letters (ʷ U+02B0-02FF), Phonetic Extensions (U+1D2C-1DFF),
    # Superscripts/Subscripts (U+2070-209F)
    t = re.sub(r'[\u02b0-\u02ff\u1d2c-\u1dff\u2070-\u209f]+', '', title)
    t = re.sub(r'[^\w\s]', '', t)
    return re.sub(r'\s+', ' ', t).strip().lower()


def _is_catchup_filename(filename):
    """Return True if the metadata filename is for a catch-up download (starts with --)."""
    # Strip the .meta.json suffix to get the recording filename
    base = filename.replace(".meta.json", "")
    return base.startswith("--")


FFMPEG_WRAPPER_LOG = os.environ.get("FFMPEG_WRAPPER_LOG", "/root/SnappierServer/logs/ffmpeg_wrapper.log")

# Import the shared Xtream cache for stream_id → epg_channel_id resolution
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import xtream_cache
except ImportError:
    xtream_cache = None


def _extract_timeshift_info(filename):
    """Extract air time, provider domain, and stream ID from ffmpeg wrapper log.
    Returns (airtime_str, provider_domain, stream_id) or (None, None, None)."""
    uuid_match = re.search(r'----([0-9a-f-]{36})', filename)
    if not uuid_match:
        return None, None, None
    uuid = uuid_match.group(1)
    try:
        # Search from end of file — UUID will be in recent lines
        # Use tail to limit search to last 5000 lines for performance
        import subprocess
        result = subprocess.run(
            f"tail -5000 '{FFMPEG_WRAPPER_LOG}' | grep -m1 '{uuid}'",
            shell=True, capture_output=True, text=True, timeout=5
        )
        for line in (result.stdout.splitlines() if result.stdout.strip() else []):
                if xtream_cache:
                    domain, stream_id, airtime = xtream_cache.parse_timeshift_url(line)
                    if airtime or (domain and stream_id):
                        return airtime, domain, stream_id
                    # Try live URL if timeshift didn't match
                    domain, stream_id = xtream_cache.parse_live_url(line)
                    if domain and stream_id:
                        return None, domain, stream_id
                else:
                    # Fallback parsing without xtream_cache module
                    airtime = None
                    domain = None
                    stream_id = None
                    m = re.search(r'/timeshift/[^/]+/[^/]+/\d+/(\d{4}-\d{2}-\d{2}:\d{2}-\d{2})/', line)
                    if m:
                        airtime = m.group(1)
                    d = re.search(r'https?://([^/:]+)(?::\d+)?/(timeshift|live)/', line)
                    if d:
                        domain = d.group(1)
                    s = re.search(r'/(\d+)\.ts', line)
                    if s:
                        stream_id = s.group(1)
                    if airtime or (domain and stream_id):
                        return airtime, domain, stream_id
    except OSError:
        pass
    return None, None, None


def _parse_airtime_digits(airtime_str):
    """Extract raw date-time digits from timeshift URL air time (YYYY-MM-DD:HH-MM).

    Returns 12-digit string like '202603252000' (YYYYMMDDHHmm) or None.

    The timeshift URL encodes air time in the PROVIDER's local timezone
    (e.g. Nebula uses EDT, Endurance uses UTC). The raw digits match the
    provider's own EPG start time digits regardless of timezone offset.
    """
    if not airtime_str:
        return None
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2}):(\d{2})-(\d{2})$', airtime_str)
    if not m:
        return None
    return f"{m.group(1)}{m.group(2)}{m.group(3)}{m.group(4)}{m.group(5)}"


def _epg_start_digits(raw_start):
    """Extract raw date-time digits (YYYYMMDDHHmm) from an EPG start string."""
    if not raw_start or not isinstance(raw_start, str):
        return None
    m = re.match(r'^(\d{12})', raw_start.strip())
    return m.group(1) if m else None


def _parse_epg_timestamp(raw):
    """Parse EPG timestamp string to epoch seconds. Handles formats:
    - '20260325200000 -0400'  (EPG format with offset)
    - '20260325200000 +0000'  (EPG format UTC)
    - '2026-03-25T21:55:46-04:00' (ISO 8601)
    - '20260325T215546-0400' (filename format)
    """
    if not raw or not isinstance(raw, str):
        return None
    raw = raw.strip()
    # EPG format: YYYYMMDDHHmmss +/-HHMM
    m = re.match(r'^(\d{14})\s*([+-]\d{4})$', raw)
    if m:
        try:
            dt = datetime.strptime(m.group(1), "%Y%m%d%H%M%S")
            off = m.group(2)
            sign = 1 if off[0] == '+' else -1
            delta = timedelta(hours=int(off[1:3]), minutes=int(off[3:5]))
            dt = dt.replace(tzinfo=timezone(sign * delta))
            return dt.timestamp()
        except (ValueError, OverflowError):
            return None
    # Filename format: YYYYMMDDTHHmmss-HHMM
    m = re.match(r'^(\d{8})T(\d{6})([+-]\d{4})$', raw)
    if m:
        try:
            dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
            off = m.group(3)
            sign = 1 if off[0] == '+' else -1
            delta = timedelta(hours=int(off[1:3]), minutes=int(off[3:5]))
            dt = dt.replace(tzinfo=timezone(sign * delta))
            return dt.timestamp()
        except (ValueError, OverflowError):
            return None
    # ISO 8601
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, TypeError):
        return None


def epg_lookup_channel(programme_name, download_ts="", airtime=None, epg_channel_id=None, meta_start=None, provider_source=None):
    """Look up channel_name, logo, and description from EPG cache by programme title.

    If *epg_channel_id* is provided (resolved from Xtream API via stream_id),
    filters to that exact channel. If *meta_start* is provided (the metadata's
    existing start_time), uses epoch matching first. If *airtime* is provided,
    falls back to digit matching. Last resort: most-recent-before-download.

    Returns (channel_name, logo_url, description) or (None, None, None) if not found.
    """
    channels, by_title, by_channel = _load_epg_cache()
    if not by_title:
        return None, None, None

    title_norm = _normalize_title(programme_name)
    if not title_norm:
        return None, None, None

    air_digits = _parse_airtime_digits(airtime) if airtime else None
    meta_epoch = _parse_epg_timestamp(meta_start) if meta_start else None
    dl_epoch = _parse_epg_timestamp(download_ts) if download_ts and not air_digits and not meta_epoch else None

    # Build candidate sets using indexes — O(1) lookups instead of scanning all programmes
    candidate_sets = []
    if epg_channel_id:
        chan_progs = by_channel.get(epg_channel_id.lower(), [])
        if chan_progs:
            # Try exact title match first
            channel_filtered = [c for c in chan_progs if _normalize_title(c.get("title")) == title_norm]
            if channel_filtered:
                candidate_sets.append(channel_filtered)
            elif air_digits is not None:
                # Fallback: channel + airtime without title filter.
                # When Xtream confirmed the channel and we have exact air time,
                # trust that over title matching (titles may have unicode decoration).
                candidate_sets.append(chan_progs)
    # Fallback: title index
    candidates = by_title.get(title_norm)
    if candidates:
        candidate_sets.append(candidates)

    if not candidate_sets:
        return None, None, None

    best = None
    best_start = None
    best_priority = 999

    for cands in candidate_sets:
        best = None
        best_start = None
        best_priority = 999

        # Phase 1: epoch matching from metadata's known-correct start_time.
        # This avoids timezone collisions when the merged EPG cache has entries
        # in mixed timezones (e.g. both +0000 and -0400 for the same channel).
        if meta_epoch is not None:
            for prog in cands:
                prog_priority = prog.get("priority", 999)
                if not isinstance(prog_priority, int):
                    prog_priority = 999
                prog_epoch = _parse_epg_timestamp(prog.get("start"))
                if prog_epoch is not None and abs(prog_epoch - meta_epoch) < 120:
                    if best is None or prog_priority < best_priority:
                        best = prog
                        best_start = prog_epoch
                        best_priority = prog_priority
                        if prog_priority <= 1:
                            break

        # Phase 2: raw digit comparison from timeshift URL airtime.
        # Prefer entries from the same EPG source as the provider to avoid
        # digit collisions between different-timezone sources.
        if best is None and air_digits is not None:
            source_match = None
            source_match_pri = 999
            any_match = None
            any_match_pri = 999
            for prog in cands:
                prog_digits = _epg_start_digits(prog.get("start"))
                if not prog_digits or prog_digits != air_digits:
                    continue
                prog_priority = prog.get("priority", 999)
                if not isinstance(prog_priority, int):
                    prog_priority = 999
                prog_source = prog.get("source", "")
                if provider_source and prog_source == provider_source:
                    if source_match is None or prog_priority < source_match_pri:
                        source_match = prog
                        source_match_pri = prog_priority
                if any_match is None or prog_priority < any_match_pri:
                    any_match = prog
                    any_match_pri = prog_priority
            best = source_match or any_match
            if best:
                best_start = _parse_epg_timestamp(best.get("start"))
                best_priority = best.get("priority", 999)

        # Phase 3: most recent start before download time (last resort)
        if best is None and dl_epoch is not None:
            for prog in cands:
                prog_priority = prog.get("priority", 999)
                if not isinstance(prog_priority, int):
                    prog_priority = 999
                prog_start = _parse_epg_timestamp(prog.get("start"))
                if prog_start is None:
                    continue
                if prog_start > dl_epoch:
                    continue
                if (best_start is None
                        or prog_start > best_start
                        or (prog_start == best_start and prog_priority < best_priority)):
                    best = prog
                    best_start = prog_start
                    best_priority = prog_priority

        if best:
            break  # found a match, don't try fallback set

    if not best:
        return None, None, None

    chan_key = best.get("channel") or ""
    ch_meta = channels.get(chan_key) or {}

    # Resolve display name
    display_name = ch_meta.get("displayName") or ch_meta.get("name") or ""
    # Handle displayName being an array (known bug with some EPG sources)
    if isinstance(display_name, list):
        display_name = display_name[0] if display_name else ""

    logo_url = ch_meta.get("icon") or ""
    raw_desc = best.get("desc") or ""
    if isinstance(raw_desc, dict):
        raw_desc = raw_desc.get("_") or raw_desc.get("text") or ""
    description = raw_desc if isinstance(raw_desc, str) else ""

    # Fallback: clean the channel key itself if no display name
    if not display_name and chan_key:
        display_name = re.sub(r'\.(us|ca|uk|au|mx|tv)$', '', chan_key, flags=re.IGNORECASE)
        display_name = display_name.replace('_', ' ').replace('.', ' ').strip()

    return display_name or None, logo_url or None, description or None


def _find_recording_file(uuid):
    """Find the actual recording file (mkv/ts/mp4) by UUID across all recording dirs."""
    for d in RECORDING_DIRS:
        if not os.path.isdir(d):
            continue
        for entry in os.listdir(d):
            if os.path.isdir(os.path.join(d, entry)):
                continue
            if uuid in entry:
                return os.path.join(d, entry)
    return None


def _is_file_in_use(filepath):
    """Return True if the recording is still being downloaded or remuxed.

    A .ts sibling means the download/remux pipeline is still in-flight
    (the .ts is deleted only after a successful remux).  If the file itself
    is a .ts, check its mtime — still being written if recent.
    """
    base, ext = os.path.splitext(filepath)
    if ext == ".mkv":
        # Remux is done (.ts deleted) — safe to rename
        ts_sibling = base + ".ts"
        return os.path.exists(ts_sibling)
    # For .ts files: still in use if recently modified
    try:
        mtime = os.path.getmtime(filepath)
        return (time.time() - mtime) < 90
    except OSError:
        return False


def _rename_with_channel(filepath, data, channel_name):
    """Rename catch-up recording + metadata files to include channel name.

    Before: --Program_Name--timestamp----uuid.ext
    After:  Channel_Name--Program_Name--timestamp----uuid.ext
    """
    filename = os.path.basename(filepath)

    # Only rename files that start with -- (catch-ups with no channel)
    if not _is_catchup_filename(filename):
        return filepath

    # Build channel prefix: spaces -> underscores for filename
    chan_fs = channel_name.replace(" ", "_")

    # Find and rename the actual recording file
    m = _UUID_RE.search(filename)
    if m:
        uuid = m.group(0)
        rec_path = _find_recording_file(uuid)
        if rec_path:
            rec_name = os.path.basename(rec_path)
            if _is_catchup_filename(rec_name):
                # Guard: don't rename if the file is still being written/remuxed
                if _is_file_in_use(rec_path):
                    print(f"[metadata_fixer] Skipping rename of {rec_name} — file still in use (mtime < 90s)")
                    sys.stdout.flush()
                    return filepath
                # rec_name starts with "--", so chan_fs + rec_name gives "Channel--Program--..."
                new_rec_name = chan_fs + rec_name
                new_rec_path = os.path.join(os.path.dirname(rec_path), new_rec_name)
                try:
                    os.rename(rec_path, new_rec_path)
                    print(f"[metadata_fixer] Renamed recording: {rec_name} -> {new_rec_name}")
                except OSError as e:
                    print(f"[metadata_fixer] WARN: failed to rename recording: {e}")

    # Rename the metadata file itself
    # filename: --Program--ts----uuid.ts.meta.json -> Channel--Program--ts----uuid.ts.meta.json
    new_meta_name = chan_fs + filename
    new_meta_path = os.path.join(os.path.dirname(filepath), new_meta_name)
    try:
        os.rename(filepath, new_meta_path)
        print(f"[metadata_fixer] Renamed metadata:  {filename} -> {new_meta_name}")
        filepath = new_meta_path
    except OSError as e:
        print(f"[metadata_fixer] WARN: failed to rename metadata: {e}")

    return filepath


def fix_file(filepath):
    """Fix catch-up metadata: enrich channel/logo from EPG, fix bare time strings."""
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[metadata_fixer] WARN: cannot read {os.path.basename(filepath)}: {e}")
        return False

    filename = os.path.basename(filepath)
    modified = False
    channel_enriched = None  # Track if we just added a channel name

    # ── EPG enrichment ─────────────────────────────────────────────────
    # For catch-ups (filename starts with --): enrich channel, logo, description
    # For all recordings: enrich description if missing
    is_catchup = _is_catchup_filename(filename)
    needs_channel = is_catchup and not data.get("channel_name", "").strip()
    needs_logo = is_catchup and not data.get("logo", "").strip()
    needs_desc = not data.get("description", "").strip()

    if needs_channel or needs_logo or needs_desc:
        prog_name = data.get("programme_name", "")
        # Extract download timestamp from filename (e.g. 20260325T215546-0400)
        ts_match = re.search(r'(\d{8}T\d{6}[+-]\d{4})', filename)
        download_ts = ts_match.group(1) if ts_match else data.get("start_time", "")
        # Extract air time, provider, and stream ID from ffmpeg wrapper log
        airtime, provider_domain, stream_id = _extract_timeshift_info(filename)
        # Resolve stream_id → epg_channel_id via Xtream API cache
        epg_channel_id = None
        provider_channel_name = None
        if xtream_cache and provider_domain and stream_id:
            epg_channel_id = xtream_cache.lookup(provider_domain, stream_id)
            # Get the provider-specific channel name (e.g. "Bravo East" from Nebula)
            # This is more accurate than EPG display names which are generic
            raw_name = xtream_cache.lookup_name(provider_domain, stream_id)
            # Strip common country/region prefixes (e.g. "US : Bravo East" → "Bravo East")
            if raw_name:
                provider_channel_name = re.sub(r'^[A-Z]{2,3}\s*:\s*', '', raw_name).strip() or raw_name
        if airtime or epg_channel_id:
            print(f"[metadata_fixer] Timeshift info: airtime={airtime}, provider={provider_domain}, stream_id={stream_id}, epg_channel={epg_channel_id}, provider_name={provider_channel_name}")
            sys.stdout.flush()
        # Pass metadata's existing start_time for epoch-based EPG matching
        # (more reliable than digit matching when EPG has mixed-timezone entries)
        meta_start = data.get("start_time", "")
        if not meta_start or BARE_TIME_RE.match(meta_start):
            meta_start = None
        # Get EPG source name for same-source preference in digit matching
        provider_source = xtream_cache.lookup_provider_name(provider_domain) if xtream_cache and provider_domain else None
        display_name, logo_url, epg_desc = epg_lookup_channel(prog_name, download_ts, airtime, epg_channel_id, meta_start=meta_start, provider_source=provider_source)
        # Prefer provider-specific channel name over EPG display name
        if provider_channel_name:
            display_name = provider_channel_name
        if needs_channel and display_name:
            data["channel_name"] = display_name
            modified = True
            channel_enriched = display_name
            print(
                f"[metadata_fixer] Enriched channel_name: '' -> "
                f"'{display_name}' in {filename}"
            )
        if needs_logo and logo_url:
            data["logo"] = logo_url
            modified = True
            print(
                f"[metadata_fixer] Enriched logo: '' -> "
                f"'{logo_url}' in {filename}"
            )
        if needs_desc and epg_desc:
            data["description"] = epg_desc
            modified = True
            print(
                f"[metadata_fixer] Enriched description in {filename}"
            )

    # ── Fix bare time strings ────────────────────────────────────────────
    start_raw = data.get("start_time", "")
    end_raw = data.get("end_time", "")

    start_is_bare = bool(BARE_TIME_RE.match(start_raw))
    end_is_bare = bool(BARE_TIME_RE.match(end_raw))

    if start_is_bare or end_is_bare:
        dl_dt = parse_filename_datetime(filename)
        if dl_dt is None:
            print(f"[metadata_fixer] WARN: cannot extract date from filename: {filename}")
        else:
            if start_is_bare:
                parsed = parse_bare_time(start_raw)
                if parsed:
                    hour, minute = parsed
                    show_dt = dl_dt.replace(hour=hour, minute=minute, second=0)
                    if show_dt > dl_dt:
                        show_dt -= timedelta(days=1)
                    data["start_time"] = format_utc(show_dt)
                    modified = True
                    print(
                        f"[metadata_fixer] Fixed start_time: '{start_raw}' -> "
                        f"'{data['start_time']}' in {filename}"
                    )

            if end_is_bare:
                parsed = parse_bare_time(end_raw)
                if parsed:
                    if (
                        end_raw.strip().lower() == start_raw.strip().lower()
                        and "start_time" in data
                    ):
                        try:
                            st = datetime.strptime(
                                data["start_time"], "%Y%m%d%H%M%S +0000"
                            ).replace(tzinfo=timezone.utc)
                            data["end_time"] = format_utc(st + timedelta(hours=1))
                        except ValueError:
                            hour, minute = parsed
                            show_dt = dl_dt.replace(hour=hour, minute=minute, second=0)
                            if show_dt > dl_dt:
                                show_dt -= timedelta(days=1)
                            data["end_time"] = format_utc(show_dt)
                    else:
                        hour, minute = parsed
                        show_dt = dl_dt.replace(hour=hour, minute=minute, second=0)
                        if show_dt > dl_dt:
                            show_dt -= timedelta(days=1)
                        data["end_time"] = format_utc(show_dt)
                    modified = True
                    print(
                        f"[metadata_fixer] Fixed end_time:   '{end_raw}' -> "
                        f"'{data['end_time']}' in {filename}"
                    )

    # ── Write back if anything changed ───────────────────────────────────
    if modified:
        tmp_path = filepath + ".tmp"
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.rename(tmp_path, filepath)
        except OSError as e:
            print(f"[metadata_fixer] ERROR: failed to write {filename}: {e}")
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            return False

    # ── Rename files to include channel in filename ──────────────────
    # Run on every scan: catches deferred renames (guard blocked earlier)
    # and cases where channel was enriched in a previous container run.
    channel_name = data.get("channel_name", "").strip()
    if is_catchup and channel_name:
        filepath = _rename_with_channel(filepath, data, channel_name)

    return modified


_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)


def _get_existing_uuids():
    """Collect UUIDs from all actual recording files across all recording dirs."""
    uuids = set()
    for d in RECORDING_DIRS:
        if not os.path.isdir(d):
            continue
        for entry in os.listdir(d):
            # Skip directories (like metaData/)
            full = os.path.join(d, entry)
            if os.path.isdir(full):
                continue
            m = _UUID_RE.search(entry)
            if m:
                uuids.add(m.group(0).lower())
    return uuids


def cleanup_orphans():
    """Remove metadata files whose recording no longer exists. Returns count removed."""
    pattern = os.path.join(METADATA_DIR, "*.meta.json")
    meta_files = glob.glob(pattern)
    if not meta_files:
        return 0

    existing = _get_existing_uuids()
    removed = 0
    for fp in meta_files:
        fname = os.path.basename(fp)
        m = _UUID_RE.search(fname)
        if not m:
            continue
        uuid = m.group(0).lower()
        if uuid not in existing:
            try:
                os.unlink(fp)
                removed += 1
            except OSError as e:
                print(f"[metadata_fixer] WARN: failed to remove orphan {fname}: {e}")
    return removed


def scan():
    """Scan metadata directory: fix/enrich files and clean up orphans."""
    pattern = os.path.join(METADATA_DIR, "*.meta.json")
    files = glob.glob(pattern)
    fixed = 0
    for fp in files:
        if fix_file(fp):
            fixed += 1
    return fixed, len(files)


def main():
    print(f"[metadata_fixer] Started — scanning {METADATA_DIR} every {SCAN_INTERVAL}s")
    sys.stdout.flush()

    scan_count = 0
    while True:
        try:
            if os.path.isdir(METADATA_DIR):
                fixed, total = scan()
                if fixed > 0:
                    print(f"[metadata_fixer] Scan complete: fixed {fixed}/{total} files")
                    sys.stdout.flush()

                # Clean up orphaned metadata every 5th scan (~5 min)
                scan_count += 1
                if scan_count % 5 == 0:
                    removed = cleanup_orphans()
                    if removed > 0:
                        print(f"[metadata_fixer] Cleaned up {removed} orphaned metadata file(s)")
                        sys.stdout.flush()
        except Exception as e:
            print(f"[metadata_fixer] ERROR during scan: {e}")
            sys.stdout.flush()

        time.sleep(SCAN_INTERVAL)


if __name__ == "__main__":
    main()
