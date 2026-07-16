#!/bin/sh
set -eu
if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found; on macOS it may need to be invoked from the Tailscale app bundle." >&2
  exit 1
fi
cat <<'EOF'
The backend must already be running on 127.0.0.1:8787.
Also start it with HERDR_MOBILE_ALLOWED_ORIGINS set to the exact HTTPS URL shown by Tailscale Serve.
EOF
exec tailscale serve --bg http://127.0.0.1:8787
