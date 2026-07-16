#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
TOKEN_FILE=.cloudflare-api-token

if [ -e "$TOKEN_FILE" ]; then
  echo "$TOKEN_FILE already exists; refusing to overwrite it." >&2
  exit 2
fi

trap 'stty echo 2>/dev/null || true; unset token' EXIT HUP INT TERM
printf 'Cloudflare API Token (input hidden): ' >&2
stty -echo
IFS= read -r token
stty echo
printf '\n' >&2

if [ -z "$token" ]; then
  echo "Token must not be empty." >&2
  exit 2
fi

umask 077
printf '%s\n' "$token" > "$TOKEN_FILE"
unset token
chmod 600 "$TOKEN_FILE"
echo "Stored $TOKEN_FILE with mode 0600."
