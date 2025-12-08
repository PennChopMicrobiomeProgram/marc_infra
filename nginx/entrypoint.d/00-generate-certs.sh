#!/bin/sh
set -euo pipefail

DOMAIN="${LETSENCRYPT_DOMAIN:-localhost}"
if [ "$DOMAIN" = "localhost" ] && [ -z "${LETSENCRYPT_DOMAIN:-}" ]; then
    echo "LETSENCRYPT_DOMAIN is not set; bootstrapping a localhost self-signed certificate" >&2
fi

CERT_ROOT="/etc/letsencrypt/live/${DOMAIN}"
FULLCHAIN="${CERT_ROOT}/fullchain.pem"
PRIVKEY="${CERT_ROOT}/privkey.pem"

if [ -s "$FULLCHAIN" ] && [ -s "$PRIVKEY" ]; then
    echo "Existing certificate found for ${DOMAIN}; using it."
    exit 0
fi

echo "Bootstrapping self-signed certificate for ${DOMAIN}..."
LETSENCRYPT_DOMAIN="$DOMAIN"
mkdir -p "$CERT_ROOT"
if ! command -v openssl >/dev/null 2>&1; then
    apk add --no-cache openssl >/dev/null
fi
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
    -subj "/CN=${DOMAIN}" \
    -keyout "$PRIVKEY" \
    -out "$FULLCHAIN" >/dev/null 2>&1
