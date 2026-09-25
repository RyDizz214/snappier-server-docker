"""Xtream channel ID cache — maps provider stream IDs to EPG channel IDs.

Fetches each provider's live stream list via the Xtream API and builds a
lookup: (provider_domain, stream_id) → epg_channel_id.

Used by both metadata_fixer.py and enhanced_webhook.py to resolve the exact
EPG channel from a catch-up timeshift URL.

Cache refreshes automatically when older than REFRESH_INTERVAL_SEC.
"""

import json
import os
import sys
import time
import re
from datetime import datetime, timezone
from urllib.parse import urlparse, parse_qs

try:
    import requests
    _HAS_REQUESTS = True
except ImportError:
    _HAS_REQUESTS = False

try:
    import httpx
    _HAS_HTTPX = True
except ImportError:
    _HAS_HTTPX = False

REFRESH_INTERVAL_SEC = int(os.environ.get("XTREAM_CACHE_REFRESH_SEC", "10800"))  # 3 hours
REQUEST_TIMEOUT = int(os.environ.get("XTREAM_CACHE_TIMEOUT", "30"))

# Cache state
_cache = {}              # (domain, stream_id_str) -> epg_channel_id
_channel_names = {}      # (domain, stream_id_str) -> channel display name
_stream_host_provider = {}  # streaming-URL hostname -> provider name (e.g. "Veil")
_provider_tz = {}        # API or streaming hostname -> IANA tz from server_info (e.g. "Europe/London")
_last_refresh = 0
_providers = []          # list of {domain, scheme, username, password, name}


def _parse_providers():
    """Parse EPG_URLS_JSON to extract provider credentials."""
    global _providers
    if _providers:
        return _providers
    raw = os.environ.get("EPG_URLS_JSON", "")
    if not raw:
        return []
    try:
        entries = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []
    for entry in entries:
        url = entry.get("url", "")
        if not url:
            continue
        u = urlparse(url)
        params = parse_qs(u.query)
        username = params.get("username", [""])[0]
        password = params.get("password", [""])[0]
        if u.hostname and username and password:
            # Keep hostname-only as the cache key (log_monitor strips ports
            # from ffmpeg URLs before lookup). Track netloc separately so the
            # API fetch preserves any non-default port.
            _providers.append({
                "domain": u.hostname,
                "netloc": u.netloc,
                "scheme": u.scheme or "http",
                "username": username,
                "password": password,
                "name": entry.get("name", u.hostname),
            })
    return _providers


def _fetch_json(url):
    """Fetch JSON from URL using requests or httpx."""
    if _HAS_REQUESTS:
        r = requests.get(url, timeout=REQUEST_TIMEOUT, verify=False)
        r.raise_for_status()
        return r.json()
    elif _HAS_HTTPX:
        with httpx.Client(timeout=REQUEST_TIMEOUT, verify=False) as client:
            r = client.get(url)
            r.raise_for_status()
            return r.json()
    else:
        raise RuntimeError("No HTTP library available (install requests or httpx)")


def refresh(force=False):
    """Refresh the cache if stale or forced."""
    global _cache, _channel_names, _stream_host_provider, _provider_tz, _last_refresh

    if not force and _cache and (time.time() - _last_refresh) < REFRESH_INTERVAL_SEC:
        return  # cache is fresh

    providers = _parse_providers()
    if not providers:
        return

    # Merge into existing cache rather than replacing wholesale.
    # This way, if some providers fail, their existing mappings are preserved.
    new_cache = dict(_cache)
    new_names = dict(_channel_names)
    new_host_provider = dict(_stream_host_provider)
    new_tz = dict(_provider_tz)
    total = 0
    succeeded = []
    failed = []

    for prov in providers:
        netloc = prov.get("netloc") or prov["domain"]
        auth_url = (
            f"{prov['scheme']}://{netloc}/player_api.php"
            f"?username={prov['username']}&password={prov['password']}"
        )
        api_url = auth_url + "&action=get_live_streams"
        # Timeshift URLs carry the air time in the provider's server timezone
        # (server_info.timezone), which differs per provider and follows DST.
        tz_name = None
        try:
            tz_name = (_fetch_json(auth_url).get("server_info") or {}).get("timezone") or None
        except Exception:
            pass
        # Aliases the cache should also be keyed by for this provider —
        # populated from any channel whose direct_source streams from a
        # different hostname than the API endpoint.
        aliases = set()
        try:
            channels = _fetch_json(api_url)
            if not isinstance(channels, list):
                failed.append(prov['name'])
                continue
            count = 0
            for ch in channels:
                sid = str(ch.get("stream_id", ""))
                epg_id = ch.get("epg_channel_id", "")
                name = ch.get("name", "")
                ds = ch.get("direct_source") or ""
                ds_host = None
                if ds:
                    try:
                        ds_host = urlparse(ds).hostname
                    except Exception:
                        ds_host = None
                if ds_host and ds_host != prov["domain"]:
                    aliases.add(ds_host)
                if sid and epg_id:
                    new_cache[(prov["domain"], sid)] = epg_id
                    for alias in aliases:
                        new_cache[(alias, sid)] = epg_id
                    count += 1
                if sid and name:
                    new_names[(prov["domain"], sid)] = name
                    for alias in aliases:
                        new_names[(alias, sid)] = name
            for alias in aliases:
                new_host_provider[alias] = prov["name"]
            if tz_name:
                for host in (prov["domain"], *aliases):
                    new_tz[host] = tz_name
            total += count
            succeeded.append(f"{prov['name']}({count})")
        except Exception as e:
            failed.append(f"{prov['name']}")

    if new_cache:
        _cache = new_cache
        _channel_names = new_names
        _stream_host_provider = new_host_provider
        _provider_tz = new_tz
        _last_refresh = time.time()
        summary = f"[xtream_cache] Cached {total} stream mappings from {len(succeeded)} providers: {', '.join(succeeded)}"
        if failed:
            summary += f" | failed: {', '.join(failed)}"
        print(summary, flush=True)


