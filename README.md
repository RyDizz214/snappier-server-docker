# Snappier-Server Docker

A Docker image that packages the Snappier-Server CLI (v0.8.0q) on Ubuntu 25.04 with FFmpeg installed. This multi-stage Dockerfile:

1. **Base stage**: installs runtime dependencies, FFmpeg, and configures timezone.
2. **Snappier-Server stage**: downloads and installs the Snappier-Server CLI binary for your architecture.

---

## Features

* **Snappier-Server CLI v0.8.0q** for Linux (amd64 & arm64)
* **FFmpeg** installed via `apt` for encoding/decoding support
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
  --tag rydizz214/snappier-server:0.8.0q \
  --build-arg TZ="America/New_York" \
  .
```

This creates an image named `rydizz214/snappier-server:0.8.0q` containing:

* `/usr/local/bin/snappier-server` (the CLI)
* FFmpeg binaries in `/usr/bin/ffmpeg` & `/usr/bin/ffprobe`

---

## Running the Container

Run with default settings:

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  rydizz214/snappier-server:0.8.0q
```

### Customizing via Environment Variables

| Variable                   | Default                           | Description                        |
| -------------------------- | --------------------------------- | ---------------------------------- |
| `PORT`                     | `7429:8000`                       | Host\:container port mapping       |
| `ENABLE_REMUX`             | `true`                            | Enable/disable automatic remuxing  |
| `RECORDINGS_FOLDER`        | `/root/SnappierServer/recordings` | Root folder for new recordings     |
| `MOVIES_FOLDER`            | `/root/SnappierServer/movies`     | Subfolder for movie recordings     |
| `SERIES_FOLDER`            | `/root/SnappierServer/series`     | Subfolder for TV series recordings |
| `PVR_FOLDER`               | `/root/SnappierServer/pvr`        | Subfolder for PVR recordings       |
| `DOWNLOAD_SPEED_LIMIT_MBS` | `10`      '0' to disable          | Max download speed in MB/s         |

Example with volume mounts and custom remux setting:

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -e ENABLE_REMUX=false \
  -v /host/recordings:/root/SnappierServer/recordings \
  -v /host/movies:/root/SnappierServer/movies \
  -v /host/series:/root/SnappierServer/series \
  -v /host/pvr:/root/SnappierServer/pvr \
  rydizz214/snappier-server:0.8.0q
```

---

## Using Docker Compose

You can manage your Snappier-Server with Docker Compose. Below is an example `docker-compose.yml` that builds from the local Dockerfile, tags the image per the `SNAPPIER_VERSION` build arg, and binds your host folders into the container. Environment options are **optional** and can be changed to meet your specific needs.

```yaml
services:
  snappier-server:
    build:
      context: .
      args:
        SNAPPIER_VERSION: "0.8.0q"
    image: rydizz214/snappier-server:0.8.0q
    container_name: snappier-server
    restart: unless-stopped

    environment:
      PORT:                     "8000"
      ENABLE_REMUX:             "true"
      RECORDINGS_FOLDER:        "/root/SnappierServer/Recordings"
      MOVIES_FOLDER:            "/root/SnappierServer/Movies"
      SERIES_FOLDER:            "/root/SnappierServer/TVSeries"
      PVR_FOLDER:               "/root/SnappierServer/PVR"
      DOWNLOAD_SPEED_LIMIT_MBS: "10"

    volumes:
      - "/data/recordings/snappier-server/Recordings:/root/SnappierServer/Recordings"
      - "/data/recordings/snappier-server/Movies:/root/SnappierServer/Movies"
      - "/data/recordings/snappier-server/TVSeries:/root/SnappierServer/TVSeries"
      - "/data/recordings/snappier-server/PVR:/root/SnappierServer/PVR"
      - "/etc/localtime:/etc/localtime:ro"
      - "/etc/timezone:/etc/timezone:ro"

    ports:
      - "7429:8000"

    healthcheck:
      test: [
        "CMD",
        "curl", "-f", "-X", "GET",
        "http://127.0.0.1:8000/serverStats",
        "-H", "Accept: application/json"
      ]
      interval: 60s
      timeout: 5s
      retries: 3
      # ⚠️ If you change API_PORT from 8000, update the URL here.
```

> **Note:** This Compose setup includes a functional health check that runs every minute against the `/serverStats` endpoint to verify the container is healthy and running.

## Volumes

The Dockerfile declares these volumes so you can mount host paths:

* `/root/SnappierServer/recordings`
* `/root/SnappierServer/movies`
* `/root/SnappierServer/series`
* `/root/SnappierServer/pvr`

Any existing data in these host folders will be visible inside the container.

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
