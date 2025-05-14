# ─── STAGE 1: use official FFmpeg 7.1 image ─────────────────────────────────
FROM jrottenberg/ffmpeg:7.1-ubuntu AS ffmpeg-build

# ─── STAGE 2: runtime ───────────────────────────────────────────────────────
FROM ubuntu:25.04

# Copy FFmpeg executables from the prebuilt stage
COPY --from=ffmpeg-build /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg-build /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Install runtime tools for downloading and unpacking Snappier
RUN apt-get update -qq && \
    apt-get install -y ca-certificates wget unzip curl && \
    rm -rf /var/lib/apt/lists/*

# Download and unpack the Snappier-Server ELF binary
WORKDIR /opt/snappier
RUN wget -q \
      https://snappierserver.app/files/snappierServer_full_linux_x86_64_v076_beta.zip \
      -O snappier.zip && \
    unzip snappier.zip && \
    rm snappier.zip && \
    mv snappierServer_full_linux_* snappierServer && \
    chmod +x snappierServer

# Copy the entrypoint script and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose the internal server port
EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
