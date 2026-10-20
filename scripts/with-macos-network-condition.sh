#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 command [args...]" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This conditioner uses macOS PF and dummynet." >&2
  exit 2
fi
if [[ "${CI:-}" != "true" ]]; then
  echo "This script is restricted to disposable CI runners; it changes the host PF ruleset temporarily." >&2
  exit 2
fi
for tool in pfctl dnctl sudo; do
  command -v "$tool" >/dev/null || { echo "Required tool is missing: $tool" >&2; exit 2; }
done
sudo -n true || { echo "Passwordless sudo is required on the disposable CI runner." >&2; exit 2; }

PIPE_IN=591
PIPE_OUT=592
ANCHOR=pairdesk-benchmark
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pairdesk-net.XXXXXX")
PF_WAS_ENABLED=''
PF_CONFIG_LOADED=false
JITTER_PID=''

cleanup() {
  if [[ -n "$JITTER_PID" ]]; then kill "$JITTER_PID" 2>/dev/null || true; wait "$JITTER_PID" 2>/dev/null || true; fi
  if [[ "$PF_CONFIG_LOADED" == true ]]; then
    sudo -n pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
    sudo -n pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  fi
  sudo -n dnctl -q pipe delete "$PIPE_IN" "$PIPE_OUT" >/dev/null 2>&1 || true
  if [[ "$PF_CONFIG_LOADED" == true && "$PF_WAS_ENABLED" == Disabled ]]; then sudo -n pfctl -d >/dev/null 2>&1 || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

awk -v anchor="$ANCHOR" '
  { print }
  $1 == "dummynet-anchor" && !inserted {
    print "dummynet-anchor \"" anchor "\""
    inserted = 1
  }
  END { if (!inserted) exit 1 }
' /etc/pf.conf > "$TMP_DIR/pf.conf"
cat > "$TMP_DIR/dummynet.rules" <<EOF
dummynet in quick on lo0 inet proto udp from any to any port 17882:17981 pipe $PIPE_IN
dummynet out quick on lo0 inet proto udp from any to any port 17882:17981 pipe $PIPE_OUT
EOF

sudo -n dnctl pipe "$PIPE_IN" config bw 20000Kbit/s delay 40ms plr 0.005
sudo -n dnctl pipe "$PIPE_OUT" config bw 20000Kbit/s delay 40ms plr 0.005
sudo -n pfctl -n -f "$TMP_DIR/pf.conf"
sudo -n pfctl -a "$ANCHOR" -n -f "$TMP_DIR/dummynet.rules"
PF_WAS_ENABLED=$(sudo -n pfctl -s info | awk -F ': ' '/Status:/ {split($2, status, " "); print status[1]; exit}')
if [[ "$PF_WAS_ENABLED" != Enabled && "$PF_WAS_ENABLED" != Disabled ]]; then
  echo "Could not determine the runner's PF state; refusing to load network rules." >&2
  exit 1
fi
sudo -n pfctl -e >/dev/null 2>&1 || [[ "$PF_WAS_ENABLED" == Enabled ]]
sudo -n pfctl -f "$TMP_DIR/pf.conf"
PF_CONFIG_LOADED=true
sudo -n pfctl -a "$ANCHOR" -f "$TMP_DIR/dummynet.rules"

# Change both directions on a fixed sequence to introduce repeatable delay variation.
(
  while true; do
    for delay_ms in 20 60 30 50; do
      sudo -n dnctl pipe "$PIPE_IN" config bw 20000Kbit/s delay "${delay_ms}ms" plr 0.005
      sudo -n dnctl pipe "$PIPE_OUT" config bw 20000Kbit/s delay "${delay_ms}ms" plr 0.005
      sleep 1
    done
  done
) &
JITTER_PID=$!

PAIRDESK_BENCHMARK_PROFILE=constrained \
PAIRDESK_NETWORK_CONDITION_ACTIVE=1 \
PAIRDESK_NETWORK_CONDITION_BANDWIDTH_KBIT=20000 \
PAIRDESK_NETWORK_CONDITION_DELAY_SEQUENCE_MS=20,60,30,50 \
PAIRDESK_NETWORK_CONDITION_PACKET_LOSS_PERCENT=0.5 \
  "$@"
