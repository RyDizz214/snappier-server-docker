# Snappier-Server Docker

A Docker image that packages the Snappier-Server CLI (v0.0.0s) on Ubuntu 25.04 with FFmpeg installed. This multi-stage Dockerfile:

1. **Base stage**: installs runtime dependencies, FFmpeg (7.1.1), and configures timezone.
2. **Snappier-Server stage**: downloads and installs the Snappier-Server CLI binary for your architecture.

---

## Features

* **Snappier-Server CLI v0.0.0s** for Linux (amd64 & arm64)
* **FFmpeg 7.1.1** installed via `apt` for encoding/decoding support
* **Timezone support** (default `America/New_York`, override via `TZ` build arg)
* **Exposed HTTP port 8000** for API/UI
* **Persistent volumes** for Recordings, Movies, Series, and PVR
* **Default environment variables** for ports, remuxing, folder locations, and download rate

---

## Prerequisites

* Docker Engine ≥ 20.10
* (Optional) Build argument `TARGETARCH` if cross-building

---

## Building the Image

```bash
# From the project root
docker build \
  --tag ghcr.io/rydizz214/snappier-server:0.0.0s \
  --build-arg TZ="America/New_York" \
  .
```

This creates an image named `ghcr.io/rydizz214/snappier-server:0.0.0s` containing:

* `/usr/local/bin/snappier-server` (the CLI)
* FFmpeg binaries in `/usr/bin/ffmpeg` & `/usr/bin/ffprobe`

> **Tip:** If you’ve already pulled the previous `ghcr.io/rydizz214/snappier-server:0.8.0r` image, run `docker rmi ghcr.io/rydizz214/snappier-server:0.8.0r` before rebuilding to avoid confusion.

---

## Download Options

By default, Snappier-Server will use `curl` to fetch media segments. We **strongly recommend** limiting the download speed to `10 MB/s` to avoid throttling or connection drops by IPTV providers:

```bash
# Set this when running the container (or in your Docker Compose file):
DOWNLOAD_SPEED_LIMIT_MBS=10
```

If you encounter incomplete or failed downloads with `curl`, you can switch to an `ffmpeg`-based download method—this tends to be more resilient for certain hosts or network conditions. To enable the FFmpeg download fallback:

```bash
# When running the container:
USE_FFMPEG_TO_DOWNLOAD=true
```

When `USE_FFMPEG_TO_DOWNLOAD=true` is set:

* All movie/series downloads and CatchupTV fetches will route through `ffmpeg` instead of `curl`.
* The container image already includes `ffmpeg` (version ≥ 7.1.1), so no extra installation is required.

---

## Running the Container

Run with default settings:

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  ghcr.io/rydizz214/snappier-server:0.0.0s
```

### Customizing via Environment Variables

| Variable                   | Default                           | Description                                                               |
| -------------------------- | --------------------------------- | ------------------------------------------------------------------------- |
| `PORT`                     | `7429:8000`                       | Host : container port mapping (container always listens on 8000)          |
| `ENABLE_REMUX`             | `true`                            | Enable/disable automatic remuxing of completed `.ts` → `.mkv`             |
| `RECORDINGS_FOLDER`        | `/root/SnappierServer/recordings` | Root folder inside container for live TV recordings                       |
| `MOVIES_FOLDER`            | `/root/SnappierServer/movies`     | Subfolder inside container for downloaded movies                          |
| `SERIES_FOLDER`            | `/root/SnappierServer/series`     | Subfolder inside container for downloaded TV series                       |
| `PVR_FOLDER`               | `/root/SnappierServer/pvr`        | Subfolder inside container for PVR metadata and schedules                 |
| `DOWNLOAD_SPEED_LIMIT_MBS` | `10` (set to `0` to disable)      | Max download speed in MB/s for `curl`                                     |
| `USE_FFMPEG_TO_DOWNLOAD`   | `false`                           | Set to `true` to force using `ffmpeg` for all downloads instead of `curl` |

#### Example with Volume Mounts and Custom Download Settings

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -e ENABLE_REMUX=false \
  -e DOWNLOAD_SPEED_LIMIT_MBS=10 \
  -e USE_FFMPEG_TO_DOWNLOAD=true \
  -v /host/recordings:/root/SnappierServer/recordings \
  -v /host/movies:/root/SnappierServer/movies \
  -v /host/series:/root/SnappierServer/series \
  -v /host/pvr:/root/SnappierServer/pvr \
  ghcr.io/rydizz214/snappier-server:0.0.0s
```

---

## Using Docker Compose

You can manage your Snappier-Server with Docker Compose. Below is an example `docker-compose.yml` that builds (or pulls) the image tagged `0.0.0s` and binds your host folders into the container. Adjust environment options to meet your specific needs.

```yaml
version: "3.8"
services:
  snappier-server:
    image: ghcr.io/rydizz214/snappier-server:0.0.0s
    container_name: snappier-server
    restart: unless-stopped

    ports:
      - "7429:8000"

    environment:
      # API port (container always listens on 8000)
      PORT: "8000"
      # Enable automatic remuxing of .ts → .mkv
      ENABLE_REMUX: "true"
      # Default max download speed for curl (MB/s)
      DOWNLOAD_SPEED_LIMIT_MBS: "10"
      # Set to "true" to use ffmpeg for downloads instead of curl
      USE_FFMPEG_TO_DOWNLOAD: "false"
      # If you want to bind-mount custom folders, uncomment & set below:
      # RECORDINGS_FOLDER: "/root/SnappierServer/recordings"
      # MOVIES_FOLDER: "/root/SnappierServer/movies"
      # SERIES_FOLDER: "/root/SnappierServer/series"
      # PVR_FOLDER: "/root/SnappierServer/pvr"

    volumes:
      - /data/recordings/snappier-server/recordings:/root/SnappierServer/recordings
      - /data/recordings/snappier-server/movies:/root/SnappierServer/movies
      - /data/recordings/snappier-server/series:/root/SnappierServer/series
      - /data/recordings/snappier-server/pvr:/root/SnappierServer/pvr
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

    healthcheck:
      test:
        - "CMD"
        - "curl"
        - "-f"
        - "-X"
        - "GET"
        - "http://127.0.0.1:8000/serverStats"
        - "-H"
        - "Accept: application/json"
      interval: 60s
      timeout: 5s
      retries: 3
      # ⚠️ If you change the exposed host port (7429), update the healthcheck URL accordingly.
```

> **Note:** This Compose setup includes a functional health check that runs every minute against the `/serverStats` endpoint to verify the container is healthy and running.

---

## Volumes

These are the directories inside the container that you can (and should) mount to host paths:

* `/root/SnappierServer/recordings`
* `/root/SnappierServer/movies`
* `/root/SnappierServer/series`
* `/root/SnappierServer/pvr`

Any existing data in these host folders will persist across container restarts.

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
