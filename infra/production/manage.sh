#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
[[ -f generated/.env ]] || { echo 'Run configure.py first' >&2; exit 1; }
# configure.py restricts these generated values to shell-safe domain/key/email characters.
source generated/.env
COMPOSE_FILES=(-f docker-compose.yml)
if [[ -n "${PAIRDESK_CLOUD_SQL_CONNECTION_NAME:-}" ]]; then
  [[ -n "${PAIRDESK_DATABASE_URL:-}" ]] || { echo 'Cloud SQL connection is configured without a database URL' >&2; exit 1; }
  [[ "$PAIRDESK_DATABASE_URL" == *'@cloud-sql-proxy:5432/pairdesk?sslmode=disable' ]] || {
    echo 'Cloud SQL proxy is configured, but the database URL does not target its private Compose service' >&2
    exit 1
  }
  COMPOSE_FILES+=(-f docker-compose.cloudsql.yml)
elif [[ "${PAIRDESK_DATABASE_URL:-}" == *'@cloud-sql-proxy:5432/'* ]]; then
  echo 'The database URL targets Cloud SQL but its instance connection name is missing; run configure-cloudsql.py' >&2
  exit 1
fi
compose() { docker compose -p pairdesk-prod --env-file generated/.env "${COMPOSE_FILES[@]}" "$@"; }
case "${1:-}" in
  certificates)
    [[ "$(uname -s)" == Linux ]] || { echo 'Certificate bootstrap runs on the Linux deployment host' >&2; exit 1; }
    [[ ! -e generated/certificates/live/pairdesk/fullchain.pem ]] || { echo 'Certificate exists; use renew' >&2; exit 1; }
    docker run --rm -p 80:80 -v "$ROOT/generated/certificates:/etc/letsencrypt" \
      certbot/certbot:v3.2.0 certonly --standalone --non-interactive --agree-tos \
      --email "$CERT_CONTACT" --cert-name pairdesk -d "$API_DOMAIN" -d "$MEDIA_DOMAIN" -d "$TURN_DOMAIN"
    ;;
  up)
    [[ "$(uname -s)" == Linux ]] || { echo 'Production startup is restricted to the Linux host' >&2; exit 1; }
    [[ -f generated/certificates/live/pairdesk/fullchain.pem ]] || { echo 'Bootstrap trusted certificates first' >&2; exit 1; }
    build_commit=$(git -C "$ROOT/../.." rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')
    PAIRDESK_BUILD_COMMIT="$build_commit" compose up -d --build
    ;;
  admin)
    [[ $# == 3 ]] || { echo 'Usage: manage.sh admin NAME EMAIL' >&2; exit 1; }
    # Offline CLI must never compete with the API writer. Restart even if user creation fails.
    compose stop api
    trap 'compose up -d api' EXIT
    compose run --rm --no-deps -it --entrypoint /pairdesk-admin api create-user --admin --name "$2" --email "$3"
    ;;
  renew)
    before=$(sha256sum generated/certificates/live/pairdesk/fullchain.pem | cut -d' ' -f1)
    docker run --rm -v "$ROOT/generated/certificates:/etc/letsencrypt" \
      -v "$ROOT/generated/challenges:/var/www/certbot" certbot/certbot:v3.2.0 \
      renew --webroot -w /var/www/certbot --non-interactive
    after=$(sha256sum generated/certificates/live/pairdesk/fullchain.pem | cut -d' ' -f1)
    if [[ "$before" != "$after" ]]; then
      compose exec -T edge nginx -t
      compose exec -T edge nginx -s reload
      compose restart livekit
    else
      echo 'Certificate unchanged; running calls preserved.'
    fi
    ;;
  backup)
    [[ $# == 2 ]] || { echo 'Usage: manage.sh backup EXISTING_PRIVATE_DIRECTORY' >&2; exit 1; }
    [[ -d "$2" ]] || { echo 'Backup directory must already exist' >&2; exit 1; }
    umask 077
    backup_dir=$(cd "$2" && pwd)
    archive="$backup_dir/pairdesk-$(date -u +%Y%m%dT%H%M%SZ).json"
    [[ ! -e "$archive" ]] || { echo 'Backup already exists' >&2; exit 1; }
    if [[ -n "${PAIRDESK_DATABASE_URL:-}" ]]; then
      compose run --rm --no-deps -T -v "$backup_dir:/pairdesk-backups" \
        --entrypoint /pairdesk-admin api export-json --to "/pairdesk-backups/$(basename "$archive")"
    else
      compose cp api:/data/pairdesk.json "$archive"
    fi
    chmod 600 "$archive"
    echo "Account snapshot saved to $archive"
    ;;
  status) compose ps ;;
  logs) compose logs --tail 80 ;;
  *) echo 'Usage: manage.sh {certificates|up|admin NAME EMAIL|renew|backup DIRECTORY|status|logs}' >&2; exit 2 ;;
esac
