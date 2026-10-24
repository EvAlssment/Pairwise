#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_COMMIT=${PAIRDESK_BUILD_COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD)}
IMAGE="pairdesk-api-smoke:${BUILD_COMMIT:0:12}"
CONTAINER="pairdesk-api-smoke-$$"
RESPONSE=$(mktemp "${TMPDIR:-/tmp}/pairdesk-api-version.XXXXXX")

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -f "$RESPONSE"
}
trap cleanup EXIT

docker build \
  --build-arg "PAIRDESK_BUILD_COMMIT=$BUILD_COMMIT" \
  --tag "$IMAGE" \
  "$ROOT/server"
docker run --detach --name "$CONTAINER" \
  --publish '127.0.0.1::8080' \
  --env "PAIRDESK_ADDR=0.0.0.0:8080" \
  --env "PAIRDESK_DATA=/data/pairdesk.json" \
  "$IMAGE" >/dev/null
PORT=$(docker port "$CONTAINER" 8080/tcp | awk -F: 'NF { print $NF; exit }')
[[ -n "$PORT" ]] || { echo 'Could not resolve the API container port' >&2; exit 1; }

for attempt in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${PORT}/version" > "$RESPONSE"; then
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    docker logs "$CONTAINER" >&2 || true
    echo 'API image did not become ready for the version check' >&2
    exit 1
  fi
  sleep 1
done

python3 - "$BUILD_COMMIT" "$RESPONSE" <<'PY'
import json
import sys

expected, path = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    response = json.load(source)
assert response == {
    "service": "pairdesk-api",
    "apiProtocol": "v1",
    "buildCommit": expected,
}, response
print(f"API image reports expected build commit {expected}")
PY
