#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Upgrade the production marc_web pool with zero downtime by standing up a new pool,
switching nginx to it, and removing the old pool.

Usage: upgrade_prod_pool.sh --image <image[:tag]> [--pool <pool-name>] [--dev-pool <dev-pool>]
                            [--timeout <seconds>] [--compose-bin <binary>]

  --image        Required. Container image (with tag) to deploy to the new pool.
  --pool         Optional. Pool name suffix to use for the new containers
                 (default: prod-<sanitized image tag>).
  --dev-pool     Optional. Current dev pool name referenced by nginx (default: dev).
  --timeout      Optional. Seconds to wait for the new containers to become healthy
                 before aborting (default: 300).
  --compose-bin  Optional. Compose binary to run (default: podman-compose).
  -h, --help     Show this help message.

Examples:
  upgrade_prod_pool.sh --image ctbushman/marc_web:0.3.8
  upgrade_prod_pool.sh --image ctbushman/marc_web:0.3.8 --pool prod-blue
USAGE
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

NEW_IMAGE=""
NEW_POOL=""
MARC_DEV_POOL="${MARC_DEV_POOL:-dev}"
TIMEOUT=300
COMPOSE_BIN=${COMPOSE_BIN:-podman-compose}
APP_NETWORK="marc_appnet"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      NEW_IMAGE="$2"; shift 2 ;;
    --pool)
      NEW_POOL="$2"; shift 2 ;;
    --dev-pool)
      MARC_DEV_POOL="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --compose-bin)
      COMPOSE_BIN="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$NEW_IMAGE" ]]; then
  echo "--image is required" >&2
  usage
  exit 1
fi

for bin in "$COMPOSE_BIN" podman envsubst; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Required binary '$bin' not found" >&2
    exit 1
  fi
done

nginx_conf="$ROOT_DIR/nginx/nginx.conf"
nginx_template="$ROOT_DIR/nginx/nginx.conf.template"

if [[ ! -f "$nginx_conf" ]]; then
  echo "Missing nginx config at $nginx_conf" >&2
  exit 1
fi

if [[ ! -f "$nginx_template" ]]; then
  echo "Missing nginx template at $nginx_template" >&2
  exit 1
fi

current_pool=$(grep -oE 'marc-web-([A-Za-z0-9_.-]+)-a:80' "$nginx_conf" | head -n1 | sed -E 's/marc-web-([A-Za-z0-9_.-]+)-a:80/\1/')
current_pool=${current_pool:-prod}

if [[ -z "$NEW_POOL" ]]; then
  tag_part=${NEW_IMAGE##*:}
  tag_part=${tag_part:-latest}
  safe_tag=$(echo "$tag_part" | tr '/:@' '-' | tr -cd '[:alnum:]-')
  if [[ -z "$safe_tag" ]]; then
    safe_tag="v$(date +%Y%m%d%H%M%S)"
  fi
  NEW_POOL="prod-${safe_tag}"
fi

if [[ "$NEW_POOL" == "$current_pool" ]]; then
  echo "New pool ($NEW_POOL) matches current pool ($current_pool); choose a different name." >&2
  exit 1
fi

ensure_network() {
  local network="$1"
  if ! podman network inspect "$network" >/dev/null 2>&1; then
    echo "Creating shared app network '$network'..."
    podman network create "$network" >/dev/null
  fi
}

connect_pool_to_network() {
  local pool_name="$1"
  local network="$2"
  local containers=("marc-web-${pool_name}-a" "marc-web-${pool_name}-b")
  for c in "${containers[@]}"; do
    if ! podman inspect -f '{{range $name,$v := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$c" 2>/dev/null | grep -qx "$network"; then
      echo "Connecting $c to network $network..."
      podman network connect "$network" "$c"
    fi
  done
}

start_pool() {
  local pool_name="$1"
  local image="$2"
  echo "Starting new pool '$pool_name' with image '$image'..."
  MARC_POOL="$pool_name" MARC_WEB_IMAGE="$image" "$COMPOSE_BIN" -f prod/docker-compose.yaml -p "marc-${pool_name}" up -d
}

healthy_or_wait() {
  local pool_name="$1"
  local deadline=$((SECONDS + TIMEOUT))
  local containers=("marc-web-${pool_name}-a" "marc-web-${pool_name}-b")
  echo "Waiting for ${containers[*]} to become healthy (timeout ${TIMEOUT}s)..."
  while (( SECONDS < deadline )); do
    local unhealthy=0
    for c in "${containers[@]}"; do
      status=$(podman inspect -f '{{ .State.Health.Status }}' "$c" 2>/dev/null || echo "missing")
      if [[ "$status" != "healthy" ]]; then
        unhealthy=1
        echo "  $c status: $status"
      fi
    done
    if (( unhealthy == 0 )); then
      echo "All containers are healthy."
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for new pool to become healthy" >&2
  return 1
}

render_nginx() {
  local pool_name="$1"
  echo "Updating nginx to target pool '$pool_name'..."
  MARC_PROD_POOL="$pool_name" MARC_DEV_POOL="$MARC_DEV_POOL" \
    envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < "$nginx_template" > "$nginx_conf"
}

reload_nginx() {
  echo "Reloading nginx configuration..."
  "$COMPOSE_BIN" -f nginx/docker-compose.yaml up -d
  podman exec nginx nginx -t
  podman exec nginx nginx -s reload
}

verify_pool_reachable_via_nginx() {
  local pool_name="$1"
  local targets=("marc-web-${pool_name}-a" "marc-web-${pool_name}-b")
  echo "Verifying nginx can reach the new pool (${targets[*]})..."
  for t in "${targets[@]}"; do
    echo "  Checking http://${t}:80/health"
    if ! podman exec nginx wget -qO- --timeout=5 "http://${t}:80/health" >/dev/null; then
      echo "  Failed to reach ${t} via nginx" >&2
      return 1
    fi
  done
}

remove_pool() {
  local pool_name="$1"
  echo "Removing old pool '$pool_name'..."
  MARC_POOL="$pool_name" "$COMPOSE_BIN" -f prod/docker-compose.yaml -p "marc-${pool_name}" down
}

ensure_network "$APP_NETWORK"
start_pool "$NEW_POOL" "$NEW_IMAGE"
connect_pool_to_network "$NEW_POOL" "$APP_NETWORK"
healthy_or_wait "$NEW_POOL"
render_nginx "$NEW_POOL"
reload_nginx

if ! verify_pool_reachable_via_nginx "$NEW_POOL"; then
  echo "New pool is not reachable from nginx; rolling back to $current_pool" >&2
  render_nginx "$current_pool"
  reload_nginx
  remove_pool "$NEW_POOL"
  exit 1
fi

if [[ -n "$current_pool" ]]; then
  remove_pool "$current_pool"
fi

echo "Upgrade complete. Active production pool: $NEW_POOL"
