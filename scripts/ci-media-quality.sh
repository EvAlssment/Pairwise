#!/bin/sh
# Run the same synthetic media and cursor quality gate used by CI on every
# release candidate. This intentionally requires a disposable GitHub macOS
# runner because the constrained profile temporarily changes PF/dummynet.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$(uname -s)" != Darwin ] || [ "${CI:-}" != true ]; then
  echo 'ci-media-quality.sh is restricted to disposable macOS CI runners.' >&2
  exit 2
fi

: "${RUNNER_TEMP:?GitHub Actions RUNNER_TEMP is required}"
: "${GITHUB_WORKSPACE:?GitHub Actions GITHUB_WORKSPACE is required}"

export PAIRDESK_BENCHMARK_COMMIT=${PAIRDESK_BENCHMARK_COMMIT:-${GITHUB_SHA:-unknown}}
export PAIRDESK_BENCHMARK_RUN_ID=${PAIRDESK_BENCHMARK_RUN_ID:-${GITHUB_RUN_ID:-unknown}}
export PAIRDESK_TEST_FILTER=${PAIRDESK_TEST_FILTER:-'CallIntegrationTests/testOneToOneSyntheticScreenQualityProfile|CallIntegrationTests/testFourNativeClientsCameraPublicationAndExclusiveScreenPermission|HostCursorIntegrationTests/testSharerRelaysAnIndependentViewerCursorToOtherParticipants|HostCursorIntegrationTests/testAuthenticatedCursorPacketsShowNamesOnHostAndClearWithTheShare|ScreenClipboardIntegrationTests'}

BENCHMARK_DIR=${PAIRDESK_MEDIA_BENCHMARK_DIR:-"$RUNNER_TEMP/pairdesk-media-quality"}
MEDIA_OUTPUT="$BENCHMARK_DIR/pairwise-media-benchmark.json"
CONDITION_REPORT="$BENCHMARK_DIR/network-conditioner.json"
LIVEKIT_BIN_DIR="$RUNNER_TEMP/livekit-bin"
LIVEKIT_SERVER="$LIVEKIT_BIN_DIR/server"
LIVEKIT_LOG="$RUNNER_TEMP/pairdesk-livekit.log"

mkdir -p "$BENCHMARK_DIR" "$LIVEKIT_BIN_DIR"
GOBIN="$LIVEKIT_BIN_DIR" go install github.com/livekit/livekit-server/cmd/server@v1.8.4
test -x "$LIVEKIT_SERVER" || { echo 'Pinned LiveKit test server was not installed.' >&2; exit 1; }

NODE_INTERFACE=$(route -n get default | awk '/interface:/{print $2; exit}')
NODE_IP=$(ipconfig getifaddr "$NODE_INTERFACE")
test -n "$NODE_IP" || { echo 'Could not determine the macOS runner IP.' >&2; exit 1; }
PAIRDESK_LIVEKIT_NODE_IP="$NODE_IP" sh infra/setup.sh

"$LIVEKIT_SERVER" --config infra/livekit.yaml > "$LIVEKIT_LOG" 2>&1 &
MEDIA_PID=$!
cleanup() {
  kill "$MEDIA_PID" 2>/dev/null || true
  wait "$MEDIA_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ready=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:7880 >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  cat "$LIVEKIT_LOG" >&2
  echo 'Pinned LiveKit test server did not become ready.' >&2
  exit 1
fi

export PAIRDESK_MEDIA_BENCHMARK_OUTPUT="$MEDIA_OUTPUT"
export PAIRDESK_NETWORK_CONDITION_REPORT="$CONDITION_REPORT"
export PAIRDESK_TEST_MEDIA_URL=${PAIRDESK_TEST_MEDIA_URL:-ws://127.0.0.1:7880}
export PAIRDESK_TEST_MEDIA_API_URL=${PAIRDESK_TEST_MEDIA_API_URL:-http://127.0.0.1:7880}
export PAIRDESK_LIVEKIT_NODE_IP="$NODE_IP"

# Exercise call prompts against the same real API/media stack before applying
# network constraints. The ordinary native test run has no integration server.
PAIRDESK_TEST_FILTER=IncomingCallIntegrationTests sh scripts/test-call.sh

PAIRDESK_BENCHMARK_PROFILE=baseline sh scripts/test-call.sh
# Camera publication is exercised by the baseline. Keep the constrained run
# focused on screen quality and cursor behavior; camera frame delivery under
# induced packet loss is nondeterministic on hosted macOS runners.
PAIRDESK_SKIP_CAMERA_PUBLICATION_TEST=1 \
  sh scripts/with-macos-network-condition.sh sh scripts/test-call.sh

python3 -m unittest discover -s scripts/tests -p 'test_*.py'
for artifact in \
  pairwise-media-benchmark-baseline-2p.json \
  pairwise-media-benchmark-baseline-4p.json \
  pairwise-media-benchmark-constrained-2p.json \
  pairwise-media-benchmark-constrained-4p.json \
  pairwise-cursor-benchmark-baseline-2p.json \
  pairwise-cursor-benchmark-baseline-3p.json \
  pairwise-cursor-benchmark-constrained-2p.json \
  pairwise-cursor-benchmark-constrained-3p.json \
  network-conditioner.json
do
  test -s "$BENCHMARK_DIR/$artifact" || {
    echo "Required media-quality artifact is missing: $artifact" >&2
    exit 1
  }
done

python3 scripts/validate-media-benchmark.py \
  "$BENCHMARK_DIR/pairwise-media-benchmark-baseline-2p.json" \
  "$BENCHMARK_DIR/pairwise-media-benchmark-baseline-4p.json" \
  "$BENCHMARK_DIR/pairwise-media-benchmark-constrained-2p.json" \
  "$BENCHMARK_DIR/pairwise-media-benchmark-constrained-4p.json" \
  --cursor-reports \
  "$BENCHMARK_DIR/pairwise-cursor-benchmark-baseline-2p.json" \
  "$BENCHMARK_DIR/pairwise-cursor-benchmark-baseline-3p.json" \
  "$BENCHMARK_DIR/pairwise-cursor-benchmark-constrained-2p.json" \
  "$BENCHMARK_DIR/pairwise-cursor-benchmark-constrained-3p.json" \
  --conditioner "$CONDITION_REPORT"
