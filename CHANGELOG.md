# Changelog

## 1.3.1 – TV Series Notifications + TMDB Integration

### New Features
- **TV Series Notifications** - Added complete notification support for TV series downloads:
  - Series completion notifications now properly trigger on `/SaveTVSeries` events
  - Episode information included in notifications (e.g., "S1E2 - Center of the Universe")
  - TMDB TV series integration for rich metadata (overview, genres, ratings)
  - Displays series name, episode, first air date, and TMDB ratings
- **TMDB TV Series Integration** - TV series notifications now automatically fetch metadata from TMDB:
  - Show overviews and descriptions
  - Genres (Drama, Crime, Comedy, etc.)
  - User ratings and vote counts
  - First air dates
  - Shares LRU cache with movie lookups (configurable via `TMDB_CACHE_MAX_SIZE`)

### Bug Fixes
- **CRITICAL: Fixed missing TV series completion notifications** - TV series downloads were not triggering completion notifications. Now properly detects `/SaveTVSeries` log events.

### Changes
- Extended TMDB helper module to support both movie (`/search/movie`) and TV series (`/search/tv`) lookups
- TV series cache keys prefixed with `tv:` to avoid collision with movie titles
- Rating display now supports both movies and TV series

## 1.3.0 – Movie Notification Fixes + TMDB Integration

### New Features
- **TMDB API Integration** - Movie notifications now automatically fetch rich metadata from The Movie Database (TMDB):
  - Full plot descriptions/overviews
  - Genres (Action, Crime, Comedy, etc.)
  - User ratings and vote counts
  - Release dates
  - LRU caching to minimize API calls (configurable via `TMDB_CACHE_MAX_SIZE`)
  - Graceful fallback if TMDB lookup fails

### Bug Fixes
- **CRITICAL: Fixed duplicate movie notifications** - Movies were triggering 3 completion notifications due to multiple log_monitor processes, remux events, and retry timeouts. Fixed by:
  - Skipping remux events for movies (only SaveMovie event sends notifications)
  - Increased curl timeout for movie actions from 8s to 25s (TMDB lookup on first request needs time)
  - Increased TMDB API timeout to 10s (configurable via `TMDB_TIMEOUT`)
  - Reduced retry attempts for movies from 3 to 2 (higher timeout = fewer retries needed)
  - Fixed duplicate logging caused by `tee` writing to both log file and stderr
- **CRITICAL: Fixed missing movie metadata** - Fixed schedules.json path configuration. The SCHEDULES env var and docker-compose mount now correctly point to `/root/SnappierServer/Recordings/schedules.json` where Snappier Server actually stores schedule data.
- **Fixed notification retry timeouts** - Movie notifications were timing out because TMDB enrichment took longer than the 8-second curl timeout. Now movie actions get 15 seconds.
- **Fixed rogue log_monitor processes** - Eliminated duplicate notifications caused by multiple log_monitor processes running simultaneously.
- **Enhanced metadata lookup** - Updated `lookup_schedule()` to also check `.meta.json` files in Movies/metaData, Recordings/metaData, and TVSeries/metaData directories as fallback.
- **Improved duplicate detection** - Enhanced deduplication logic prevents multiple notifications for the same event.

### Changes
- Remux events (exit and delete) now skip movies entirely - only the `[SaveMovie] process closed` event triggers movie notifications.
- Movie started and completed notifications now pass year and type metadata to the webhook for better enrichment.
- Updated `SCHEDULES` environment variable to point to the correct location: `/root/SnappierServer/Recordings/schedules.json`
- Updated docker-compose.yml to mount schedules.json from the correct host path: `/data/recordings/snappier-server/Recordings/schedules.json`
- Added new environment variables:
  - `TMDB_API_KEY` - Your TMDB API key for metadata enrichment
  - `TMDB_ENABLED=1` - Enable/disable TMDB integration
  - `TMDB_CACHE_MAX_SIZE=500` - Maximum TMDB cache entries (LRU)
  - `TMDB_TIMEOUT=10` - TMDB API timeout in seconds (default: 10)

