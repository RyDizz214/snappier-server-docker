# Changelog

## 1.3.4a – Production Reliability & Observability

- **Structured logging system** with DEBUG, INFO, WARNING, ERROR levels and ISO 8601 timestamps
- **Pushover retry logic** with exponential backoff (2s → 4s → 8s) for reliability
- **Startup credential validation** for Pushover with clear error messages
- **Request timeouts** (5 seconds) on file operations to prevent handler hangs
- **Catchup notification improvements** - fixed empty channel handling and added payload validation
- **FFmpeg wrapper enhancements** - 3-minute buffer extension on catch-up downloads to ensure endings don't get cut off
- **Code deduplication** - shared timestamp parsing module reduces duplication by 150+ lines
- **Comprehensive documentation** - detailed README, DEVELOPER guide, and release notes
- **Zero regressions** - all 20 notification types tested and passing

See [RELEASE_NOTES_v1.3.4a.md](RELEASE_NOTES_v1.3.4a.md) for detailed changelog.

## 1.2.8 – Notification Quality Update

- Cleaned channel metadata in notification payloads (removes IPTV country prefixes and `.us` suffixes).
- Added human-friendly schedule timestamps that honour the container’s `TZ` variable.
- Shortened job IDs in alerts while keeping the full UUID available as `job_id_full`.
- Emitted a dedicated `recording_live_started` action for “record now” requests and reused the 🔴 icon for parity.
- Added `recording_cancelled` notifications that recover program/channel metadata by rescanning the log tail.
- Normalised failure and warning icons to `❗` for visual consistency across catch-up, movie, series, and system alerts.
- Hardened the log monitor helper with metadata recovery, improved tail handling, and cleaned default `.gitignore` entries.

