#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
DOMAIN="gui/$(id -u)"
DEST="$HOME/Library/LaunchAgents"
BACKEND=local.herdr-mobile.backend
CADDY=local.herdr-mobile.caddy
GENERATED="$ROOT/.runtime/launchd"

mkdir -p "$ROOT/.runtime/logs" "$GENERATED" "$DEST"
chmod 700 "$ROOT/.runtime" "$ROOT/.runtime/logs" "$GENERATED"

python3 - "$ROOT" "$GENERATED" <<'PY'
from pathlib import Path
from xml.sax.saxutils import escape
import sys

root = Path(sys.argv[1])
generated = Path(sys.argv[2])
templates = root / "deploy" / "launchd"
for label in ("local.herdr-mobile.backend", "local.herdr-mobile.caddy"):
    text = (templates / f"{label}.plist.in").read_text()
    (generated / f"{label}.plist").write_text(
        text.replace("__HERDR_MOBILE_ROOT__", escape(str(root)))
    )
PY

for label in "$BACKEND" "$CADDY"; do
  plutil -lint "$GENERATED/$label.plist" >/dev/null
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  install -m 600 "$GENERATED/$label.plist" "$DEST/$label.plist"
done

launchctl bootstrap "$DOMAIN" "$DEST/$BACKEND.plist"
launchctl bootstrap "$DOMAIN" "$DEST/$CADDY.plist"

echo "Installed and started $BACKEND and $CADDY."
echo "Run ./scripts/launch-agents-status.sh to verify them."
