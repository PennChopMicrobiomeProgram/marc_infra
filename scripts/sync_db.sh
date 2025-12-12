#!/bin/sh
set -eu

log() {
  echo "[db-sync] $*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

: "${SOURCE_DB_PATH:?SOURCE_DB_PATH is required}"
: "${LOCAL_DB_PATH:?LOCAL_DB_PATH is required}"
: "${LAST_SYNC_PATH:?LAST_SYNC_PATH is required}"

mkdir -p "$(dirname "$LOCAL_DB_PATH")"
mkdir -p "$(dirname "$LAST_SYNC_PATH")"

log "Starting sync from $SOURCE_DB_PATH to $LOCAL_DB_PATH"

if [ ! -r "$SOURCE_DB_PATH" ]; then
  fail "Source database not readable at $SOURCE_DB_PATH"
fi

TMP_PATH="$(mktemp "${LOCAL_DB_PATH}.tmp.XXXXXX")"
trap 'rm -f "$TMP_PATH"' EXIT
cp -f "$SOURCE_DB_PATH" "$TMP_PATH" || fail "Failed to copy database"
chmod 0644 "$TMP_PATH" || fail "Failed to set permissions on temporary file"
mv "$TMP_PATH" "$LOCAL_DB_PATH" || fail "Failed to move temporary database into place"
SYNC_TIME="$(date '+%Y/%m/%d %H:%M:%S')"
printf '%s\n' "$SYNC_TIME" > "$LAST_SYNC_PATH" || fail "Failed to write last sync timestamp to $LAST_SYNC_PATH"
log "Synced successfully at $SYNC_TIME"
