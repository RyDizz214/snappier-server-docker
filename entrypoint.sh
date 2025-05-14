#!/usr/bin/env bash
set -e

# ensure recording directories exist
mkdir -p /data/recordings/snappier-server/movies \
         /data/recordings/snappier-server/tvseries

# auto-confirm and launch the ELF binary on port 8000
printf 'I understand\n' | \
  exec /opt/snappier/snappierServer \
    --host            0.0.0.0 \
    --port            8000 \
    --recordingsFolder /data/recordings/snappier-server \
    --moviesFolder     /data/recordings/snappier-server/movies \
    --tvSeriesFolder   /data/recordings/snappier-server/tvseries \
    --enable-remux
