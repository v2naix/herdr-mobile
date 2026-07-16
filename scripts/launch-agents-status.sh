#!/bin/sh
set -eu

DOMAIN="gui/$(id -u)"
for label in local.herdr-mobile.backend local.herdr-mobile.caddy; do
  echo "== $label =="
  launchctl print "$DOMAIN/$label" | grep -E '^\s*(state|pid|last exit code) = ' || true
done

echo "== loopback listeners =="
lsof -nP -iTCP:8787 -sTCP:LISTEN
lsof -nP -iTCP:8443 -sTCP:LISTEN