## 1.2.8 – Notification Quality Update + Reliability Fixes

### Features
- **NEW: Catch-up Download Extension** - Automatically extends catch-up downloads by 3 minutes to prevent early cutoffs (configurable via `CATCHUP_BUFFER_SECONDS`).
- **Enhanced catch-up completion notifications** - Now includes filename, aired time, and all metadata from the download start event.
- Cleaned channel metadata in notification payloads (removes IPTV country prefixes and `.us` suffixes).
- Added human-friendly schedule timestamps that honour the container's `TZ` variable.
- Shortened job IDs in alerts while keeping the full UUID available as `job_id_full`.
- Emitted a dedicated `recording_live_started` action for "record now" requests and reused the 🔴 icon for parity.
- Added `recording_cancelled` notifications that recover program/channel metadata by rescanning the log tail.
- Normalised failure and warning icons to `❗` for visual consistency across catch-up, movie, series, and system alerts.
- Hardened the log monitor helper with metadata recovery, improved tail handling, and cleaned default `.gitignore` entries.

### Bug Fixes (Critical & High Priority)
- **CRITICAL: Fixed FFmpeg wrapper not being installed** - The wrapper script was copied but never replaced the actual ffmpeg binary, causing catch-up extensions to not work.
- **CRITICAL: Fixed catch-up extension logic** - Snappier Server uses timeshift URLs (not `-t` parameter), now properly extends the duration in the URL from 60 to 63 minutes.
- **Fixed catch-up completion notifications** - Now detects `[remux] deleted:` event and sends completion notification with the final .mkv filename instead of the deleted .ts file. Suppressed download completion notification when `ENABLE_REMUX=1` to prevent duplicate notifications. Fixed aired time to include full date by prioritizing filename timestamp over schedule data.
- **Fixed ffmpeg.real path mismatch** - Wrapper was calling `/usr/local/bin/ffmpeg.real` but Dockerfile moved it to `/usr/bin/ffmpeg.real`.
- **Fixed webhook startup race condition** - Implemented flock-based locking to prevent duplicate webhook instances or missed startups.
- **Fixed unbounded memory growth** - Implemented LRU cache with configurable limits for EPG index (50k entries) and HTTPS capability cache (1k entries).
- **Fixed notification loss on webhook errors** - Changed curl from `-sS` to `-fsS` to properly fail on HTTP errors, added retry logic with exponential backoff (3 attempts default).
- **Fixed Pushover attachment file handle leak** - Attachment files now read into memory before passing to requests library, preventing intermittent upload failures.

### Improvements
- Added comprehensive cache statistics tracking (hits/misses/probes/warnings) exposed via `/health` endpoint.
- Enhanced logging throughout notification pipeline with detailed error messages.
- Added configurable retry logic for failed notification POSTs (`NOTIFY_RETRY_ATTEMPTS`, `NOTIFY_RETRY_DELAY`).
- Webhook startup now validates PID file and process command before assuming webhook is running.
- Process startup checks if webhook died during initialization and reports detailed error logs.

### New Environment Variables
- `CATCHUP_EXTENSION_ENABLED=1` - Enable catch-up extension feature
- `CATCHUP_BUFFER_SECONDS=180` - Buffer time for catch-ups (seconds)
- `EPG_INDEX_MAX_SIZE=50000` - Max EPG cache entries
- `HTTPS_CACHE_MAX_SIZE=1000` - Max HTTPS capability cache
- `NOTIFY_RETRY_ATTEMPTS=3` - Notification POST retry count
- `NOTIFY_RETRY_DELAY=2` - Initial retry delay (seconds)
- `FFMPEG_WRAPPER_LOG=/logs/ffmpeg_wrapper.log` - FFmpeg wrapper logging