def lookup(provider_domain, stream_id):
    """Look up the EPG channel ID for a provider's stream ID.

    Returns epg_channel_id (e.g. "bravo.us") or None.
    """
    refresh()  # ensure cache is fresh
    if not _cache:
        return None
    return _cache.get((provider_domain, str(stream_id)))


def lookup_name(provider_domain, stream_id):
    """Look up the channel display name for a provider's stream ID.

    Returns name (e.g. "Bravo") or None.
    """
    refresh()
    if not _channel_names:
        return None
    return _channel_names.get((provider_domain, str(stream_id)))


def lookup_provider_name(provider_domain):
    """Look up the EPG source name for a provider domain.

    Returns name (e.g. "Nebula") or None. This matches the 'source' field
    in EPG entries, allowing us to prefer entries from the same provider.
    Accepts either the configured API host or any streaming host discovered
    from a channel's direct_source.
    """
    providers = _parse_providers()
    for prov in providers:
        if prov["domain"] == provider_domain:
            return prov["name"]
    # Streaming-host fallback (populated by refresh()).
    return _stream_host_provider.get(provider_domain)


def lookup_timezone(provider_domain):
    """Look up the IANA timezone a provider's timeshift URLs are expressed in.

    Returns e.g. "Europe/London" or None if the provider didn't report one.
    Accepts either the configured API host or any streaming host discovered
    from a channel's direct_source.
    """
    refresh()
    return _provider_tz.get(provider_domain)


def parse_timeshift_url(wrapper_log_line):
    """Extract (provider_domain, stream_id, airtime) from an ffmpeg wrapper log line
    containing a timeshift URL.

    Returns (domain, stream_id, airtime) or (None, None, None).

    Example URL: https://veiltheworld.com/timeshift/user/pass/65/2026-03-26:00-00/59258.ts
    """
    # Provider domain
    m_domain = re.search(r'https?://([^/:]+)(?::\d+)?/timeshift/', wrapper_log_line)
    domain = m_domain.group(1) if m_domain else None

    # Air time: YYYY-MM-DD:HH-MM
    m_air = re.search(
        r'/timeshift/[^/]+/[^/]+/\d+/(\d{4}-\d{2}-\d{2}:\d{2}-\d{2})/', wrapper_log_line
    )
    airtime = m_air.group(1) if m_air else None

    # Stream ID: last numeric segment before .ts in the timeshift URL path
    m_sid = re.search(r'/timeshift/[^/]+/[^/]+/\d+/[^/]+/(\d+)\.ts', wrapper_log_line)
    stream_id = m_sid.group(1) if m_sid else None

    return domain, stream_id, airtime


def parse_live_url(wrapper_log_line):
    """Extract (provider_domain, stream_id) from an ffmpeg wrapper log line
    containing a live stream URL.

    Returns (domain, stream_id) or (None, None).

    Example URL: https://veiltheworld.com/live/user/pass/19970.ts
    """
    m_domain = re.search(r'https?://([^/:]+)(?::\d+)?/live/', wrapper_log_line)
    domain = m_domain.group(1) if m_domain else None

    m_sid = re.search(r'/live/[^/]+/[^/]+/(\d+)\.ts', wrapper_log_line)
    stream_id = m_sid.group(1) if m_sid else None

    return domain, stream_id
