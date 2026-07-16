#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
HOST="${HERDR_MOBILE_HOST:-127.0.0.1}"
PORT="${HERDR_MOBILE_PORT:-8787}"
if [ "$HOST" != "127.0.0.1" ]; then
  echo "Refusing non-loopback bind. Use Tailscale Serve in front of 127.0.0.1." >&2
  exit 2
fi
exec .venv/bin/uvicorn server.app:app --host "$HOST" --port "$PORT" --ws-max-size 8192 --limit-concurrency 32 --no-access-log
