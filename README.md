# Snappier-Server Docker


A Dockerized Snappier-Server setup with automatic remux of `.ts` recordings to `.mkv` using FFmpeg. This image bundles Ubuntu 25.04, system FFmpeg (v7.1.1), timezone data, and your local SnappierServer ELF binary.

## Contents

* **Dockerfile**: Defines the image with:

  * Ubuntu 25.04 base
  * `ffmpeg` and `tzdata` installed via `apt`
  * Timezone set to **America/New\_York**
  * Local `snappierServer` ELF binary copied into `/opt/snappier`
  * `entrypoint.sh` that launches `snappierServer` with `--enable-remux`
* **entrypoint.sh**: Auto-completes the acknowledgement prompt and `exec`s the server binary.
* **snappierServer\_full\_linux\_x86\_64\_v0.77c\_beta**: The SnappierServer ELF binary *you* download and place alongside this Dockerfile.
* **docker-compose.yml** (optional): Example Compose file to run the container, mount your recordings folder, and expose port 7429.

## Prerequisites

* Docker & Docker Compose installed on your host.
* A downloaded copy of the x86\_64 SnappierServer ELF:

  1. Visit [https://snappierserver.app/files/](https://snappierserver.app/files/)
  2. Download **snappierServer\_full\_linux\_x86\_64\_v0.77c\_beta.zip**
  3. Unzip so you have a file named:

     ```
     snappierServer_full_linux_x86_64_v0.77c_beta
     ```
  4. Move that file into this project directory (next to `Dockerfile`):

     ```bash
     mv snappierServer_full_linux_x86_64_v0.77c_beta ./
     chmod +x snappierServer_full_linux_x86_64_v0.77c_beta
     ```

## Running the Container

### Standalone `docker run`

```bash
docker run -d \
  --name snappier-server \
  -p 7429:8000 \
  -v /data/recordings/snappier-server:/data/recordings/snappier-server \
  -v /etc/localtime:/etc/localtime:ro \
  ghcr.io/rydizz214/snappier-server:v1.1.0
```

### Using Docker Compose

```yaml
version: "3.8"
services:
  snappier-server:
    image: ghcr.io/rydizz214/snappier-server:v1.1.0
    container_name: snappier-server-docker
    ports:
      - "7429:8000"
    volumes:
      - "/data/recordings/snappier-server:/data/recordings/snappier-server"
      - "/etc/localtime:/etc/localtime:ro"
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:8000 >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

```bash
docker compose up -d
```

## Usage & Verification

1. **Verify remux flag**

   ```bash
   docker exec -it snappier-server-docker \
     sh -c "tr '�' ' ' < /proc/1/cmdline; echo"
   ```

   Confirm you see `--enable-remux` in the command line.

2. **Check the output**

   ```bash
   ls -lh /data/recordings/snappier-server/*.mkv
   ```

## License

This project and Dockerfile are provided under the MIT License. See [LICENSE](LICENSE).
