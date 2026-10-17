# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version numbers track the bundled Snappier Server CLI. Up to 2.0.2 they did so
where practical (image `2.0.2` ships CLI `2.0.2-11`); from 2.0.4 onward the
image version matches the CLI version exactly, so image `2.0.4-9` ships CLI
`2.0.4-9`.

## [2.0.4-9] — 2026-10-12 (image rebuilt 2026-10-17)

Tracks upstream's 2.0.4 CLI. The image was rebuilt on 2026-10-17 on Ubuntu
26.04 LTS. The version number stays the same because it matches the bundled
CLI, which has not changed.

### About Snappier Server

Snappier Server is a **companion add-on for the Snappier IPTV app** (Apple TV,
iPhone, iPad). It is not a stand-alone player. It records, gathers channels,
films and shows into one playlist, and supplies the TV guide. You watch in the
Snappier IPTV app.

### Removed

- **In-browser playback in the dashboard** (upstream CLI 2.0.4). The
  dashboard no longer has a video player. The bundled `hls.js` player is gone
  from the CLI. Playback belongs in the Snappier IPTV app, which Snappier
  Server is built to support. The dashboard is now for setup and management,
  and its setup wizard ends by connecting the Snappier IPTV app.

### Added

- **`--show-token`** (new since upstream CLI 2.0.2-11). Prints the API token that the
  dashboard and setup wizard ask for, and exits without starting the server.
- Upstream also added a `--desktop` flag. It is used by the Snappier Server
  desktop app to start its own server and is not needed in this image.

### Changed

- Bundled Snappier Server CLI **2.0.4-9** (from 2.0.2-11). Apart from the two
  new flags, the release contains upstream changes that were not visible in
  the options, settings or `--help` output. `--check-config` gives the same
  result on an existing configuration, and `config.json` is not modified on
  upgrade.
- FFmpeg stays at **9.0.1**.
- **Base image moves from Ubuntu 25.04 to Ubuntu 26.04 LTS** (2026-10-17
  rebuild). Ubuntu 25.04 reached end of life in January 2026 and gets no
  more security updates. 26.04 is supported until 2031. Python in the image
  goes from 3.13 to 3.14. Comskip is now built against Ubuntu's FFmpeg 8.0
  libraries. The bundled FFmpeg used for recording is still 9.0.1.
