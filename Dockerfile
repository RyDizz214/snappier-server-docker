########################################
# 1) Base: FFmpeg + Node.js + jq
########################################
FROM ubuntu:25.04 AS base
ARG TARGETARCH
ARG SNAPPIER_SERVER_VERSION=1.0.0
ENV SNAPPIER_SERVER_VERSION="${SNAPPIER_SERVER_VERSION}"
ARG TZ="America/New_York"
ENV TZ="${TZ}"
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata \
      ca-certificates \
      curl \
      bash \
      unzip \
      ffmpeg \
      jq \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

########################################
# 1.5) Install Node.js
########################################
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

########################################
# 2) Snappier-Server: download & install
########################################
FROM base AS snappier-server
ARG TARGETARCH
ARG SNAPPIER_SERVER_VERSION

RUN set -eux; \
    REPO="snappierserver.app/files"; \
    INSTALL_DIR="/opt/snappier-server"; \
    BIN_NAME="snappier-server"; \
    case "$TARGETARCH" in \
      amd64) PLATFORM="x64";; \
      arm64) PLATFORM="arm64";; \
      *) echo "❌ Unsupported architecture: $TARGETARCH" >&2; exit 1;; \
    esac; \
    echo "🔖 Installing Snappier-Server v${SNAPPIER_SERVER_VERSION} for ${PLATFORM}…"; \
    ASSET_FILENAME="snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-linux-${PLATFORM}.zip"; \
    ASSET_URL="https://${REPO}/${ASSET_FILENAME}"; \
    echo "📥 Downloading from: $ASSET_URL"; \
    TMP_DIR=$(mktemp -d); \
    curl -fSL "$ASSET_URL" -o "$TMP_DIR/snappier.zip"; \
    echo "📦 Unzipping archive…"; \
    unzip -q "$TMP_DIR/snappier.zip" -d "$TMP_DIR/extracted"; \
    mkdir -p "$INSTALL_DIR"; \
    mv "$TMP_DIR/extracted/"* "$INSTALL_DIR/$BIN_NAME"; \
    chmod +x "$INSTALL_DIR/$BIN_NAME"; \
    ln -sf "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/$BIN_NAME; \
    rm -rf "$TMP_DIR"; \
    echo "✅ Snappier-Server v${SNAPPIER_SERVER_VERSION} installed!"

########################################
# 3) Notification Service
########################################
FROM snappier-server AS notifier
ENV NODE_ENV=production
RUN mkdir -p /opt/notification-service
WORKDIR /opt/notification-service
COPY notification-service/package.json notification-service/push-service.js ./
RUN npm install --only=production

########################################
# 4) Final stage: runtime image
########################################
FROM snappier-server AS final
COPY --from=snappier-server /opt/snappier-server /opt/snappier-server
COPY --from=notifier /opt/notification-service /opt/notification-service

WORKDIR /root/SnappierServer
RUN mkdir -p Recordings Movies TVSeries PVR

# Default env vars (override via env_file)
ENV PORT=8000 \
    ENABLE_REMUX=true \
    USE_CURL_TO_DOWNLOAD=false \
    RECORDINGS_FOLDER=/root/SnappierServer/Recordings \
    MOVIES_FOLDER=/root/SnappierServer/Movies \
    SERIES_FOLDER=/root/SnappierServer/TVSeries \
    PVR_FOLDER=/root/SnappierServer/PVR \
    DOWNLOAD_SPEED_LIMIT_MBS=0 \
    NOTIFICATION_HTTP_PORT=9080 \
    NOTIFICATION_WS_PORT=9081 \
    PUSHOVER_USER_KEY="" \
    PUSHOVER_API_TOKEN="" \
    NTFY_TOPIC="" \
    TELEGRAM_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    DISCORD_WEBHOOK_URL=""

# Entrypoint & server start
COPY headless-entrypoint.sh /usr/local/bin/headless-entrypoint.sh
RUN chmod +x /usr/local/bin/headless-entrypoint.sh

EXPOSE 8000 9080 9081

ENTRYPOINT ["/usr/local/bin/headless-entrypoint.sh"]
CMD ["/opt/snappier-server"]
