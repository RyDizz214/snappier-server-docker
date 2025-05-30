# syntax=docker/dockerfile

########################################
# Simplified FFmpeg install
########################################
FROM ubuntu:25.04 AS base
ARG TARGETARCH=amd64
ENV TZ="America/New_York" DEBIAN_FRONTEND=noninteractive

# runtime deps + FFmpeg
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata ca-certificates curl bash unzip ffmpeg \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

########################################
# Build final Snappier-Server image   #
########################################
FROM base AS snappier-server
ARG TARGETARCH

# download & install Snappier-Server v0.8.0r CLI
RUN case "$TARGETARCH" in \
      "amd64") PLATFORM="x64" ;; \
      "arm64") PLATFORM="arm64" ;; \
      *) echo "❌ Unsupported ARCH: $TARGETARCH" >&2 && exit 1 ;; \
    esac \
 && ASSET="snappier-server-cli-v0.8.0r-linux-${PLATFORM}.zip" \
 && curl -fSL "https://snappierserver.app/files/${ASSET}" -o /tmp/snappier.zip \
 && mkdir -p /opt/snappier-server \
 && unzip -q /tmp/snappier.zip -d /opt/snappier-server \
 && mv /opt/snappier-server/snappier-server-cli-* /opt/snappier-server/snappier-server \
 && chmod +x /opt/snappier-server/snappier-server \
 && ln -sf /opt/snappier-server/snappier-server /usr/local/bin/snappier-server \
 && rm /tmp/snappier.zip \
 && echo "✅ Snappier-Server v0.8.0r installed!"

# data dirs & expose port
RUN mkdir -p /root/SnappierServer/{Recordings,Movies,Series,PVR}
VOLUME ["/root/SnappierServer/recordings","/root/SnappierServer/movies","/root/SnappierServer/series","/root/SnappierServer/pvr"]
WORKDIR /root/SnappierServer
EXPOSE 8000

# default env vars (override with -e)
ENV PORT=7429:8000 \
    ENABLE_REMUX=true \
    RECORDINGS_FOLDER=/root/SnappierServer/recordings \
    MOVIES_FOLDER=/root/SnappierServer/movies \
    SERIES_FOLDER=/root/SnappierServer/series \
    PVR_FOLDER=/root/SnappierServer/pvr \
    DOWNLOAD_SPEED_LIMIT_MBS=5

ENTRYPOINT ["snappier-server"]
