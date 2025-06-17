########################################
# 1) Base: FFmpeg + Node.js + jq
########################################
FROM ubuntu:25.04 AS base
ARG TARGETARCH
ARG SNAPPIER_SERVER_VERSION=1.0.3
ARG TZ="America/New_York"

ENV SNAPPIER_SERVER_VERSION="${SNAPPIER_SERVER_VERSION}" \
    TZ="${TZ}" \
    DEBIAN_FRONTEND=noninteractive

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

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

########################################
# 2) Snappier-Server builder
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
    ASSET_FILENAME="snappier-server-cli-v${SNAPPIER_SERVER_VERSION}-linux-${PLATFORM}.zip"; \
    ASSET_URL="https://${REPO}/${ASSET_FILENAME}"; \
    curl -fSL "$ASSET_URL" -o /tmp/snappier.zip; \
    unzip -q /tmp/snappier.zip -d /tmp/extracted; \
    mkdir -p "$INSTALL_DIR"; \
    mv /tmp/extracted/* "$INSTALL_DIR/$BIN_NAME"; \
    chmod +x "$INSTALL_DIR/$BIN_NAME"; \
    ln -sf "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/$BIN_NAME; \
    rm -rf /tmp/snappier.zip /tmp/extracted

########################################
# 3) Notification Service builder
########################################
FROM snappier-server AS notifier
ENV NODE_ENV=production
WORKDIR /opt/notification-service

COPY notification-service/package.json notification-service/push-service.js ./
RUN npm install --only=production

########################################
# 4) Final runtime image
########################################
FROM snappier-server AS final

# Copy server binary and notifier service
COPY --from=snappier-server /opt/snappier-server /opt/snappier-server
COPY --from=notifier    /opt/notification-service /opt/notification-service

# Prepare app directory
WORKDIR /root/SnappierServer
RUN mkdir -p Recordings Movies TVSeries PVR

# Copy headless entrypoint
COPY headless-entrypoint.sh /usr/local/bin/headless-entrypoint.sh
RUN chmod +x /usr/local/bin/headless-entrypoint.sh

# Restore notifier client scripts
COPY notification_client.py           /root/SnappierServer/
# COPY notification-client.js         /root/SnappierServer/  # if you use the JS client

# Copy and wire up enhanced-node-notifier & webhook
COPY enhanced-node-notifier.js        /tmp/enhanced-node-notifier.js
COPY snappier-webhook.js              /tmp/snappier-webhook.js

RUN mkdir -p node_modules/node-notifier \
 && cp /tmp/enhanced-node-notifier.js node_modules/node-notifier/index.js \
 && printf '{"name":"node-notifier","version":"10.0.1","main":"index.js"}' > node_modules/node-notifier/package.json \
 \
 && mkdir -p /usr/local/lib/node_modules/node-notifier \
 && cp /tmp/enhanced-node-notifier.js /usr/local/lib/node_modules/node-notifier/index.js \
 && printf '{"name":"node-notifier","version":"10.0.1","main":"index.js"}' > /usr/local/lib/node_modules/node-notifier/package.json \
 \
 && mv /tmp/snappier-webhook.js /root/SnappierServer/snappier-webhook.js \
 && rm /tmp/enhanced-node-notifier.js

# **Correct** ENV block from your revised Dockerfile
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
    PUSHOVER_USER="" \
    PUSHOVER_API="" \
    NTFY_TOPIC="" \
    TELEGRAM_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    DISCORD_WEBHOOK_URL=""

EXPOSE 8000 9080 9081

ENTRYPOINT ["/usr/local/bin/headless-entrypoint.sh"]
