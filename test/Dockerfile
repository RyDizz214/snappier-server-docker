# syntax=docker/dockerfile

########################################
# 1) Base: Ubuntu 25.04 + stock FFmpeg, tzdata, etc.
########################################
FROM ubuntu:25.04 AS base
ARG TARGETARCH=amd64
ENV TZ="America/New_York" DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies + FFmpeg
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata \
      ca-certificates \
      curl \
      bash \
      unzip \
      ffmpeg \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

########################################
# 2) Final stage: copy in your local Snappier-Server CLI
########################################
FROM base AS snappier-server
ARG TARGETARCH

# Create the directory where we’ll stash the binary
RUN mkdir -p /opt/snappier-server

# Copy the locally built snappier-server (from the current directory) into /opt
# (Because our build context is this folder, "snappier-server" refers to ./snappier-server)
COPY snappier-server /opt/snappier-server/snappier-server

# Make it executable and symlink so ENTRYPOINT can just call "snappier-server"
RUN chmod +x /opt/snappier-server/snappier-server \
 && ln -sf /opt/snappier-server/snappier-server /usr/local/bin/snappier-server \
 && echo "✅ Snappier-Server (local) installed!"

# Create the data directories and declare them as volumes
RUN mkdir -p /root/SnappierServer/{Recordings,Movies,TVSeries,PVR}
VOLUME ["/root/SnappierServer/Recordings","/root/SnappierServer/Movies","/root/SnappierServer/TVSeries","/root/SnappierServer/PVR"]

WORKDIR /root/SnappierServer
EXPOSE 8000

# Default environment variables (you can override via docker-compose or CLI)
ENV LOG_LEVEL=debug \
    PORT=7429:8000 \
    USE_FFMPEG_TO_DOWNLOAD=true \
    ENABLE_REMUX=true \
    RECORDINGS_FOLDER=/root/SnappierServer/Recordings \
    MOVIES_FOLDER=/root/SnappierServer/Movies \
    SERIES_FOLDER=/root/SnappierServer/Series \
    PVR_FOLDER=/root/SnappierServer/PVR \
    DOWNLOAD_SPEED_LIMIT_MBS=0

# When the container runs, this is what it executes
ENTRYPOINT ["snappier-server"]
