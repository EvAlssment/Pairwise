#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
ENV_FILE=${PAIRDESK_TEST_ENV_FILE:-"$ROOT/infra/.env"}
if [ ! -f "$ENV_FILE" ]; then
  echo 'Run infra/setup.sh and start the local LiveKit service first.' >&2
  exit 1
fi
set -a
. "$ENV_FILE"
set +a
mkdir -p .cache
FIXTURE=$(mktemp -d "$ROOT/.cache/call-test.XXXXXX")
PAIRDESK_TEST_PASSWORD=$(openssl rand -hex 24)
PAIRDESK_ADMIN_PASSWORD="$PAIRDESK_TEST_PASSWORD"
PAIRDESK_DATA="$FIXTURE/accounts.json"
export PAIRDESK_ADMIN_PASSWORD PAIRDESK_DATA
API_PID=''
cleanup() {
  if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; wait "$API_PID" 2>/dev/null || true; fi
  rm -rf "$FIXTURE"
}
trap cleanup EXIT HUP INT TERM
(cd server && go build -o "$FIXTURE/api" ./cmd/pairdesk-api && go build -o "$FIXTURE/admin" ./cmd/pairdesk-admin)
for i in 1 2 3 4 5; do
  "$FIXTURE/admin" create-user --name "Integration $i" --email "integration-$i@pairdesk.invalid" >/dev/null
  "$FIXTURE/admin" create-user --name "Direct integration $i" --email "integration-direct-$i@pairdesk.invalid" >/dev/null
  "$FIXTURE/admin" create-user --name "Join integration $i" --email "integration-join-$i@pairdesk.invalid" >/dev/null
done
for i in 1 2 3; do
  "$FIXTURE/admin" create-user --name "Annotation integration $i" --email "integration-annotation-$i@pairdesk.invalid" >/dev/null
done
LIVEKIT_URL=${PAIRDESK_TEST_MEDIA_URL:-ws://127.0.0.1:17880} LIVEKIT_API_URL=${PAIRDESK_TEST_MEDIA_API_URL:-http://127.0.0.1:17880} PAIRDESK_ADDR=127.0.0.1:18081 "$FIXTURE/api" > "$FIXTURE/api.log" 2>&1 &
API_PID=$!
ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:18081/healthz >/dev/null; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then cat "$FIXTURE/api.log" >&2; exit 1; fi
export PAIRDESK_TEST_PASSWORD
PAIRDESK_TEST_API=http://127.0.0.1:18081
export PAIRDESK_TEST_API
TEST_FILTER=${PAIRDESK_TEST_FILTER:-'CallIntegrationTests|DirectCallIntegrationTests|CallFeedbackIntegrationTests|RemoteMuteIntegrationTests|HostCursorIntegrationTests'}
(cd macos && swift test -j 4 --filter "$TEST_FILTER")
echo 'Native call/media integration profiles verified against the selected LiveKit endpoint; synthetic accounts and API cleaned up.'
