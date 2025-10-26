#!/usr/bin/env python3
"""Shared timestamp parsing utilities for log_monitor.sh"""
import os
import re
from datetime import datetime, timezone, timedelta, time

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

def parse_datetime(raw):
    """Parse various datetime formats"""
    if not raw:
        return None
    raw = raw.strip()
    if not raw:
        return None

    normalized = raw.replace('Z', '+00:00')
    candidates = [normalized]

    m = re.fullmatch(r"(\d{8})T(\d{6})([+-]\d{4})", raw)
    if m:
        date_part, time_part, offset = m.groups()
        candidates.append(
            f"{date_part[:4]}-{date_part[4:6]}-{date_part[6:]}T"
            f"{time_part[:2]}:{time_part[2:4]}:{time_part[4:]}"
            f"{offset[:3]}:{offset[3:]}"
        )

    m = re.fullmatch(r"(\d{8})T(\d{6})", raw)
    if m:
        date_part, time_part = m.groups()
        candidates.append(
            f"{date_part[:4]}-{date_part[4:6]}-{date_part[6:]}T"
            f"{time_part[:2]}:{time_part[2:4]}:{time_part[4:]}"
        )

    for candidate in candidates:
        try:
            return datetime.fromisoformat(candidate)
        except Exception:
            continue

    m = re.fullmatch(r"(\d{8})(\d{6})([+-]\d{4})", re.sub(r"[^0-9+\-]", "", raw))
    if m:
        date_part, time_part, offset = m.groups()
        try:
            dt = datetime.strptime(date_part + time_part, "%Y%m%d%H%M%S")
            sign = 1 if offset.startswith('+') else -1
            hours = int(offset[1:3])
            minutes = int(offset[3:5])
            offset_delta = timedelta(seconds=sign * (hours * 3600 + minutes * 60))
            return dt.replace(tzinfo=timezone(offset_delta))
        except Exception:
            pass

    digits = re.sub(r"\D", "", raw)
    if len(digits) == 14:
        try:
            dt = datetime.strptime(digits, "%Y%m%d%H%M%S")
            off_match = re.search(r"([+-]\d{2}:?\d{2})", raw)
            offset = off_match.group(1) if off_match else "+0000"
            offset = offset.replace(":", "")
            sign = 1 if offset.startswith('+') else -1
            hours = int(offset[1:3])
            minutes = int(offset[3:5])
            offset_delta = timedelta(seconds=sign * (hours * 3600 + minutes * 60))
            return dt.replace(tzinfo=timezone(offset_delta))
        except Exception:
            return None

    return None

def parse_time_of_day(raw):
    """Parse time of day (HH:MM, noon, midnight, etc.)"""
    if not raw:
        return None
    text = raw.strip()
    if not text:
        return None

    upper = text.upper().replace('.', '')
    specials = {
        "NOON": time(12, 0, 0),
        "MIDNIGHT": time(0, 0, 0),
    }
    if upper in specials:
        return specials[upper]

    patterns = (
        "%I:%M %p",
        "%I:%M%p",
        "%I %p",
        "%I%p",
        "%H:%M",
        "%H%M",
        "%H",
    )
    for fmt in patterns:
        try:
            return datetime.strptime(upper, fmt).time()
        except Exception:
            continue
    return None

def ensure_timezone(dt, fallback_dt=None):
    """Ensure datetime has timezone info"""
    if dt is None:
        return None
    if dt.tzinfo is None:
        if fallback_dt and fallback_dt.tzinfo is not None:
            return dt.replace(tzinfo=fallback_dt.tzinfo)
        tz_name = os.environ.get("TZ")
        if tz_name and ZoneInfo is not None:
            try:
                return dt.replace(tzinfo=ZoneInfo(tz_name))
            except Exception:
                return dt.replace(tzinfo=timezone.utc)
        return dt.replace(tzinfo=timezone.utc)
    return dt

def resolve(primary, fallback):
    """Resolve timestamp from primary and fallback values"""
    fallback_dt = parse_datetime(fallback)
    if fallback_dt:
        fallback_dt = ensure_timezone(fallback_dt)

    primary_dt = parse_datetime(primary)
    if primary_dt:
        return ensure_timezone(primary_dt, fallback_dt)

    primary_time = parse_time_of_day(primary)
    if primary_time and fallback_dt:
        return fallback_dt.replace(
            hour=primary_time.hour,
            minute=primary_time.minute,
            second=primary_time.second,
            microsecond=0,
        )

    return fallback_dt
