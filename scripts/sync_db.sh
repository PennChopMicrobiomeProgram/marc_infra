#!/bin/sh
set -eu

: "${SOURCE_DB_PATH:?SOURCE_DB_PATH is required}"
: "${LOCAL_DB_PATH:?LOCAL_DB_PATH is required}"
: "${LAST_SYNC_PATH:?LAST_SYNC_PATH is required}"

mkdir -p "$(dirname "$LOCAL_DB_PATH")"
mkdir -p "$(dirname "$LAST_SYNC_PATH")"

if [ ! -r "$SOURCE_DB_PATH" ]; then
  echo "[db-sync] Source database not readable at $SOURCE_DB_PATH" >&2
  exit 1
fi

TMP_PATH="${LOCAL_DB_PATH}.tmp$$"
cp -f "$SOURCE_DB_PATH" "$TMP_PATH"
chmod 0644 "$TMP_PATH"
mv "$TMP_PATH" "$LOCAL_DB_PATH"
SYNC_TIME="$(date '+%Y/%m/%d %H:%M:%S')"
printf '%s\n' "$SYNC_TIME" > "$LAST_SYNC_PATH"
echo "[db-sync] Synced $SYNC_TIME" >&2
