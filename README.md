# Snappier-Server Docker

A Docker image that packages the Snappier-Server CLI (v0.8.0v) on Ubuntu 25.04 with FFmpeg installed. This multi-stage Dockerfile:

1. **Base stage**: installs runtime dependencies, FFmpeg (7.1.1), and configures timezone.
2. **Snappier-Server stage**: downloads and installs the Snappier-Server CLI binary for your architecture (v0.8.0v).

---

## Features

* **Snappier-Server CLI v0.8.0v** for Linux (amd64 & arm64)
* **FFmpeg 7.1.1** installed via `apt` for encoding/decoding support
* **Timezone support** (default `America/New_York`, override via `TZ` build arg)
* **Exposed HTTP port 8000** for API/UI
* **Persistent volumes** for Recordings, Movies, TVSeries, and PVR
* **Default environment variables** for ports, remuxing, folder locations, and download rate

---

## Prerequisites

* Docker Engine ≥ 20.10
* (Optional) Build argument `TARGETARCH` if you need to cross-build

---

## Building the Image

From the project root (where the Dockerfile lives), run:

```bash
docker build \
  --build-arg TZ="America/New_York" \
  --build-arg SNAPPIER_VERSION=0.8.0v \
  -t ghcr.io/rydizz214/snappier-server-docker:0.8.0v \
  .
```

* `--build-arg SNAPPIER_VERSION=0.8.0v` tells the Dockerfile to fetch v0.8.0v of the CLI.
* `-t ghcr.io/rydizz214/snappier-server-docker:0.8.0v` tags the final image exactly as `0.8.0v`.

> **Tip:** If you previously pulled or built `snappier-server-docker:0.8.0t`, you can remove it first to avoid confusion:
>
> ```bash
> docker rmi ghcr.io/rydizz214/snappier-server-docker:0.8.0t
> ```

---

## Running the Container

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  ghcr.io/rydizz214/snappier-server-docker:0.8.0v
```

* This maps host port 7429 → container port 8000 (where Snappier-Server listens).
* The container will use the default environment variables unless you override them (see next section).

---

## Download Options

By default, Snappier-Server uses `curl` to fetch media segments. We recommend throttling `curl` to **10 MB/s** to avoid potential provider throttling:

```bash
# Example override when running:
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -e DOWNLOAD_SPEED_LIMIT_MBS=10 \
  ghcr.io/rydizz214/snappier-server-docker:0.8.0v
```

If you encounter failed downloads with `curl`, you can force **ffmpeg** to handle the download by setting:

```bash
-e USE_FFMPEG_TO_DOWNLOAD=true
```

> **Note:** `ffmpeg` does not support built-in speed throttling—use with caution if your provider enforces per-stream limits.

---

## Environment Variables

You can override any of the following when you run the container (via `-e` flags):

| Variable                   | Default                           | Description                                                          |
| -------------------------- | --------------------------------- | -------------------------------------------------------------------- |
| `PORT`                     | `8000`                            | Port on which Snappier-Server listens inside the container           |
| `ENABLE_REMUX`             | `true`                            | Automatically remux `.ts` → `.mkv` when a recording finishes         |
| `USE_FFMPEG_TO_DOWNLOAD`   | `false`                           | If `true`, use `ffmpeg` instead of `curl` for media downloads        |
| `RECORDINGS_FOLDER`        | `/root/SnappierServer/Recordings` | Container path for live TV recordings (default)                      |
| `MOVIES_FOLDER`            | `/root/SnappierServer/Movies`     | Container path for downloaded movies                                 |
| `SERIES_FOLDER`            | `/root/SnappierServer/TVSeries`   | Container path for downloaded TV series                              |
| `PVR_FOLDER`               | `/root/SnappierServer/PVR`        | Container path for PVR metadata and schedules                        |
| `DOWNLOAD_SPEED_LIMIT_MBS` | `10` (set to `0` to disable)      | Max download speed in MB/s for `curl` (only applies if using `curl`) |

#### Example with Volume Mounts

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -e DOWNLOAD_SPEED_LIMIT_MBS=10 \
  -e USE_FFMPEG_TO_DOWNLOAD=false \
  -v /host/Recordings:/root/SnappierServer/Recordings \
  -v /host/Movies:/root/SnappierServer/Movies \
  -v /host/TVSeries:/root/SnappierServer/TVSeries \
  -v /host/PVR:/root/SnappierServer/PVR \
  ghcr.io/rydizz214/snappier-server-docker:0.8.0v
```

---

## Using Docker Compose

Below is a sample `docker-compose.yml` that uses the new image tag:

```yaml
version: "3.8"

services:
  snappier-server:
    image: ghcr.io/rydizz214/snappier-server-docker:0.8.0v
    container_name: snappier-server
    restart: unless-stopped

    ports:
      - "7429:8000"

    environment:
      PORT: "8000"
      ENABLE_REMUX: "true"
      DOWNLOAD_SPEED_LIMIT_MBS: "10"
      # Set to 0 to disable or change to preferred rate
      USE_FFMPEG_TO_DOWNLOAD: "false"
      # Set to "true" if you want to use ffmpeg for downloads

      # To override folders, uncomment below:
      # RECORDINGS_FOLDER: "/root/SnappierServer/Recordings"
      # MOVIES_FOLDER: "/root/SnappierServer/Movies"
      # SERIES_FOLDER: "/root/SnappierServer/TVSeries"
      # PVR_FOLDER: "/root/SnappierServer/PVR"

    volumes:
      - /data/recordings/snappier-server/Recordings:/root/SnappierServer/Recordings
      - /data/recordings/snappier-server/Movies:/root/SnappierServer/Movies
      - /data/recordings/snappier-server/TVSeries:/root/SnappierServer/TVSeries
      - /data/recordings/snappier-server/PVR:/root/SnappierServer/PVR
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

    healthcheck:
      test:
        - "CMD"
        - "curl"
        - "-f"
        - "http://127.0.0.1:8000/serverStats"
      interval: 60s
      timeout: 5s
      retries: 3
```

Run with:

```bash
docker-compose up -d
```

---

## Healthcheck

The built-in healthcheck queries:

```
http://127.0.0.1:8000/serverStats
```

If you change the internal `PORT` environment variable, update the healthcheck URL accordingly.

---

## Frequently Asked Questions

**Q1: How do I throttle download speed?**

* Set `DOWNLOAD_SPEED_LIMIT_MBS=10` (or another MB/s value) when running. This only affects `curl`. To disable throttling, set `0`.

**Q2: How do I force ****************`ffmpeg`**************** downloads?**

* Set `USE_FFMPEG_TO_DOWNLOAD=true`. Note: `ffmpeg` does not support built-in speed limits.

**Q3: Why is ****************`PORT`**************** set to ****************`8000`**************** in the Dockerfile?**

* Snappier-Server always listens on port 8000 internally. You map it to any host port with `-p HOST:8000` or in Compose.

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
