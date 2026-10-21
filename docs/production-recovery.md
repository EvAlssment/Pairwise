# PairDesk production recovery

Production API state is stored in the PostgreSQL 16 Cloud SQL instance
`pairdesk-pg` in `us-central1`; the API and push worker run as one writer on
`pairdesk-server`. Cloud SQL automated backups are enabled with seven retained
backups, seven-day point-in-time recovery (PITR), and deletion protection. The
API connects through the Cloud SQL Auth Proxy using its attached runtime
service account. Keep the old root-only JSON snapshot and boot-disk snapshot
from the 2026-10-21 migration as rollback artifacts; they are not the live
state source.

## Check production recovery configuration

Use a signed-in `gcloud` account with read access. These commands do not change
the instance:

```sh
gcloud sql instances describe pairdesk-pg \
  --project=named-tube-444103-p0 \
  --format='yaml(name,state,databaseVersion,region,settings.backupConfiguration)'
gcloud sql backups list --instance=pairdesk-pg \
  --project=named-tube-444103-p0 --limit=10
```

Check that backup and PITR settings remain enabled, recent backups are
successful, and the production instance is `RUNNABLE` before depending on this
procedure. Do not include database passwords, connection strings, tokens, or
state payloads in tickets or logs.

## Exercise backup restore and PITR safely

Run recovery drills by restoring into a disposable Cloud SQL instance. Do not
restore over `pairdesk-pg` to test the procedure. For a backup drill, create a
fresh on-demand backup, create a temporary PostgreSQL target with no backup
retention, and restore the selected backup to that target:

```sh
gcloud sql backups create --instance=pairdesk-pg \
  --description='PairDesk isolated recovery drill' \
  --project=named-tube-444103-p0
gcloud sql backups list --instance=pairdesk-pg \
  --project=named-tube-444103-p0 --limit=5
gcloud sql instances create pairdesk-restore-drill-YYYYMMDD \
  --database-version=POSTGRES_16 --region=us-central1 --tier=db-g1-small \
  --storage-type=SSD --storage-size=10 --assign-ip --no-backup \
  --no-deletion-protection --project=named-tube-444103-p0
gcloud sql backups restore BACKUP_ID \
  --restore-instance=pairdesk-restore-drill-YYYYMMDD \
  --backup-instance=pairdesk-pg --project=named-tube-444103-p0
```

Replace `BACKUP_ID` with the successful backup ID from the list. For a PITR
drill, select a UTC time within the configured seven-day window and before the
present, then clone the source:

```sh
gcloud sql instances clone pairdesk-pg pairdesk-pitr-drill-YYYYMMDD \
  --point-in-time='2026-10-21T13:24:00Z' \
  --preferred-zone=us-central1-a \
  --project=named-tube-444103-p0
```

The destination inherits source protections and settings. Confirm the
operation completed and the destination is `RUNNABLE`. Connect only to that
destination through the Cloud SQL Auth Proxy; use a temporary password for the
cloned `pairdesk_app` role, never the production password. Read back aggregate
state counts without selecting user records or secret fields. For example:

```sql
SELECT updated_at,
       (SELECT count(*) FROM jsonb_object_keys(payload->'users')) AS users,
       (SELECT count(*) FROM jsonb_object_keys(payload->'sessions')) AS sessions,
       (SELECT count(*) FROM jsonb_object_keys(payload->'rooms')) AS rooms,
       (SELECT count(*) FROM jsonb_object_keys(payload->'presence')) AS presence,
       (SELECT count(*) FROM jsonb_object_keys(payload->'calls')) AS calls,
       (SELECT count(*) FROM jsonb_object_keys(payload->'devices')) AS devices,
       (SELECT count(*) FROM jsonb_object_keys(payload->'pushJobs')) AS push_jobs
FROM pairdesk_state WHERE id = 1;
```

After collecting recovery time and confirming the selected recovery point,
remove the temporary proxy. Disable deletion protection only on the disposable
clone, then delete that clone:

```sh
gcloud sql instances patch pairdesk-pitr-drill-YYYYMMDD \
  --no-deletion-protection --project=named-tube-444103-p0
gcloud sql instances delete pairdesk-pitr-drill-YYYYMMDD \
  --project=named-tube-444103-p0
```

Record the backup or PITR timestamp, operation result, aggregate counts,
recovery time, and cleanup result. Do not record user values, password hashes,
push tokens, sessions, or call content. Account owners must verify their own
sign-in after a real production recovery; an aggregate database read cannot
prove an existing user's password works.

## Production recovery boundary

A real production recovery needs an approved maintenance window. First preserve
the current database state and identify the target backup or PITR timestamp.
Restore to a new instance, verify it independently, and record the chosen
recovery point. Stop the API and worker before changing the production
connection; keep the old instance intact until readiness, existing-account
sign-in, calls, presence, and outbox replay are verified. Then ask account
owners to test sign-in and call behavior. Preserve the original database and
all recovery artifacts until owners confirm success. The deployment is
single-writer; do not add API or worker replicas until the PostgreSQL
multi-instance integration gate is green and the deployment plan is reviewed.

## Completed GCP drill (2026-10-21)

After cutover, on-demand backup `1792589086990` completed successfully at
`2026-10-21T13:24:46.990Z`. It was restored to isolated PostgreSQL 16 instance
`pairdesk-restore-drill-20261021`. Aggregate readback showed 8 users, 6
sessions, 31 rooms, 5 presence records, 1 call, and empty join-request, device,
push-job, and audit collections. The clone and its temporary proxy were
removed after the readback.

A separate PITR clone of `pairdesk-pg` at `2026-10-21T13:24:00Z` completed
successfully (Cloud SQL operation
`8fa4dbb0-779f-4fa5-9d23-076c00000032`, start `13:50:52Z`, completion
`14:00:45Z`). Its restored row had `updated_at=13:23:59.457609Z`; aggregate
readback showed 8 users, 6 sessions, 31 rooms, 5 presence records, 1 call, and
no device or pending push-job records. The PITR clone inherited deletion
protection; protection was disabled on that disposable clone and the instance
was deleted after verification. Neither drill used or printed user credentials
or state contents.

These drills prove backup restore and PITR data recovery. They do not prove
that a teammate can sign in after a production restore or that a deployed
multi-replica service can call external APNs/FCM providers. Those checks remain
separate acceptance gates.

## Alerting

GCP project `named-tube-444103-p0` has a multi-region uptime check for `/readyz`
and an enabled five-minute failure alert routed to the project-owner email
channel. An enabled channel does not prove mailbox delivery; confirm receipt
during an operational test before relying on it.
