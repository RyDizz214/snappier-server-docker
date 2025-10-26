# ============================================================================
# Snappier Server Docker Image
# - Builds FFmpeg from source with common codecs (x264, x265, fdk-aac, libvpx, opus)
# - Pulls the Snappier CLI artifact and wraps ffmpeg with custom logic
# - Provides notification helpers (Flask webhook + node shim)
# ============================================================================

ARG SNAPPIER_SERVER_VERSION=1.3.4a
ARG SNAPPIER_SERVER_ARCH=linux-x64
ARG FFMPEG_VERSION=latest

# ----------------------------------------------------------------------------
# Stage 1: Build FFmpeg and codec libraries from source
# ----------------------------------------------------------------------------
FROM ubuntu:25.04 AS ffmpeg-build

ARG DEBIAN_FRONTEND=noninteractive
ARG FFMPEG_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates wget unzip xz-utils grep coreutils \
    build-essential pkg-config autoconf automake cmake libtool \
    yasm nasm meson ninja-build \
    libfreetype6-dev libass-dev libfontconfig1-dev libunistring-dev libnuma-dev \
    libfribidi-dev libharfbuzz-dev \
    libssl-dev \
    libx11-dev libxext-dev libxfixes-dev libxi-dev libxrender-dev libxrandr-dev \
 && rm -rf /var/lib/apt/lists/*

# x264 (static)
RUN git clone --depth=1 https://code.videolan.org/videolan/x264.git /tmp/x264 \
 && cd /tmp/x264 \
 && ./configure --prefix=/usr/local --enable-static --enable-pic \
 && make -j"$(nproc)" && make install

# x265 (static) + pkg-config metadata
RUN git clone --depth=1 https://github.com/videolan/x265.git /tmp/x265 \
 && cd /tmp/x265/build/linux \
 && cmake -G "Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DENABLE_SHARED=OFF \
    ../../source \
 && make -j"$(nproc)" && make install \
 && mkdir -p /usr/local/lib/pkgconfig \
 && { \
    echo 'prefix=/usr/local'; \
    echo 'exec_prefix=${prefix}'; \
    echo 'libdir=${exec_prefix}/lib'; \
    echo 'includedir=${prefix}/include'; \
    echo ''; \
    echo 'Name: x265'; \
    echo 'Description: H.265/HEVC video encoder'; \
    echo 'Version: 3.5'; \
    echo 'Libs: -L${libdir} -lx265 -lstdc++ -lm -lpthread -ldl -lnuma'; \
    echo 'Cflags: -I${includedir}'; \
 } > /usr/local/lib/pkgconfig/x265.pc \
 && ldconfig

# fdk-aac (static)
RUN git clone --depth=1 https://github.com/mstorsjo/fdk-aac.git /tmp/fdk-aac \
 && cd /tmp/fdk-aac && autoreconf -fiv \
 && ./configure --prefix=/usr/local --disable-shared \
 && make -j"$(nproc)" && make install

# libvpx (static)
RUN git clone --depth=1 https://chromium.googlesource.com/webm/libvpx /tmp/libvpx \
 && cd /tmp/libvpx \
 && ./configure --prefix=/usr/local --disable-examples --disable-unit-tests --enable-vp9-highbitdepth \
 && make -j"$(nproc)" && make install

# opus (static)
RUN git clone --depth=1 https://github.com/xiph/opus.git /tmp/opus \
 && cd /tmp/opus && ./autogen.sh \
 && ./configure --prefix=/usr/local --disable-shared \
 && make -j"$(nproc)" && make install

# FFmpeg (latest stable or overridden via FFMPEG_VERSION)
RUN set -eux; \
  if [ "${FFMPEG_VERSION}" = "latest" ]; then \
    FFMPEG_TARBALL="$(curl -fsSL https://ffmpeg.org/releases/ | grep -Eo 'ffmpeg-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' | grep -vE 'rc|git' | sort -V | tail -1)"; \
  else \
    FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"; \
  fi; \
  echo "Selected FFmpeg: ${FFMPEG_TARBALL}"; \
  curl -fsSLo "/tmp/${FFMPEG_TARBALL}" "https://ffmpeg.org/releases/${FFMPEG_TARBALL}"; \
  mkdir -p /tmp/ffmpeg && tar -xf "/tmp/${FFMPEG_TARBALL}" -C /tmp/ffmpeg --strip-components=1; \
  cd /tmp/ffmpeg; \
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"; \
  ./configure \
    --prefix=/usr/local \
    --pkg-config-flags="--static" \
    --extra-cflags="-I/usr/local/include" \
    --extra-ldflags="-L/usr/local/lib" \
    --extra-libs="-lpthread -lm -ldl -lnuma" \
    --bindir=/usr/local/bin \
    --enable-gpl --enable-nonfree \
    --enable-openssl \
    --enable-libx264 --enable-libx265 --enable-libfdk_aac \
    --enable-libvpx --enable-libopus --enable-libass --enable-libfreetype \
    --disable-debug --disable-doc; \
  make -j"$(nproc)" && make install && hash -r

# ----------------------------------------------------------------------------
# Stage 2: Runtime image
# ----------------------------------------------------------------------------
FROM ubuntu:25.04

ARG DEBIAN_FRONTEND=noninteractive
ARG SNAPPIER_SERVER_VERSION
ARG SNAPPIER_SERVER_ARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    nodejs npm \
    curl jq ca-certificates tzdata tini dumb-init procps iproute2 inotify-tools \
    unzip tar xz-utils \
    libssl3 \
    libxcb1 libxcb-shm0 libxcb-shape0 libxcb-xfixes0 \
    libx11-6 libxext6 libxrender1 libxfixes3 libxi6 libxrandr2 \
    libnuma1 libstdc++6 \
    libass9 libfreetype6 libfribidi0 libharfbuzz0b libfontconfig1 libpng16-16 \
    fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

# Configure system timezone to match TZ environment variable
# This ensures applications that read /etc/localtime get the correct timezone
RUN ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime \
 && echo "America/New_York" > /etc/timezone

# Bring FFmpeg toolchain from build stage
COPY --from=ffmpeg-build /usr/local /usr/local

# Python dependencies used by helper scripts
RUN python3 -m pip install --no-cache-dir --break-system-packages flask requests watchdog

WORKDIR /opt
RUN mkdir -p /logs /root/SnappierServer/epg /root/SnappierServer

# Download Snappier CLI artifact
RUN set -eux; \
  APP_URL="https://snappierserver.app/betaFiles/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_SERVER_ARCH}.zip"; \
  echo "Downloading SnappierServer from: ${APP_URL}"; \
  curl -fsSL -o /tmp/snappier.zip "${APP_URL}"; \
  mkdir -p /opt/SnappierServer; \
  unzip -q /tmp/snappier.zip -d /opt/SnappierServer; \
  rm -f /tmp/snappier.zip; \
  find /opt/SnappierServer -maxdepth 2 -type f \( -name "*.sh" -o -name "snappier*" -o -name "*.bin" \) -exec chmod +x {} + || true; \
  if [ -f "/opt/SnappierServer/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_SERVER_ARCH}" ]; then \
    ln -sf "snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_SERVER_ARCH}" /opt/SnappierServer/snappier-server-cli; \
  fi; \
  if [ -f /opt/SnappierServer/package.json ]; then (cd /opt/SnappierServer && (npm ci || npm install)); fi; \
  if [ -f /opt/SnappierServer/requirements.txt ]; then python3 -m pip install --no-cache-dir --break-system-packages -r /opt/SnappierServer/requirements.txt; fi; \
  ln -sf /opt/SnappierServer /root/SnappierServer

ENV SNAPPIER_ARTIFACT_URL="https://snappierserver.app/betaFiles/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_SERVER_ARCH}.zip" \
    SNAPPIER_ARTIFACT_FILE="snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_SERVER_ARCH}.zip"

RUN echo "artifact_url=${SNAPPIER_ARTIFACT_URL}" > /opt/SnappierServer/.artifact_info \
 && echo "artifact_file=${SNAPPIER_ARTIFACT_FILE}" >> /opt/SnappierServer/.artifact_info \
 && echo "version=${SNAPPIER_SERVER_VERSION}" >> /opt/SnappierServer/.artifact_info \
 && echo "arch=${SNAPPIER_SERVER_ARCH}" >> /opt/SnappierServer/.artifact_info \
 && echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /opt/SnappierServer/.artifact_info

# Notification webhook + helper scripts
COPY notify/ /opt/notify/
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh /opt/notify/*.py || true

# FFmpeg wrapper: preserve original binary
RUN mv /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg.real
COPY ffmpeg-wrapper.sh /usr/local/bin/ffmpeg
RUN chmod +x /usr/local/bin/ffmpeg \
 && ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg \
 && ln -sf /usr/local/bin/ffmpeg.real /usr/bin/ffmpeg.real \
 && ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe

# Entrypoint sequence
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default environment variables
ENV TZ=America/New_York \
    PORT=8000 \
    HOST_PORT=7429 \
    NOTIFICATION_HTTP_PORT=9080 \
    NOTIFICATION_WS_PORT=0 \
    NOTIFICATION_SSE_PATH=/events \
    USE_CURL_TO_DOWNLOAD=false \
    DOWNLOAD_SPEED_LIMIT_MBS=0 \
    SNAP_LOG_FILE="/root/SnappierServer/server.log" \
    EPG_CACHE="/root/SnappierServer/epg/epg_cache.json" \
    SCHEDULES="/root/SnappierServer/Recordings/schedules.json" \
    ALLOW_HTTP=0 \
    ALLOW_HTTP_HOSTS="localhost,127.0.0.1,snappier-server" \
    HTTPS_PROBE_TIMEOUT=3 \
    HTTPS_PROBE_METHOD="HEAD" \
    NOTIFY_TITLE_PREFIX="🎬 Snappier" \
    SNAPPY_API_BASE="http://127.0.0.1:8000" \
    SNAPPY_API_TIMEOUT=5 \
    NOTIFY_DESC_LIMIT=900 \
    HEALTH_INTERVAL_SEC=30 \
    HEALTH_FAIL_THRESHOLD=3 \
    HEALTH_WARN_COOLDOWN_SEC=300 \
    HEALTH_HTTP_TIMEOUT=5 \
    HEALTH_EXPECT_MIN=200 \
    HEALTH_EXPECT_MAX=399 \
    HEALTH_WARN_ON_RECOVERY=0 \
    HEALTH_NOTIFY_URL="http://127.0.0.1:9080/notify" \
    HEALTH_ENDPOINT="/serverStats"

EXPOSE 8000 9080

# Simple healthcheck against the Snappier HTTP endpoint
HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/serverStats" || exit 1

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/usr/local/bin/entrypoint.sh"]
