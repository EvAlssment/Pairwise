# Shared PostgreSQL storage

The API can use PostgreSQL by setting `PAIRDESK_DATABASE_URL` on every API
instance. When it is unset, the server uses `PAIRDESK_DATA` and remains a
single-writer deployment. Do not scale JSON-volume mode to multiple API
instances.

The first PostgreSQL implementation stores the existing state document in a
single JSONB row and locks that row for every store transaction. This preserves
atomic call creation plus push-outbox insertion and prevents lost updates
across instances. Push workers claim jobs by writing a 30-second owner lease
before contacting APNs/FCM. Delivery is at-least-once across process crashes:
an expired lease can be retried, and mobile clients must treat call/request IDs
as idempotency keys. The single-row lock favors correctness for Pairwise's
small team; it is a deliberate throughput limit. Normalize hot tables before
using this design for a substantially larger deployment.

## Migration

1. Schedule a short maintenance window and take a private JSON-mode backup with
   `bash infra/production/manage.sh backup /secure-backup`. Verify that the
   resulting file is valid JSON and retain an encrypted copy outside the VM.
   Stop the API and push worker before importing so no writes are lost.
2. Use the dedicated `pairdesk-pg` PostgreSQL 16 instance in `us-central1`.
   It has automated daily backups (7 retained), 7-day point-in-time recovery,
   SSL required, and no authorized public client networks. The `pairdesk`
   database and least-privilege `pairdesk_app` role are provisioned. Its
   password is held in Secret Manager as `pairdesk-db-password`; never copy it
   into this repository or a committed `.env` file. A dedicated runtime
   service account is prepared as
   `pairdesk-api-runtime@named-tube-444103-p0.iam.gserviceaccount.com`; it has
   the Cloud SQL Client role and Secret Accessor on this database password
   secret. It is attached to the production VM with the `cloud-platform` API
   scope. The production API connects through the Cloud SQL Auth Proxy.
3. Import the verified snapshot while the API remains stopped. Start only the
   proxy, then run the admin importer against the private backup path:

   ```sh
   docker compose -p pairdesk-prod --env-file infra/production/generated/.env \
     -f infra/production/docker-compose.yml \
     -f infra/production/docker-compose.cloudsql.yml up -d cloud-sql-proxy
   docker compose -p pairdesk-prod --env-file infra/production/generated/.env \
     -f infra/production/docker-compose.yml \
     -f infra/production/docker-compose.cloudsql.yml run --rm --no-deps \
     -v /secure-backup:/pairdesk-backups:ro --entrypoint /pairdesk-admin api \
     import-json --from /pairdesk-backups/PAIRWISE-BACKUP.json
   ```

   Import replaces the singleton state atomically and preserves accounts,
   password hashes, sessions, device registrations, audit entries, and
   unexpired pending jobs. Export the database to a separate temporary JSON
   file, normalize both JSON files, and compare them before starting the API.
4. Start one API instance with the same DSN. Verify `/healthz`, `/readyz`,
   existing-user login, presence, call creation, and outbox delivery before
   enabling additional replicas.
5. Run the PostgreSQL integration checks against a disposable database with
   `PAIRDESK_TEST_DATABASE_URL=... go test -race ./internal/app -run
   '^TestPostgres' -count=1`. The suite exercises independent store/API
   instances, call creation and outbox atomicity, concurrent claims, and
   restart/replay behavior.

Only after the import comparison passes should the API be started in Cloud SQL
mode with `bash infra/production/manage.sh up`. If import or comparison fails,
keep the API stopped and use the pre-cutover JSON snapshot as the recovery
source.

The initial schema is created idempotently on application start. Back up before
upgrading; keep the JSON export until account owners confirm sign-in and call
flows after the migration.

## Production proxy configuration

The production stack has an optional Cloud SQL Auth Proxy Compose override. On
the VM, after the runtime service account is attached and the VM has the
`cloud-platform` API scope, run:

```sh
python3 infra/production/configure-cloudsql.py \
  --project named-tube-444103-p0 \
  --instance pairdesk-pg \
  --secret pairdesk-db-password
```

The helper verifies the instance is `RUNNABLE`, reads the password from Secret
Manager without printing it, URL-escapes it, and writes the DSN and instance
connection name into `infra/production/generated/.env` with mode `0600`.
`manage.sh` then includes the pinned Cloud SQL Auth Proxy sidecar, which uses
the VM's attached identity and is reachable only on the private Compose
network. If the connection name is configured without a matching DSN, startup
fails closed. A non-Cloud-SQL PostgreSQL URL can still be used without the
sidecar.

In Cloud SQL mode, `manage.sh backup DIRECTORY` exports the current PostgreSQL
state through the app's store before saving a mode-`0600` JSON snapshot. In
JSON mode it retains the atomic file-copy backup. Keep the snapshot from
before cutover separately from later PostgreSQL exports so rollback preserves
the exact pre-migration state.

## Rollback

Stop every API and worker first so the export is a consistent snapshot. Run
`PAIRDESK_DATABASE_URL=... pairdesk-admin export-json --to
/secure-backup/pairdesk-postgres-export.json`, validate the JSON file and its
permissions, then point the single API writer back to `PAIRDESK_DATA` on a
restored volume. This returns to single-writer mode and rolls state back to the
export point. Keep the Cloud SQL instance and backups until owners confirm
sign-in and pending-call behavior; do not delete the database as part of
rollback.

## Recovery and cutover status

The production cutover completed on 2026-10-21. The API VM was stopped, its
30-GiB boot disk was snapshotted as
`pairdesk-pre-postgres-cutover-20261021`, and the live JSON state was exported
to the VM's root-only `/var/backups/pairdesk-pre-cloudsql` directory. The JSON
was validated and imported into the dedicated `pairdesk-pg` instance through
the Cloud SQL Auth Proxy. Exporting immediately after import produced an exact
state match: 8 users, 6 sessions, 1 call, and 0 pending push jobs. The primary
database retains automated daily backups, 7-day PITR, and deletion protection.

After restart, `/readyz` passed both inside the Compose network and through the
public API hostname. An existing unexpired session successfully read `/v1/me`,
`/v1/users`, and `/v1/active-calls`. A live state export retained all persistent
sections and all five presence entries; one presence timestamp refreshed after
the API resumed, as expected. The root-only JSON export and boot-disk snapshot
remain available for rollback. The deployment is still one API writer; do not
scale it until the two-instance database integration tests cover authentication,
presence, call creation, outbox delivery/retry, and restart/replay together.

The merged PostgreSQL lifecycle integration test exercises two independent
stores and API handlers, verifies shared sessions and presence, races two call
requests for the same teammate, and simulates restart with new stores and API
handlers. It verifies persisted retry state, successful replay, and no second
delivery after completion. CI runs this test against disposable PostgreSQL.
Production remains configured as one API writer; the test does not validate
live APNs/FCM delivery or the behavior of multiple deployed VM replicas.

The pre-cutover isolated-clone restore and sentinel readback verified the
Cloud SQL restore path. The production migration itself was validated by an
exact state export comparison and post-restart API checks, not by restoring a
post-cutover production backup. Run and record that restore drill before
closing this issue or scaling the API.

Cloud Monitoring has one enabled Pairwise readiness alert policy. A temporary
test policy targeting the configured email channel opened an incident and was
removed after the incident closed. The test incident confirms the alert path
was exercised; mailbox receipt was not independently confirmed.
