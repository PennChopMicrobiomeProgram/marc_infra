#!/bin/sh

# Usage: sudo upgrade_prod.sh
# This is intended to be a utility for zero-downtime upgrades
# For dev you can just upgrade manually in place, it doesn't matter
# The concept here is to stand up a new pool of production containers
# with the new image, switch nginx to point to them, and then
# remove the old pool.
#
# YOU MUST UPDATE THE .env FILE TO POINT TO THE NEW POOL FIRST.
#
# Best case, this is an easy way of managing the site such that no one
# will ever notice downtime.
#
# Worst case, bring it all down and then stand it back up as quickly 
# as you can. Should take a minute or two at most if done right.
echo "Starting production upgrade..."
set -euo pipefail

### Preparation and validation ###
# Load environment variables
if [ ! -f .env ]; then
  echo ".env file not found!" >&2
  exit 1
fi

source .env

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Get .env info
IMAGE=$MARC_PROD_IMAGE
POOL=$MARC_PROD_POOL

if [ -z "$IMAGE" ] || [ -z "$POOL" ]; then
  echo "MARC_PROD_IMAGE and MARC_PROD_POOL must be set in .env"
  exit 1
fi

# Ensure nginx config file exists
nginx_conf="nginx/nginx.conf"
nginx_template="nginx/nginx.conf.template"

if [[ ! -f "$nginx_conf" ]]; then
  echo "Missing nginx config at $nginx_conf" >&2
  exit 1
fi

if [[ ! -f "$nginx_template" ]]; then
  echo "Missing nginx template at $nginx_template" >&2
  exit 1
fi

# Ensure the new pool is not the same as the current pool
current_pool=$(grep -oE 'marc-web-([A-Za-z0-9_.-]+):80' "$nginx_conf" | head -n1 | sed -E 's/marc-web-([A-Za-z0-9_.-]+):80/\1/')
if [[ -z "$current_pool" ]]; then
  echo "Could not determine the current production pool from $nginx_conf" >&2
  exit 1
fi

if [[ "$POOL" == "$current_pool" ]]; then
  echo "The new pool ($POOL) must be different from the current pool ($current_pool)" >&2
  exit 1
fi

### Stand up new production pool ###
echo "Standing up new production pool '$POOL' with image '$IMAGE'..."

podman-compose -f prod/docker-compose.yaml up -d

# Check that the new containers are healthy
echo "Waiting 30 seconds then checking that containers are healthy..."
sleep 30
# TODO

### Switch nginx to new pool ###
echo "Switching nginx to new production pool '$POOL'..."
envsubst '\$MARC_PROD_POOL \$MARC_DEV_POOL' < "$nginx_template" > "$nginx_conf"
podman exec nginx nginx -t
podman exec nginx nginx -s reload

### Tear down old production pool ###
echo "Tearing down old production pool '$current_pool'..."
podman-compose -f prod/docker-compose.yaml down -v --remove-orphans