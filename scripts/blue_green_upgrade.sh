#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/blue_green_upgrade.sh <new_image_tag> [--auto-promote]

Stages a blue/green upgrade using the dev pool first, then promotes to prod.

Steps:
  1) Updates MARC_WEB_DEV_TAG in .env and redeploys marc-web-dev-*.
  2) Waits for dev containers to report healthy.
  3) Promotes to prod by updating MARC_WEB_PROD_TAG (optionally waits for user confirmation).
  4) Rolling-redeploys prod containers and waits for them to be healthy.

Options:
  --auto-promote   Skip the confirmation prompt before promoting to prod.

Environment:
  ENV_FILE   Override path to the env file (default: ./.env). If missing,
             the script copies .env.example to .env.
USAGE
}

command -v podman-compose >/dev/null 2>&1 || {
  echo "podman-compose is required to run this script" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  echo "Run this script with sudo so it can manage containers" >&2
  exit 1
fi

if [[ -z "${SUDO_USER:-}" ]]; then
  echo "SUDO_USER is not set. Run with sudo from your user account so NFS mounts stay accessible." >&2
  exit 1
fi

RUN_AS_USER="$SUDO_USER"

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

NEW_TAG="$1"
AUTO_PROMOTE=false
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-promote)
      AUTO_PROMOTE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

ENV_FILE="${ENV_FILE:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
  else
    echo "$ENV_FILE is missing and .env.example not found; aborting" >&2
    exit 1
  fi
fi

set_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file"; then
    # Replace existing line
    perl -pi -e "s/^${key}=.*/${key}=${value}/" "$file"
  else
    echo "${key}=${value}" >>"$file"
  fi
}

run_compose() {
  # Ensure podman-compose runs as the invoking user so NFS permissions are preserved.
  sudo -u "$RUN_AS_USER" -E env "MARC_WEB_DEV_TAG=${MARC_WEB_DEV_TAG:-}" "MARC_WEB_PROD_TAG=${MARC_WEB_PROD_TAG:-}" \
    podman-compose --env-file "$ENV_FILE" "$@"
}

redeploy_services() {
  local services=("$@")
  run_compose stop "${services[@]}" || true
  run_compose rm -f "${services[@]}" || true
  run_compose up -d "${services[@]}"
}

wait_for_health() {
  local service="$1" retries=20
  while (( retries > 0 )); do
    status=$(sudo -u "$RUN_AS_USER" podman inspect -f '{{.State.Health.Status}}' "$service" 2>/dev/null || echo "unknown")
    if [[ "$status" == "healthy" ]]; then
      return 0
    fi
    sleep 5
    ((retries--))
  done
  echo "Service $service did not become healthy in time" >&2
  return 1
}

echo "Staging new image tag $NEW_TAG to dev pool..."
set_env_var MARC_WEB_DEV_TAG "$NEW_TAG" "$ENV_FILE"
MARC_WEB_DEV_TAG="$NEW_TAG" redeploy_services marc-web-dev-a marc-web-dev-b
wait_for_health marc-web-dev-a
wait_for_health marc-web-dev-b
echo "Dev pool healthy on tag $NEW_TAG. Validate via /dev/."

if [[ "$AUTO_PROMOTE" != true ]]; then
  read -r -p "Press Enter to promote to prod (Ctrl+C to abort)..."
fi

PREVIOUS_PROD_TAG=$(grep -E '^MARC_WEB_PROD_TAG=' "$ENV_FILE" | sed 's/^MARC_WEB_PROD_TAG=//')
echo "Promoting to prod (previous tag: ${PREVIOUS_PROD_TAG:-unset})..."
set_env_var MARC_WEB_PROD_TAG "$NEW_TAG" "$ENV_FILE"
MARC_WEB_PROD_TAG="$NEW_TAG" redeploy_services marc-web-prod-a marc-web-prod-b nginx
wait_for_health marc-web-prod-a
wait_for_health marc-web-prod-b

echo "Prod pool is healthy on tag $NEW_TAG."
if [[ -n "$PREVIOUS_PROD_TAG" && "$PREVIOUS_PROD_TAG" != "$NEW_TAG" ]]; then
  echo "Rollback hint: MARC_WEB_PROD_TAG=$PREVIOUS_PROD_TAG podman-compose up -d marc-web-prod-a marc-web-prod-b"
fi
