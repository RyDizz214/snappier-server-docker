# Changelog

## 1.2.8 – Notification Quality Update

- Cleaned channel metadata in notification payloads (removes IPTV country prefixes and `.us` suffixes).
- Added human-friendly schedule timestamps that honour the container’s `TZ` variable.
- Shortened job IDs in alerts while keeping the full UUID available as `job_id_full`.
- Emitted a dedicated `recording_live_started` action for “record now” requests and reused the 🔴 icon for parity.
- Added `recording_cancelled` notifications that recover program/channel metadata by rescanning the log tail.
- Normalised failure and warning icons to `❗` for visual consistency across catch-up, movie, series, and system alerts.
- Hardened the log monitor helper with metadata recovery, improved tail handling, and cleaned default `.gitignore` entries.

