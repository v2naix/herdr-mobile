#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
export GOPATH="$ROOT/.tools/go"
export GOMODCACHE="$GOPATH/pkg/mod"
export GOCACHE="$ROOT/.tools/go-build-cache"
export GOBIN="$ROOT/.tools/bin"
mkdir -p "$GOBIN" "$GOMODCACHE" "$GOCACHE"

go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.6
"$GOBIN/xcaddy" build v2.11.4 \
  --with github.com/caddy-dns/cloudflare@v0.2.4 \
  --output "$ROOT/.tools/caddy"

"$ROOT/.tools/caddy" list-modules | grep -qx 'dns.providers.cloudflare'
echo "Built $ROOT/.tools/caddy with the Cloudflare DNS module."
