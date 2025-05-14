# Snappier-Server Docker

A self-contained Docker setup for running Snappier-Server (ELF binary) with FFmpeg 7.1 on Ubuntu 25.04. It leverages the official `jrottenberg/ffmpeg:7.1-ubuntu` image for prebuilt FFmpeg, auto-acknowledges the initial “I understand” prompt, and includes a health check.

## Features

* Uses the official `jrottenberg/ffmpeg:7.1-ubuntu` Docker image for FFmpeg 7.1
* Downloads and renames the Snappier-Server ELF binary automatically
* Auto-response to initial startup prompt
* Built-in HTTP health check on `/` endpoint
* Persistent storage for recordings via host-mounted volume

## Prerequisites

* Docker ≥ 20.10
* Docker Compose ≥ 1.29
* Git (for cloning this repository)

## Getting Started

1. **Clone the repository**:

   ```bash
   git clone https://github.com/RyDizz214/snappier-server-docker.git
   cd snappier-server-docker
   ```

2. **Build and start the container**:

   ```bash
   docker-compose up -d
   ```

3. **Verify the service**:

   * **API & UI**: [http://localhost:7429](http://localhost:7429)
   * **Recordings** directory on host: `./recordings/`

## Configuration

* **Port**: 7429 (mapped host→container)
* **Recordings paths**:

  * `/data/recordings/snappier-server` (root recordings folder)
  * `/data/recordings/snappier-server/movies` (movies)
  * `/data/recordings/snappier-server/tvseries` (TV series)
* **Health check**:

  * HTTP probe every 30s
  * 10s timeout, 3 retries, 30s startup grace

## File Structure

```
snappier-server-docker/
├── Dockerfile           # Multi-stage FFmpeg build & runtime image
├── entrypoint.sh        # Auto-confirm prompt & launch server
├── docker-compose.yml   # Compose service with ports, volumes, healthcheck
├── .gitignore           # Excludes recordings/ and ZIP files
├── README.md            # Project documentation
└── LICENSE              # MIT License
```

## Updating the Snappier-Server Binary

To bump to a newer Snappier-Server version:

1. Edit the download URL in `Dockerfile` (under `/opt/snappier` stage):

   ```dockerfile
   RUN wget -q https://snappierserver.app/files/snappierServer_full_linux_x86_64_v0XX_beta.zip -O snappier.zip
   ```
2. Rebuild and redeploy:

   ```bash
   docker-compose up -d
   ```

## Contributing

1. Fork this repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m "Add new feature"`)
4. Push to your fork (`git push origin feature/my-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
