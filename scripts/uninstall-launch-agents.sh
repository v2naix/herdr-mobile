#!/bin/sh
set -eu

DOMAIN="gui/$(id -u)"
DEST="$HOME/Library/LaunchAgents"
for label in local.herdr-mobile.backend local.herdr-mobile.caddy; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  rm -f "$DEST/$label.plist"
done

echo "Stopped and removed herdr-mobile LaunchAgents."
