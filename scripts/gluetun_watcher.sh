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

# Each entry: gluetun_container:dependent_container[,dependent_container...]:compose_dir
# Multiple dependents (comma-separated) are recreated together — use this when
# several services share the same gluetun netns (e.g. snappier + provider-proxy).
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
  local dependents_csv="${GLUETUN_TO_DEPENDENT[$gluetun]}"
  local compose_dir="${GLUETUN_TO_COMPOSE[$gluetun]}"

  local -a dependents
  IFS=',' read -r -a dependents <<< "$dependents_csv"

  cd "$compose_dir"

  # Stale-check uses the first dependent's container. All services attached to
  # the same gluetun netns go stale together, so checking one is sufficient.
  local first_service="${dependents[0]}"
  local first_container
  first_container=$(docker compose ps -a -q "$first_service" 2>/dev/null | head -n1)

  local current_net gluetun_id
  current_net=$(docker inspect "$first_container" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
  gluetun_id=$(docker inspect "$gluetun" --format '{{.Id}}' 2>/dev/null || echo "unknown")

  if [[ "$current_net" == "container:$gluetun_id" ]]; then
    log "${dependents[*]} already reference the current $gluetun, skipping"
    return 0
  fi

  log "Stale network detected: $first_service has $current_net, $gluetun is $gluetun_id"
  log "Waiting ${SETTLE_DELAY}s for $gluetun to initialize..."
  sleep "$SETTLE_DELAY"

  for i in $(seq 1 24); do
    local health
    health=$(docker inspect "$gluetun" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
      log "$gluetun is healthy, recreating: ${dependents[*]}"
      break
    fi
    log "$gluetun health: $health, waiting... ($i/24)"
    sleep 5
  done

  if docker compose up -d --force-recreate "${dependents[@]}" 2>&1; then
    log "Recreated: ${dependents[*]}"
  else
    log "ERROR: Failed to recreate: ${dependents[*]}"
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
