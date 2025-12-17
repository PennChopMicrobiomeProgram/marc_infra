#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Stand up the full marc stack (db-sync, production, development, and nginx) on a fresh machine.

Usage: bootstrap_full_stack.sh \
  --prod-image <image[:tag]> \
  --prod-pool <pool-name> \
  --dev-image <image[:tag]> \
  --dev-pool <pool-name> \
  --nfs-db-path <absolute-nfs-sqlite-path> \
  --openai-key <api-key> \
  --compose-bin <binary>

All flags are required. There are no defaults.

Examples:
  bootstrap_full_stack.sh \
    --prod-image ctbushman/marc_web:1.0.0 \
    --prod-pool prod-20240925 \
    --dev-image ctbushman/marc_web:1.0.0-dev \
    --dev-pool dev-20240925 \
    --nfs-db-path /mnt/isilon/marc_genomics/marc_web_db_RO/marc.sqlite \
    --openai-key sk-123 \
    --compose-bin podman-compose
USAGE
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

PROD_IMAGE=""
PROD_POOL=""
DEV_IMAGE=""
DEV_POOL=""
NFS_DB_PATH=""
OPENAI_API_KEY_VALUE=""
COMPOSE_BIN=""
APP_NETWORK="marc_appnet"
LOG_DIR="/var/log/marc"
DATA_DIR="$ROOT_DIR/data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod-image)
      PROD_IMAGE="$2"; shift 2 ;;
    --prod-pool)
      PROD_POOL="$2"; shift 2 ;;
    --dev-image)
      DEV_IMAGE="$2"; shift 2 ;;
    --dev-pool)
      DEV_POOL="$2"; shift 2 ;;
    --nfs-db-path)
      NFS_DB_PATH="$2"; shift 2 ;;
    --openai-key)
      OPENAI_API_KEY_VALUE="$2"; shift 2 ;;
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

: "${PROD_IMAGE:?--prod-image is required}"
: "${PROD_POOL:?--prod-pool is required}"
: "${DEV_IMAGE:?--dev-image is required}"
: "${DEV_POOL:?--dev-pool is required}"
: "${NFS_DB_PATH:?--nfs-db-path is required}"
: "${OPENAI_API_KEY_VALUE:?--openai-key is required}"
: "${COMPOSE_BIN:?--compose-bin is required}"

for bin in "$COMPOSE_BIN" podman envsubst; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Required binary '$bin' not found" >&2
    exit 1
  fi
done

if [[ ! -d "$LOG_DIR" ]]; then
  echo "Creating log directory at $LOG_DIR..."
  mkdir -p "$LOG_DIR"
fi

echo "Ensuring data directory at $DATA_DIR..."
mkdir -p "$DATA_DIR"

echo "Ensuring shared app network '$APP_NETWORK' exists..."
if ! podman network inspect "$APP_NETWORK" >/dev/null 2>&1; then
  podman network create "$APP_NETWORK" >/dev/null
fi

echo "Starting db-sync stack..."
MARC_NFS_DB_PATH="$NFS_DB_PATH" "$COMPOSE_BIN" -f db-sync/docker-compose.yaml up -d

echo "Starting production pool '$PROD_POOL' with image '$PROD_IMAGE'..."
MARC_PROD_POOL="$PROD_POOL" MARC_PROD_IMAGE="$PROD_IMAGE" OPENAI_API_KEY="$OPENAI_API_KEY_VALUE" \
  "$COMPOSE_BIN" -f prod/docker-compose.yaml -p "marc-${PROD_POOL}" up -d

echo "Starting development pool '$DEV_POOL' with image '$DEV_IMAGE'..."
MARC_DEV_POOL="$DEV_POOL" MARC_DEV_IMAGE="$DEV_IMAGE" OPENAI_API_KEY="$OPENAI_API_KEY_VALUE" \
  "$COMPOSE_BIN" -f dev/docker-compose.yaml -p "marc-${DEV_POOL}" up -d

echo "Rendering nginx configuration..."
nginx_template="$ROOT_DIR/nginx/nginx.conf.template"
nginx_conf="$ROOT_DIR/nginx/nginx.conf"
MARC_PROD_POOL="$PROD_POOL" MARC_DEV_POOL="$DEV_POOL" \
  envsubst '$MARC_PROD_POOL $MARC_DEV_POOL' < "$nginx_template" > "$nginx_conf"

echo "Starting nginx..."
"$COMPOSE_BIN" -f nginx/docker-compose.yaml up -d

echo "Bootstrap complete."
