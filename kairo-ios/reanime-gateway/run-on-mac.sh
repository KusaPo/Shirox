#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_CLI=$(command -v tailscale)
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TAILSCALE_CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale
else
  echo 'Install Tailscale on your Mac and sign in before running this script.' >&2
  exit 1
fi
export TAILSCALE_BE_CLI=1
DNS_NAME=$("$TAILSCALE_CLI" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
if [ -z "$DNS_NAME" ]; then
  echo 'Connect Tailscale on the Mac first.' >&2
  exit 1
fi
if [ ! -f .gateway-env ]; then
  umask 077
  node -e 'const c=require("node:crypto");process.stdout.write(`GATEWAY_SECRET=${c.randomBytes(32).toString("hex")}\nGATEWAY_ACCESS_KEY=${c.randomBytes(24).toString("hex")}\n`)' > .gateway-env
fi
set -a
# Generated keys contain only hex; do not put shell commands in this file.
. ./.gateway-env
set +a
export PUBLIC_ORIGIN="https://$DNS_NAME"
export HOST=127.0.0.1
npm ci
"$TAILSCALE_CLI" serve --bg 8080
printf '\nGateway URL for Kairo: %s\nGateway access key: %s\n' "$PUBLIC_ORIGIN" "$GATEWAY_ACCESS_KEY"
echo 'Keep this Terminal window open while testing playback or downloading.'
exec node server.mjs
