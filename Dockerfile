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
#     --push -t ghcr.io/<you>/snappier-server:2.0.4-9 .       # multi-arch publish
########################################

ARG SNAPPIER_SERVER_VERSION=2.0.4-9
ARG USE_HOST_FFMPEG=false

########################################
# Stage 1: Build FFmpeg and codec libraries from source
# (BuildKit skips this entirely when USE_HOST_FFMPEG=true)
########################################
FROM ubuntu:26.04 AS ffmpeg-build

ARG DEBIAN_FRONTEND=noninteractive
# Pinned rather than "latest" so a release builds the same FFmpeg every time.
# 9.0.1 is the version this image's ffmpeg-wrapper.sh is tested against
# (it ran in production through the host-FFmpeg overlay before this pin).
# Setting FFMPEG_VERSION=latest restores resolving the newest stable tarball.
ARG FFMPEG_VERSION=9.0.1

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
# From the maintained upstream, pinned. The github.com/videolan/x265 mirror is
# frozen at 3.5-era sources that CMake 4 (Ubuntu 26.04) refuses to configure.
ARG X265_VERSION=4.2
RUN git clone --depth=1 --branch "${X265_VERSION}" https://bitbucket.org/multicoreware/x265_git.git /tmp/x265 \
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
    echo "Version: ${X265_VERSION}"; \
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

# FFmpeg (pinned via FFMPEG_VERSION above; set it to "latest" to track stable)
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
# Stage 1b: Build Comskip from source
########################################
# Snappier's --enable-comskip expects a comskip binary, but ships none that
# runs here: the upstream desktop bundle links against FFmpeg 4.x shared
# objects that no current container base provides. Build it against this
# base's own FFmpeg packages instead, and install the matching runtime libs
# in the final stage. Built on the same ubuntu:26.04 as runtime-base so the
# libav* ABI agrees.
FROM ubuntu:26.04 AS comskip-build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates build-essential autoconf automake libtool pkg-config \
      libargtable2-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
      libsdl2-dev \
 && rm -rf /var/lib/apt/lists/*

# FFmpeg 8 removed AVCodecContext.ticks_per_frame, which Comskip still uses
# (upstream issue #186). Replace it with what FFmpeg documents as its
# successor: 2 for codecs flagged AV_CODEC_PROP_FIELDS, else 1. MPEG-1 carries
# that flag but Comskip always forced it to 1, so keep that exception. (The
# open upstream PR #187 multiplies by the raw flag bit, 16, which is wrong.)
RUN git clone --depth=1 https://github.com/erikkaashoek/Comskip.git /tmp/comskip \
 && cd /tmp/comskip \
 && sed -i -e '/codec_id == AV_CODEC_ID_MPEG1VIDEO)/{N;/ticks_per_frame = 1;/d}' \
      -e 's/is->dec_ctx->ticks_per_frame/COMSKIP_TICKS_PER_FRAME(is->dec_ctx)/g' \
      -e '/#include <libavcodec\/avcodec.h>/a #define COMSKIP_TICKS_PER_FRAME(c) (((c)->codec_id != AV_CODEC_ID_MPEG1VIDEO \&\& (c)->codec_descriptor \&\& ((c)->codec_descriptor->props \& AV_CODEC_PROP_FIELDS)) ? 2 : 1)' \
      mpeg2dec.c \
 && grep -q '^#define COMSKIP_TICKS_PER_FRAME' mpeg2dec.c \
 && ! grep -n 'TICKS_PER_FRAME(is->dec_ctx) = 1' mpeg2dec.c \
 && ./autogen.sh \
 && ./configure --bindir=/usr/local/bin \
 && make -j"$(nproc)" comskip \
 && install -m 0755 comskip /usr/local/bin/comskip \
 && test -x /usr/local/bin/comskip

########################################
# Stage 2: Common runtime base
########################################
FROM ubuntu:26.04 AS runtime-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    curl jq ca-certificates tzdata tini procps inotify-tools iproute2 coreutils \
    unzip \
    libssl3t64 \
    libxcb1 libxcb-shm0 libxcb-shape0 libxcb-xfixes0 \
    libx11-6 libxext6 libxrender1 libxfixes3 libxi6 libxrandr2 \
    libnuma1 libstdc++6 \
    libass9 libfreetype6 libfribidi0 libharfbuzz0b libfontconfig1 libpng16-16t64 \
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
#
# Upstream publishes under a per-version directory (files/v<VER>/<file>). The
# flat files/<file> form this used to build 404s for every version, so the
# fetch below is the only supported layout — do not "simplify" it back.
# The published .sha256 is verified before the archive is trusted.
RUN set -eux; \
  SNAPPIER_ARCH="$(cat /tmp/snappier_arch)"; \
  ZIP_NAME="snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}.zip"; \
  BASE_URL="https://snappierserver.app/files/v${SNAPPIER_SERVER_VERSION}"; \
  echo "Downloading SnappierServer from: ${BASE_URL}/${ZIP_NAME}"; \
  curl -fsSL -o "/tmp/${ZIP_NAME}" "${BASE_URL}/${ZIP_NAME}"; \
  curl -fsSL -o "/tmp/${ZIP_NAME}.sha256" "${BASE_URL}/${ZIP_NAME}.sha256"; \
  (cd /tmp && sha256sum -c "${ZIP_NAME}.sha256"); \
  mkdir -p /opt/SnappierServer; \
  unzip -q "/tmp/${ZIP_NAME}" -d /opt/SnappierServer; \
  rm -f "/tmp/${ZIP_NAME}" "/tmp/${ZIP_NAME}.sha256"; \
  find /opt/SnappierServer -maxdepth 2 -type f \( -name "*.sh" -o -name "snappier*" -o -name "*.bin" \) -exec chmod +x {} + || true; \
  test -f "/opt/SnappierServer/snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}"; \
  ln -sf "snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-${SNAPPIER_ARCH}" /opt/SnappierServer/snappier-server-cli; \
  test -x /opt/SnappierServer/snappier-server-cli; \
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

# Comskip: the real binary from stage 1b, fronted by a wrapper that rebases
# orphan sidecars as soon as a run finishes. Runtime libav* packages must match
# the ones comskip was compiled against in stage 1b.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libargtable2-0 libavformat62 libavcodec62 libavutil60 libswscale9 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=comskip-build /usr/local/bin/comskip /usr/local/bin/comskip.real
COPY scripts/comskip-wrapper.sh /usr/local/bin/comskip
COPY comskip.ini /usr/local/etc/comskip.ini
# Smoke-test the ABI, not the exit code: comskip exits 2 even for --help, so a
# successful run proves nothing. An unresolved libav* symbol would show up here
# as a "not found" line, which is the failure this stage exists to catch.
RUN chmod +x /usr/local/bin/comskip /usr/local/bin/comskip.real \
 && ldd /usr/local/bin/comskip.real \
 && ! ldd /usr/local/bin/comskip.real | grep -q 'not found'

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
