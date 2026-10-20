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

1. Take and verify an encrypted copy of `/data/pairdesk.json`; schedule a short
   maintenance window and stop the API and push worker.
2. Configure a private Cloud SQL PostgreSQL instance with automated backups
   and point-in-time recovery, TLS/private connectivity, and least-privilege
   credentials. Put the DSN in the deployment secret store, not a committed
   `.env` file or shell history.
3. Run `PAIRDESK_DATABASE_URL=... pairdesk-admin import-json --from
   /data/pairdesk.json`. Import replaces the singleton state atomically and
   preserves accounts, password hashes, sessions, device registrations, audit
   entries, and unexpired pending jobs.
4. Start one API instance with the same DSN. Verify `/healthz`, `/readyz`,
   existing-user login, presence, call creation, and outbox delivery before
   enabling additional replicas.
5. Run the two-instance integration check against a disposable database with
   `PAIRDESK_TEST_DATABASE_URL=... go test ./internal/app -run
   TestPostgresConcurrentWorkersLeasePushOnce -count=1`.

The initial schema is created idempotently on application start. Back up before
upgrading; keep the JSON export until account owners confirm sign-in and call
flows after the migration.

## Rollback

Stop every API and worker first so the export is a consistent snapshot. Run
`PAIRDESK_DATABASE_URL=... pairdesk-admin export-json --to
/secure-backup/pairdesk-postgres-export.json`, validate the JSON file and its
permissions, then point the single API writer back to `PAIRDESK_DATA` on a
restored volume. This returns to single-writer mode and rolls state back to the
export point. Keep the Cloud SQL instance and backups until owners confirm
sign-in and pending-call behavior; do not delete the database as part of
rollback.

## Recovery evidence still required

This repository change does not provision or alter Cloud SQL. Before closing
the shared-storage issue, operations still need to configure GCP backups/PITR,
perform a restore into an isolated instance, and verify an existing teammate
can sign in after that restore. Alert delivery also needs a real test receipt.
