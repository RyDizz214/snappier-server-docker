########################################
# Unified Snappier Server Dockerfile
#
# Build modes:
#   USE_HOST_FFMPEG=false (default) - builds FFmpeg from source (publishable image)
#   USE_HOST_FFMPEG=true            - skips FFmpeg build (local dev, host-mounted)
#
# Multi-arch: uses TARGETARCH from buildx (amd64|arm64) to fetch matching Snappier CLI.
#
# Examples:
#   docker compose build                                    # built-in ffmpeg, native arch
#   docker compose build --build-arg USE_HOST_FFMPEG=true   # host ffmpeg (x86-64 only)
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --push -t ghcr.io/<you>/snappier-server:1.5.0 .       # multi-arch publish
########################################

ARG SNAPPIER_SERVER_VERSION=1.5.0
ARG USE_HOST_FFMPEG=false

########################################
# Stage 1: Build FFmpeg and codec libraries from source
# (BuildKit skips this entirely when USE_HOST_FFMPEG=true)
########################################
FROM ubuntu:25.04 AS ffmpeg-build

ARG DEBIAN_FRONTEND=noninteractive
ARG FFMPEG_VERSION=latest

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

# FFmpeg (latest stable by default; override via FFMPEG_VERSION=8.1 etc.)
#
# FFMPEG_REFRESH is a cache-bust token. When FFMPEG_VERSION=latest, set this to
# the current date (e.g. in CI: --build-arg FFMPEG_REFRESH=$(date +%Y%m%d)) so
# Docker re-resolves the latest tarball instead of reusing a stale cached layer.
ARG FFMPEG_REFRESH=1
RUN set -eux; \
  echo "FFMPEG_REFRESH=${FFMPEG_REFRESH} FFMPEG_VERSION=${FFMPEG_VERSION}"; \
  if [ "${FFMPEG_VERSION}" = "latest" ]; then \
    FFMPEG_TARBALL="$(curl -fsSL https://ffmpeg.org/releases/ | grep -Eo 'ffmpeg-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' | grep -vE 'rc|git' | sort -V | uniq | tail -1)"; \
  else \
    FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"; \
  fi; \
  if [ -z "${FFMPEG_TARBALL}" ]; then echo "Failed to resolve FFmpeg tarball" >&2; exit 1; fi; \
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

########################################
# Stage 2: Common runtime base
########################################
FROM ubuntu:25.04 AS runtime-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    curl jq ca-certificates tzdata tini procps inotify-tools iproute2 coreutils \
    unzip \
    libssl3 \
    libxcb1 libxcb-shm0 libxcb-shape0 libxcb-xfixes0 \
    libx11-6 libxext6 libxrender1 libxfixes3 libxi6 libxrandr2 \
    libnuma1 libstdc++6 \
    libass9 libfreetype6 libfribidi0 libharfbuzz0b libfontconfig1 libpng16-16 \
    fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

# Timezone is set at runtime by entrypoint.sh from the TZ env var — no default baked in.

########################################
# Stage 3a: Built-in FFmpeg (published image)
########################################
FROM runtime-base AS runtime-false

COPY --from=ffmpeg-build /usr/local /usr/local
RUN mv /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg.real \
 && ln -sf /usr/local/bin/ffmpeg.real /usr/bin/ffmpeg.real \
 && ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe

########################################
# Stage 3b: Host FFmpeg (local dev)
########################################
FROM runtime-base AS runtime-true

RUN mkdir -p /usr/local/bin \
 && ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg \
 && ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe

########################################
# Stage 4: Final image
########################################
FROM runtime-${USE_HOST_FFMPEG} AS final

ARG DEBIAN_FRONTEND=noninteractive
ARG SNAPPIER_SERVER_VERSION
ARG TARGETARCH

# Map Docker's TARGETARCH (amd64/arm64) to Snappier's artifact arch (linux-x64/linux-arm64).
# Allows `docker buildx build --platform linux/amd64,linux/arm64` to fetch the right CLI.
RUN case "${TARGETARCH:-amd64}" in \
      amd64) echo "linux-x64" > /tmp/snappier_arch ;; \
      arm64) echo "linux-arm64" > /tmp/snappier_arch ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac

# Python dependencies for webhook and helper scripts
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    fastapi uvicorn[standard] httpx aiofiles requests watchdog

WORKDIR /opt
RUN mkdir -p /logs /root/SnappierServer/epg /root/SnappierServer /opt/certs

# Download Snappier CLI artifact (per-arch via buildx TARGETARCH)
RUN set -eux; \
  SNAPPIER_ARCH="$(cat /tmp/snappier_arch)"; \
  APP_URL="https://snappierserver.app/files/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}.zip"; \
  echo "Downloading SnappierServer from: ${APP_URL}"; \
  curl -fsSL -o /tmp/snappier.zip "${APP_URL}"; \
  mkdir -p /opt/SnappierServer; \
  unzip -q /tmp/snappier.zip -d /opt/SnappierServer; \
  rm -f /tmp/snappier.zip; \
  find /opt/SnappierServer -maxdepth 2 -type f \( -name "*.sh" -o -name "snappier*" -o -name "*.bin" \) -exec chmod +x {} + || true; \
  if [ -f "/opt/SnappierServer/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}" ]; then \
    ln -sf "snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}" /opt/SnappierServer/snappier-server-cli; \
  fi; \
  ln -sf /opt/SnappierServer /root/SnappierServer; \
  echo '{}' > /opt/SnappierServer/config.json; \
  { \
    echo "version=${SNAPPIER_SERVER_VERSION}"; \
    echo "arch=${SNAPPIER_ARCH}"; \
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
  } > /opt/SnappierServer/.artifact_info

# Notification webhook + helper scripts
COPY notify/enhanced_webhook.py notify/tmdb_helper.py /opt/notify/
COPY scripts/health_watcher.py scripts/log_monitor.sh scripts/metadata_fixer.py scripts/timestamp_helpers.py scripts/xtream_cache.py /opt/scripts/
RUN chmod +x /opt/scripts/*.sh 2>/dev/null || true

# FFmpeg wrapper (becomes /usr/local/bin/ffmpeg, calls ffmpeg.real under the hood)
COPY ffmpeg-wrapper.sh /usr/local/bin/ffmpeg
RUN chmod +x /usr/local/bin/ffmpeg \
 && ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default environment variables (TZ intentionally unset — set via .env)
ENV PORT=8000 \
    NOTIFICATION_HTTP_PORT=9080 \
    NOTIFICATION_SSE_PATH=/events \
    NOTIFY_TITLE_PREFIX="Snappier" \
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

HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/8000' || exit 1

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/usr/local/bin/entrypoint.sh"]
