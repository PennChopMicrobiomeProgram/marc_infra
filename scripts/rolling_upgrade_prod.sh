#!/usr/bin/env bash
set -euo pipefail

COMPOSE="podman compose"
COMPOSE_FILES=(
  -f compose/common.yaml
  -f compose/prod.yaml
  -f compose/nginx.yaml
)

TARGET_IMAGE="${1:-${MARC_WEB_IMAGE:-ctbushman/marc_web:0.3.7}}"
export MARC_WEB_IMAGE="$TARGET_IMAGE"

wait_for_health() {
  local container_name=$1
  local retries=20
  local delay=3

  echo "Waiting for ${container_name} to become healthy..."
  for ((i=1; i<=retries; i++)); do
    status=$(podman inspect --format '{{.State.Health.Status}}' "$container_name" 2>/dev/null || true)
    if [[ "$status" == "healthy" ]]; then
      echo "${container_name} is healthy."
      return 0
    fi
    sleep "$delay"
  done

  echo "${container_name} did not become healthy after $((retries * delay))s" >&2
  return 1
}

upgrade_service() {
  local service=$1
  echo "Updating ${service} to image ${TARGET_IMAGE}..."
  ${COMPOSE} "${COMPOSE_FILES[@]}" pull "$service"
  ${COMPOSE} "${COMPOSE_FILES[@]}" up -d --no-deps --force-recreate "$service"
  wait_for_health "$service"
}

upgrade_service marc-web-prod-b
upgrade_service marc-web-prod-a

${COMPOSE} "${COMPOSE_FILES[@]}" ps
