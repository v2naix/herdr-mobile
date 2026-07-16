#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
TOKEN_FILE="$ROOT/.cloudflare-api-token"
DOMAIN_FILE=${HERDR_MOBILE_DOMAIN_FILE:-$ROOT/.herdr-mobile-domain}
CADDY="$ROOT/.tools/caddy"

if [ -z "${HERDR_MOBILE_DOMAIN:-}" ]; then
  if [ ! -f "$DOMAIN_FILE" ]; then
    echo "Missing domain configuration; copy .herdr-mobile-domain.example to .herdr-mobile-domain." >&2
    exit 2
  fi
  IFS= read -r HERDR_MOBILE_DOMAIN < "$DOMAIN_FILE"
fi
case "$HERDR_MOBILE_DOMAIN" in
  ''|*[!A-Za-z0-9.-]*) echo "Invalid HERDR_MOBILE_DOMAIN." >&2; exit 2 ;;
esac
export HERDR_MOBILE_DOMAIN

if [ ! -x "$CADDY" ]; then
  echo "Missing $CADDY; run ./scripts/build-caddy.sh first." >&2
  exit 2
fi
if [ ! -f "$TOKEN_FILE" ]; then
  echo "Missing $TOKEN_FILE; run ./scripts/store-cloudflare-token.sh in your terminal." >&2
  exit 2
fi

mode=$(stat -f '%Lp' "$TOKEN_FILE")
if [ "$mode" != 600 ]; then
  echo "$TOKEN_FILE must have mode 0600 (currently $mode)." >&2
  exit 2
fi

IFS= read -r CF_API_TOKEN < "$TOKEN_FILE"
if [ -z "$CF_API_TOKEN" ]; then
  echo "$TOKEN_FILE is empty." >&2
  exit 2
fi
export CF_API_TOKEN

umask 077
export XDG_DATA_HOME="$ROOT/.caddy/data"
export XDG_CONFIG_HOME="$ROOT/.caddy/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
chmod 700 "$ROOT/.caddy" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

exec "$CADDY" run --config "$ROOT/deploy/Caddyfile" --adapter caddyfile
