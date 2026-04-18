#!/usr/bin/env bash
########################################
# gluetun_watcher.sh
#
# Watches for Docker container start events on any gluetun sidecar.
# When gluetun is recreated (e.g. by Watchtower), containers using
# network_mode: container:<id> get a stale reference. This script
# detects the event and recreates the dependent container.
#
# Intended to run as a systemd service on the host.
########################################

set -euo pipefail

SETTLE_DELAY=10  # seconds to wait for gluetun to fully initialize

# Each entry: gluetun_container:dependent_container:compose_dir
PAIRS=(
  "snappier-gluetun:snappier-server:/opt/snappier-server"
  "uhf-gluetun:uhf-server:/opt/uhf-server-docker"
  "gluetun-vpn:stremio-server:/opt/stremio-server"
)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Build a lookup from gluetun container name to its pair info
declare -A GLUETUN_TO_DEPENDENT
declare -A GLUETUN_TO_COMPOSE
for pair in "${PAIRS[@]}"; do
  IFS=: read -r gluetun dependent compose_dir <<< "$pair"
  GLUETUN_TO_DEPENDENT["$gluetun"]="$dependent"
  GLUETUN_TO_COMPOSE["$gluetun"]="$compose_dir"
done

reconcile() {
  local gluetun="$1"
  local dependent="${GLUETUN_TO_DEPENDENT[$gluetun]}"
  local compose_dir="${GLUETUN_TO_COMPOSE[$gluetun]}"

  # Check if dependent is running with a stale network reference
  local current_net gluetun_id
  current_net=$(docker inspect "$dependent" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
  gluetun_id=$(docker inspect "$gluetun" --format '{{.Id}}' 2>/dev/null || echo "unknown")

  if [[ "$current_net" == "container:$gluetun_id" ]]; then
    log "$dependent already references the current $gluetun container, skipping"
    return 0
  fi

  log "Stale network detected: $dependent has $current_net, $gluetun is $gluetun_id"
  log "Waiting ${SETTLE_DELAY}s for $gluetun to initialize..."
  sleep "$SETTLE_DELAY"

  # Wait up to 120s for gluetun healthcheck to pass
  for i in $(seq 1 24); do
    local health
    health=$(docker inspect "$gluetun" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
      log "$gluetun is healthy, recreating $dependent..."
      break
    fi
    log "$gluetun health: $health, waiting... ($i/24)"
    sleep 5
  done

  # Recreate dependent container
  cd "$compose_dir"
  if docker compose up -d --force-recreate "$dependent" 2>&1; then
    log "$dependent recreated successfully"
    local new_net
    new_net=$(docker inspect "$dependent" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
    log "New network mode: $new_net"
  else
    log "ERROR: Failed to recreate $dependent"
  fi
}

# Build filter args for docker events
FILTER_ARGS=()
for gluetun in "${!GLUETUN_TO_DEPENDENT[@]}"; do
  FILTER_ARGS+=(--filter "container=$gluetun")
done

log "Watching for gluetun start events: ${!GLUETUN_TO_DEPENDENT[*]}"

docker events \
  "${FILTER_ARGS[@]}" \
  --filter "event=start" \
  --format '{{.Actor.Attributes.name}} {{.Time}} {{.Action}}' |
while read -r container_name timestamp action; do
  log "Detected $container_name $action event (ts=$timestamp)"

  if [[ -n "${GLUETUN_TO_DEPENDENT[$container_name]+x}" ]]; then
    reconcile "$container_name"
  else
    log "Unknown container $container_name, ignoring"
  fi
done
