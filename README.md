# Snappier-Server Docker

A Docker image that packages the Snappier-Server CLI (v0.0.0t) on Ubuntu 25.04 with FFmpeg installed. This multi-stage Dockerfile:

1. **Base stage**: installs runtime dependencies, FFmpeg (7.1.1), and configures timezone.
2. **Snappier-Server stage**: downloads and installs the Snappier-Server CLI binary for your architecture (v0.0.0t).

---

## Features

* **Snappier-Server CLI v0.0.0t** for Linux (amd64 & arm64)
* **FFmpeg 7.1.1** installed via `apt` for encoding/decoding support
* **Timezone support** (default `America/New_York`, override via `TZ` build arg)
* **Exposed HTTP port 8000** for API/UI
* **Persistent volumes** for Recordings, Movies, Series, and PVR
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
  --build-arg SNAPPIER_VERSION=0.0.0t \
  -t ghcr.io/rydizz214/snappier-server-docker:0.0.0t \
  .
```

* `--build-arg SNAPPIER_VERSION=0.0.0t` tells the Dockerfile to fetch v0.0.0t of the CLI.
* `-t ghcr.io/rydizz214/snappier-server-docker:0.0.0t` tags the final image exactly as `0.0.0t`.

> **Tip:** If you previously pulled or built `snappier-server-docker:0.0.0r`, you can remove it first to avoid confusion:
>
> ```bash
> docker rmi ghcr.io/rydizz214/snappier-server-docker:0.0.0r
> ```

---

## Running the Container

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  ghcr.io/rydizz214/snappier-server-docker:0.0.0t
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
  ghcr.io/rydizz214/snappier-server-docker:0.0.0t
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
| `RECORDINGS_FOLDER`        | `/root/SnappierServer/recordings` | Container path for live TV recordings (default)                      |
| `RECORDINGS_FOLDER`        | `/root/SnappierServer/recordings` | Container path for live TV recordings (default)                      |
| `MOVIES_FOLDER`            | `/root/SnappierServer/movies`     | Container path for downloaded movies                                 |
| `SERIES_FOLDER`            | `/root/SnappierServer/series`     | Container path for downloaded TV series                              |
| `PVR_FOLDER`               | `/root/SnappierServer/pvr`        | Container path for PVR metadata and schedules                        |
| `DOWNLOAD_SPEED_LIMIT_MBS` | `10` (set to `0` to disable)      | Max download speed in MB/s for `curl` (only applies if using `curl`) |

#### Example with Volume Mounts

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -e DOWNLOAD_SPEED_LIMIT_MBS=10 \
  -e USE_FFMPEG_TO_DOWNLOAD=false \
  -v /host/recordings:/root/SnappierServer/recordings \
  -v /host/movies:/root/SnappierServer/movies \
  -v /host/series:/root/SnappierServer/series \
  -v /host/pvr:/root/SnappierServer/pvr \
  ghcr.io/rydizz214/snappier-server-docker:0.0.0t
```

---

## Using Docker Compose

Below is a sample `docker-compose.yml` that uses the new image tag:

```yaml
version: "3.8"

services:
  snappier-server:
    image: ghcr.io/rydizz214/snappier-server-docker:0.0.0t
    container_name: snappier-server
    restart: unless-stopped

    ports:
      - "7429:8000"

    environment:
      PORT: "8000"
      ENABLE_REMUX: "true"
      DOWNLOAD_SPEED_LIMIT_MBS: "10"
      USE_FFMPEG_TO_DOWNLOAD: "false"  
      # Set to "true" if you want to use ffmpeg for downloads
      
      # To override folders, uncomment below:
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

**Q2: How do I force ************`ffmpeg`************ downloads?**

* Set `USE_FFMPEG_TO_DOWNLOAD=true`. Note: `ffmpeg` does not support built-in speed limits.

**Q3: Why is ************`PORT`************ set to ************`8000`************ in the Dockerfile?**

* Snappier-Server always listens on port 8000 internally. You map it to any host port with `-p HOST:8000` or in Compose.

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
