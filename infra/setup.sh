#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then
  api_key="LK$(openssl rand -hex 8)"
  api_secret="$(openssl rand -hex 32)"
  umask 077
  printf 'LIVEKIT_API_KEY=%s\nLIVEKIT_API_SECRET=%s\n' "$api_key" "$api_secret" > .env
fi
set -a
. ./.env
set +a
umask 077
LIVEKIT_NODE_IP=${PAIRDESK_LIVEKIT_NODE_IP:-127.0.0.1}
sed "s/API_KEY_PLACEHOLDER/$LIVEKIT_API_KEY/g; s/API_SECRET_PLACEHOLDER/$LIVEKIT_API_SECRET/g; s/NODE_IP_PLACEHOLDER/$LIVEKIT_NODE_IP/g" livekit.yaml.template > livekit.yaml
echo "Generated development secrets and LiveKit config. Keep .env and livekit.yaml private."
