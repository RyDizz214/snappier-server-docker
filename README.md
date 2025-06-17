# Snappier Server Docker Image

This repository contains the build context for `ghcr.io/rydizz214/snappier-server-docker`, a self‑contained Docker image that bundles the Snappier Server CLI, a hardened FFmpeg toolchain, and the notification helpers that enrich and forward events to Pushover.

## Key Features

- **Prebuilt FFmpeg toolchain** – statically linked with x264/x265, libvpx, fdk-aac, opus, freetype, and other common codecs.
- **Enhanced notification pipeline** – Python webhook and Node shim parse Snappier log output, enrich the payload with EPG metadata, and send structured JSON to Pushover.
- **Clean metadata for alerts** – channel names have the IPTV provider prefix stripped, job IDs are shortened for readability, and cancellation events are recovered even if only a tail log is available.
- **Human-friendly schedule timestamps** – scheduled recordings include an auto-localised start time that honours the container’s `TZ` variable.
- **Drop-in entrypoint** – the container uses `/usr/local/bin/entrypoint.sh` to launch the notifier stack, background helpers, and `snappier-server-cli`.

## Repository Layout

```
├── Dockerfile
├── docker-compose.yml        # Reference compose file with sane defaults
├── entrypoint.sh             # Boot sequence for notify + Snappier CLI
├── notify/                   # Enhanced webhook + node-notifier shim
├── scripts/                  # Log monitor, health watcher, etc.
├── ffmpeg-wrapper.sh         # Wrapper that points ffmpeg -> ffmpeg.real
├── .gitignore
└── CHANGELOG.md              # Release notes
```

## Requirements

- Docker 24+
- Optional: Docker Compose v2 if you want to use `docker-compose.yml`
- Pushover user/app tokens (set via environment variables)

## Building Locally

```bash
git clone https://github.com/rydizz214/snappier-server-docker.git
cd snappier-server-docker
docker build -t ghcr.io/rydizz214/snappier-server-docker:1.2.8 .
```

The build script downloads the Snappier Server CLI artifact (`v1.2.8`, x64 linux) and the latest FFmpeg source, compiles the encoder stack, and copies in the notification helpers.

## Publishing to GHCR

Once the image builds successfully:

```bash
# Authenticate once (GitHub PAT with package:write scope)
echo "${GHCR_TOKEN}" | docker login ghcr.io -u rydizz214 --password-stdin

docker push ghcr.io/rydizz214/snappier-server-docker:1.2.8
```

## Runtime Configuration

The container uses environment variables to control behaviour. The reference `.env.example` includes common options; the most relevant ones are listed below:

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `America/New_York` | Controls timezone for the container and notification timestamps. |
| `PUSHOVER_USER_KEY` / `PUSHOVER_APP_TOKEN` | _(required)_ | Pushover credentials for alerts. |
| `NOTIFICATION_HTTP_PORT` | `9080` | Internal webhook port (not exposed by default). |
| `SNAP_LOG_FILE` | `/logs/snappier.log` | Original Snappier log path; the enhanced log monitor now tails `/root/SnappierServer/server.log`. |
| `LOG` | `/root/SnappierServer/server.log` | Overrides the log monitor target. |
| `SNAPPY_API_BASE` | `http://127.0.0.1:8000` | REST endpoint for EPG enrichment. |

## Running with Docker Compose

1. Copy `.env.example` to `.env` and adjust the values (particularly Pushover credentials and media library paths).
2. Launch the stack:

   ```bash
   docker compose up -d
   ```

3. Tail the notification log to confirm delivery:

   ```bash
   docker compose logs -f snappier-server | grep notify
   ```

## Notification Behaviour

- **Recording started (live)** – emitted immediately when the Snappier scheduler starts a “record now” request. Uses the 🔴 indicator.
- **Recording started (scheduled)** – triggered when FFmpeg begins writing the `.ts` file; includes shortened `job_id` plus the full UUID as `job_id_full`.
- **Recording cancelled** – watches for `saveLiveWithFFmpeg` cancel messages (code 255) and back-fills channel/program metadata from the log tail.
- **Catch-up downloads** – `catchup_started` / `catchup_completed` / `catchup_failed` still fire, but job IDs are shortened and channel strings are cleaned.
- **Failure / warning events** – all use the ❗ marker for consistent prominence (`recording_failed`, `catchup_failed`, `health_warn`, `server_error`, etc.).

## Contributing

1. Fork the repository and create a feature branch.
2. Make your changes and run `docker build` locally.
3. Update `CHANGELOG.md` with a concise summary.
4. Open a pull request.

Please include log samples if you’re extending the monitor to handle new event formats—the helpers rely on regexes and a small amount of log context to recover metadata.

## License

MIT License. See [LICENSE](LICENSE) for details.

