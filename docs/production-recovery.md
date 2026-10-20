# PairDesk production recovery

PairDesk stores accounts, password hashes, sessions, call state, audit events, mobile registrations, and the push outbox in `/data/pairdesk.json`. The current deployment is single-writer. The GCP host takes daily mode-600 snapshots in `/var/lib/pairdesk/backups`; the API's Docker volume remains the live source of truth.

## Verify backups and run an isolated restore drill

Run these commands on the PairDesk VM through IAP. The drill uses the deployed API image, copies one snapshot into a temporary private directory, and starts an API container bound to a loopback-only host port with media credentials unset. It creates and signs in a throwaway account against the restored copy, checks that the original account records loaded, and removes the temporary container, network, and files on exit. It never writes the live Docker volume or sends credentials to GCP services.

```sh
sudo systemctl status pairdesk-backup.timer --no-pager
sudo find /var/lib/pairdesk/backups -maxdepth 1 -type f -name 'pairdesk-*.json' -printf '%TY-%Tm-%Td %TH:%TM %m %u %f\n' | sort
sudo /opt/pairdesk/infra/production/restore-drill.sh /var/lib/pairdesk/backups/PAIRWISE_SNAPSHOT.json
```

Choose an existing snapshot path from the listing. The script requires a root-owned file with mode `600`, a free loopback port (default `18082`), Docker, Python 3, OpenSSL, and curl. Set `PAIRDESK_RESTORE_DRILL_PORT` when that port is occupied. Its recovery-time figure covers the isolated snapshot load and test-account login; it is not a measured production outage recovery time.

The drill verifies that the snapshot parses, original account records and password hashes are present, and a temporary account can authenticate against the restored service. It cannot verify that a teammate's existing password works without using that teammate's credential. Have an account owner verify sign-in after any real production restore.

## Production restore boundary

Do not run an unreviewed restore against the live volume. A production recovery requires a maintenance window, an independently preserved copy of the current `/data/pairdesk.json`, a chosen and verified snapshot, stopping the single API writer, restoring the file with owner `65532:65532` and mode `600`, restarting the API, checking `/healthz` and `/readyz`, and asking account owners to verify sign-in. Preserve both pre-restore and source snapshots until verification is complete. Restoring the JSON snapshot also rolls back sessions and call/device/outbox state to the snapshot time; clients may need to sign in again, and stale push jobs must expire under their existing TTL policy.

## Alerting

GCP project `named-tube-444103-p0` has a multi-region uptime check for `/readyz` and an enabled five-minute failure alert routed to the project owner's email notification channel. The channel resource being enabled does not prove that an alert was delivered; confirm receipt during an operational test before relying on it.
