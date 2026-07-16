#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
DOMAIN_FILE=${HERDR_MOBILE_DOMAIN_FILE:-$ROOT/.herdr-mobile-domain}

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

export HERDR_MOBILE_ALLOWED_ORIGINS="https://$HERDR_MOBILE_DOMAIN:8443"
export HERDR_MOBILE_COOKIE_SECURE=1
exec ./scripts/start.sh
