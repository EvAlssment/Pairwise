#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT=/var/lib/pairdesk/backups
API_CONTAINER=pairdesk-prod-api-1
PORT=${PAIRDESK_RESTORE_DRILL_PORT:-18082}

if [[ $(id -u) != 0 ]]; then
  echo 'Run this drill with sudo on the PairDesk host.' >&2
  exit 1
fi
if [[ $# != 1 ]]; then
  echo 'Usage: restore-drill.sh /var/lib/pairdesk/backups/SNAPSHOT.json' >&2
  exit 2
fi
SNAPSHOT=$(realpath -- "$1")
BACKUP_ROOT=$(realpath -- "$BACKUP_ROOT")
case "$SNAPSHOT" in
  "$BACKUP_ROOT"/*) ;;
  *) echo 'Snapshot must be inside the private PairDesk backup directory.' >&2; exit 1 ;;
esac
[[ -f "$SNAPSHOT" ]] || { echo 'Snapshot file not found.' >&2; exit 1; }
[[ $(stat -c '%a' "$SNAPSHOT") == 600 ]] || { echo 'Snapshot must have mode 600.' >&2; exit 1; }
[[ $(stat -c '%u' "$SNAPSHOT") == 0 ]] || { echo 'Snapshot must be owned by root.' >&2; exit 1; }
python3 - "$PORT" <<'PY'
import socket, sys
with socket.socket() as sock:
    try:
        sock.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError as exc:
        raise SystemExit(f"Restore-drill port {sys.argv[1]} is unavailable: {exc}")
PY

STARTED=$(date +%s)
DRILL_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
DRILL_DIR=$(mktemp -d "/var/tmp/pairdesk-restore-drill.${DRILL_ID}.XXXXXX")
chmod 700 "$DRILL_DIR"
chown 65532:65532 "$DRILL_DIR"
CONTAINER="pairdesk-restore-drill-${DRILL_ID}"
NETWORK="pairdesk-restore-drill-${DRILL_ID}"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf -- "$DRILL_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install -o 65532 -g 65532 -m 600 "$SNAPSHOT" "$DRILL_DIR/pairdesk.json"
SNAPSHOT_USERS=$(python3 - "$DRILL_DIR/pairdesk.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
users = state.get("users")
if not isinstance(users, dict) or not users:
    raise SystemExit("Snapshot has no account records.")
if any(not isinstance(user, dict) or not user.get("passwordHash") for user in users.values()):
    raise SystemExit("Snapshot contains an account without a password hash.")
print(len(users))
PY
)
SNAPSHOT_ENABLED_USERS=$(python3 - "$DRILL_DIR/pairdesk.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
print(sum(1 for user in state["users"].values() if user.get("enabled") is True))
PY
)
IMAGE=$(docker inspect --format '{{.Image}}' "$API_CONTAINER")
docker network create --internal "$NETWORK" >/dev/null

# Create a throwaway account in the cloned snapshot; credentials never leave this process.
TEST_EMAIL="restore-drill-${DRILL_ID}@pairdesk.invalid"
TEST_PASSWORD=$(openssl rand -hex 24)
docker run --rm --network "$NETWORK" \
  -v "$DRILL_DIR:/restore" \
  -e PAIRDESK_DATA=/restore/pairdesk.json \
  -e PAIRDESK_ADMIN_PASSWORD="$TEST_PASSWORD" \
  --entrypoint /pairdesk-admin "$IMAGE" \
  create-user --admin --name 'PairDesk Restore Drill' --email "$TEST_EMAIL" >/dev/null

docker run -d --name "$CONTAINER" --network host \
  -v "$DRILL_DIR:/restore" \
  -e PAIRDESK_DATA=/restore/pairdesk.json \
  -e PAIRDESK_ADDR="127.0.0.1:${PORT}" \
  -e LIVEKIT_URL= -e LIVEKIT_API_URL= -e LIVEKIT_API_KEY= -e LIVEKIT_API_SECRET= \
  "$IMAGE" >/dev/null

ready=0
for _ in $(seq 1 30); do
  if curl --silent --show-error --fail "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true) != true ]]; then
    docker logs "$CONTAINER" >&2 || true
    break
  fi
  sleep 1
done
if [[ $ready != 1 ]]; then
  echo 'Restored API did not become healthy; isolated container diagnostics follow.' >&2
  docker inspect --format 'state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' "$CONTAINER" >&2 || true
  docker logs "$CONTAINER" >&2 || true
  exit 1
fi

LOGIN=$(printf '{"email":"%s","password":"%s"}' "$TEST_EMAIL" "$TEST_PASSWORD" |
  curl --silent --show-error --fail -H 'Content-Type: application/json' \
    --data-binary @- "http://127.0.0.1:${PORT}/v1/login")
TOKEN=$(python3 -c 'import json,sys; value=json.load(sys.stdin).get("token", ""); print(value) if value else sys.exit(1)' <<<"$LOGIN")

# The private roster response confirms original account records loaded from the snapshot.
RESTORED_USERS=$(curl --silent --show-error --fail \
  -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:${PORT}/v1/users" |
  python3 -c 'import json,sys; users=json.load(sys.stdin).get("users"); sys.exit(1) if not isinstance(users,list) else print(len(users))')
[[ "$RESTORED_USERS" == "$((SNAPSHOT_ENABLED_USERS + 1))" ]] || {
  echo 'Restored roster size did not match the snapshot plus the throwaway drill user.' >&2
  exit 1
}

ELAPSED=$(( $(date +%s) - STARTED ))
echo "Isolated restore drill passed: ${SNAPSHOT_USERS} snapshot accounts loaded (${SNAPSHOT_ENABLED_USERS} enabled); temporary login succeeded; roster count matched; ${ELAPSED}s."
echo 'Production API, volume, and account file were not modified. This does not prove an existing teammate password works.'