- Comskip is patched at build time to compile against FFmpeg 8, which removed
  a field Comskip relied on (upstream issue #186). Commercial detection
  results are unchanged.
- x265 (the H.265 encoder in the bundled FFmpeg) moves from 3.5 to **4.2**,
  now built from the maintained upstream source. The old source no longer
  builds with the CMake in Ubuntu 26.04.

## [2.0.2] — 2026-09-25

Tracks upstream's 2.0.2 CLI. Nothing in this image changed besides the CLI.

### Added

- **Built-in VPN or proxy** (upstream CLI 2.0.2). Snappier Server can now
  send everything it fetches from providers through WireGuard, a SOCKS5 proxy
  or an HTTP proxy. You set it up in the dashboard under Settings → IPTV
  Provider, and it is stored in the new `outbound_proxy_*` keys. **It is off
  by default.** If you already use `docker-compose.vpn.yml` (gluetun), leave
  it off, because turning it on as well puts provider traffic through two
  tunnels.
- Upstream now bundles `wireproxy` (v1.1.3, ISC licence) in the CLI
  archive. The server starts it only when the built-in WireGuard option is on.
- New `xtream_art_through_server` key, off by default. It loads channel logos,
  posters and guide icons through the server.

### Changed

- Bundled Snappier Server CLI **2.0.2-11** (from 2.0.1-1). The CLI's embedded
  runtime moves from Node.js 18.5 to **Node.js 24.18** (OpenSSL 3.0.5 → 3.5.7).
  `--help` output is the same as 2.0.1. `--check-config` gives the same result
  on an existing configuration, and `config.json` is not modified on upgrade.
- FFmpeg stays at **9.0.1**.

## [2.0.1] — 2026-09-24

A point release: upstream's 2.0.1 CLI, FFmpeg 9, and two fixes to how
recordings are matched to the programme guide.

### Added

- **Support log** (upstream CLI 2.0.1). `--support-log [1|6|24]`, or the
  dashboard's Settings → Server → Logging → Support log, writes a redacted
  `snappier-support-log-<REF>.txt` covering the last 1, 6 or 24 hours to the
  logs folder and exits without starting the server — safe to attach to a bug
  report.

### Changed

- Bundled Snappier Server CLI **2.0.1-1** (from 2.0.0-2). No configuration
  changes; `config.json` is not modified on upgrade. The rest of upstream's
  delta is catalog-source documentation and dashboard wording.
- **FFmpeg 9.0.1** (from 8.1.2), still pinned. The wrapper ran against 9.0.1
  in production before this pin moved.
- CI no longer rebuilds FFmpeg on every run. Now that the version is pinned,
  the cached layer is reused until the pin changes.

### Fixed

- **Catch-ups reported with the wrong programme and air time.** Providers put
  the air time in timeshift URLs in their own server timezone (Europe/London
  for some, UTC for others, following DST), and it was compared digit-for-digit
  against guide entries that may use a different offset. A catch-up could match
  the show an hour either side, so the notification, `.meta.json` and
  dashboard showed the wrong title, description and time. The provider's
  timezone is now read from its Xtream `server_info` and the air time is
  matched as an exact instant. Providers that report no timezone keep the old
  behaviour.
- **Recordings shown with another channel's name and logo.** When a
  recording's own channel had no matching guide entry, the metadata fixer
  searched every channel for the same title and could pick another provider's
  channel. It now only does that when the recording's channel is unknown.
- **Channel guessed by title for some recordings.** If the stream details were
  missed when a recording started (e.g. the container restarted mid-recording),
  the completion notification fell back to guessing the channel by title and
  could show an unrelated channel's logo. They are now re-read at completion.
  Comskip notifications carry the recording's stream details too, and are never
  matched by title alone.

## [2.0.0] — 2026-09-20

First release in five months, bundling upstream's first stable 2.0.0 CLI along
with a backlog of recording-pipeline fixes that had been running in production
before landing here.

### Added

- **Commercial detection (Comskip).** The image now builds Comskip from source
  and installs it at `/usr/local/bin/comskip`, so Snappier's `--enable-comskip`
  works out of the box. It was previously broken: the CLI unpacks its own
  bundled comskip at runtime, but that binary needs FFmpeg 4.x shared objects
  (`libavutil.so.56` and friends) which no current container base provides, so
  every run died with "error while loading shared libraries". Off by default via
  `ENABLE_COMSKIP=false` — it is CPU-heavy and takes minutes per recording.
  `COMSKIP_PATH` and `COMSKIP_INI` let you supply your own binary or tuning.
- **Comskip output lands on the right filename immediately.** The installed
  comskip is a wrapper that rebases orphaned `.edl`/`.txt` output as soon as a
  run exits, instead of waiting up to 60s for the next metadata scan.
- **`.meta.json` sidecars for scheduled and live recordings.** Only catch-up
  recordings ever got one, so scheduled recordings showed up in the dashboard
  as "Uncategorized" with placeholder titles.
- **Comskip completion notifications.** `comskip_completed` / `comskip_failed`
  webhook events, so a failed detection is visible outside the raw log.
- **Multiple dependents per gluetun sidecar** in `gluetun_watcher.sh`, for
  setups where several containers share one VPN network namespace.

### Changed

- **FFmpeg is pinned to 8.1.2** rather than resolving the newest stable tarball
  at build time. Two builds of the same tag could previously ship different
  FFmpeg major versions; the resolver currently returns 9.0.2, which this
  image's wrapper has never been tested against. Set `FFMPEG_VERSION=latest`
  for the old behaviour.
- Bundled Snappier Server CLI **2.0.0-2** (from 1.5.1-1).
- The CLI archive is verified against its published SHA-256 before use.

### Fixed

- **The image could not be built at all.** Upstream moved downloads to
  per-version directories (`files/v<VER>/<file>`), so the flat path this
  Dockerfile used returned 404 for every version — including the pinned
  1.5.1-1 — and failed the build outright.
- **Dashboard playback broke behind a real hostname.** The VPN overlay mapped
  `SNAPPIER_DOMAIN` to `127.0.0.1` inside the gluetun namespace. Fine for a
  placeholder like `snappier.local`; with a real public hostname the HLS
  pipeline resolved its own URL to a port with nothing listening, wrote a
  manifest, and never produced segments.
- **Commercial detection destroyed by a rename race.** Renaming a recording
  while Comskip was running killed it with exit 255 and produced no `.edl`.
  Renames are now deferred while a Comskip process holds the recording's UUID,
  bounded so a hung run cannot block forever.
- **Sidecars left behind on rename.** Only the recording itself was renamed,
  orphaning `.edl`/`.txt`/`.logo.txt`/`.meta.json` under the old stem.
- **Recordings stuck with a `--` prefix forever.** When a scan landed within
  ~2s of download start, the `.meta.json` was renamed alone and later scans
  short-circuited because it no longer matched as a catch-up.
- **Pushover notifications silently dropped.** An unresolvable stream host sent
  catch-up lookups into a fuzzy-match path that raised `UnboundLocalError` and
  returned HTTP 500; the retry then hit the 60s dedup window and reported
  success, so a hard failure looked like a delivered notification. Matching is
  now deterministic on `(channel, airtime)`.
- **Stopped recordings never left `schedules.json`,** so the iOS app kept
  showing them as scheduled.
- **Unplayable manifests when probing failed.** A probe failure assumed H.264
  and applied `-c copy`, producing HEVC-in-fMP4 that would not play. Both the
  probe-fail and non-H.264 paths now leave the codec alone and only inject
  missing transcode safety flags.
- **720p sources were upscaled** to 1080p by the HLS scale filter.
- HTTP `.ts` URLs no longer fall into the remux path.
- A non-default provider port is no longer lost when building the Xtream
  `player_api.php` URL.

### Removed

- `HLS_MAX_HEIGHT` — superseded by an inline `min(1080,ih)` scale expression.
- The unused `extend_duration()` helper in `ffmpeg-wrapper.sh`.

### Breaking

- **`CATCHUP_BUFFER_SECONDS` is replaced by `CATCHUP_BUFFER_MINUTES`.** Defaults
  are adjusted so out-of-the-box behaviour is unchanged at 5 minutes, but if you
  set the old variable you must migrate. The wrapper logs a warning when the old
  name is still present rather than silently falling back to the default.

### Upstream notes (Snappier CLI 2.0.0)

Your existing `config.json` keeps working — single-provider keys are folded into
the new multi-source list automatically, preserving the IDs your favourites and
watch progress point at. Worth knowing:

- **Rotate your API token.** Builds before 1.7.0-12 could write it to
  `server.log`, and rotated logs from that period may still be on disk.
- **Consider rotating provider passwords.** Outbound stream URLs carried them in
  clear until 1.7.0-18, and a config reload printed the whole configuration
  until 1.7.0-23.
- **`?token=` in URLs is deprecated and will be removed in 2.1.0.** Use the
  `X-API-Token` header or `Authorization: Bearer`.
- **Behind a reverse proxy, set `trust_proxy` and `public_base_url`.** Xtream
  clients build stream URLs from the address the server reports; without these
  sign-in succeeds and playback fails against an unreachable host.
- **Linux FFmpeg is yours to provide**, 4.x minimum, and `ffprobe` should be
  present. This image supplies both.
- **`--check-config`** validates `config.json` and exits without starting
  anything.
- `/health` reports `degraded` for configuration errors and environment faults
  only; warnings no longer move the status.
- The dashboard now requires signing in.

## [1.5.1] — 2026-04-20

### Fixed

- Dashboard live playback failed with "Failed to start live playback". Snappier
  1.5.0's dashboard referenced `hls.js@1.5.21`, a version never published to
  npm; the CDN returned 404 and `playLive()` threw. Upstream 1.5.1-1 moves to
  `hls.js@1.6.16`. A `sub_filter` reverse-proxy workaround for this is no
  longer needed.

### Changed

- Bundled Snappier Server CLI **1.5.1-1** (from 1.5.0).
- CI now publishes to GHCR directly.

## [1.5.0] — 2026-04-18

### Added

- **Multi-arch images** — `linux/amd64` and `linux/arm64`, built via buildx with
  the Snappier CLI fetched per architecture from `TARGETARCH`.
- **VPN overlay** (`docker-compose.vpn.yml`) — provider-agnostic gluetun
  sidecar; the server joins its network namespace.
- **Host-FFmpeg overlay** (`docker-compose.host-ffmpeg.yml`) — skips the FFmpeg
  build for local development. x86-64 only.
- Signed tags and commits.

### Changed

- Bundled Snappier Server CLI **1.5.0** (from 1.3.4b), bringing the web
  dashboard, HLS live playback and API token authentication.
- FFmpeg tracks the latest upstream stable, rebuilt on each CI run.
- Volume paths are portable, rooted at `DATA_DIR`.
- Timezone comes from the `TZ` environment variable instead of being baked in.
- `example.env` rewritten; README rewritten for end users.

### Removed

- `Dockerfile.minimal`, `docker-compose.minimal.yml`, `README-MINIMAL.md`.
- `scripts/https_watcher.py`, superseded by the health watcher.

### Breaking

- Volume paths changed; see the v1.5.0 release notes for the migration.
- Timezone is no longer forced.
- `schedules.json` and `server.log` mounts were consolidated.

[2.0.4-9]: https://github.com/RyDizz214/snappier-server-docker/releases/tag/v2.0.4-9
[2.0.1]: https://github.com/RyDizz214/snappier-server-docker/releases/tag/v2.0.1
[2.0.0]: https://github.com/RyDizz214/snappier-server-docker/releases/tag/v2.0.0
[1.5.1]: https://github.com/RyDizz214/snappier-server-docker/releases/tag/v1.5.1
[1.5.0]: https://github.com/RyDizz214/snappier-server-docker/releases/tag/v1.5.0
