# Nightly dumps

A dump of each database on db1 goes to the NFS share on db2 every night, to restore one database to its state at 02:00.

Checks: [09](../../../checks/09-backup.sh), [24](../../../checks/24-fresh-clones.sh) · Managed by: [Role pgdump](../ansible/pgdump.md)

## Setup

| Part | Setup |
|---|---|
| Script | `/usr/local/bin/pg-backup.sh` (from the role `pgdump`), run as `postgres` over the local socket |
| Service | `pg-backup.service`, oneshot, `Wants=` and `After=autofs.service`. Only the timer starts it. |
| Retry | Same as `pgbackrest@.service` ([pgBackRest, Setup](pgbackrest.md#setup)) |
| Timer | `pg-backup.timer`, every day at 02:00, `Persistent=true` |
| Destination | `/mnt/db2/backup/pgsql`, `postgres:dba`, mode `2750`. The files are `640`. |
| Contents | One gzip SQL dump per database, the roles from `pg_dumpall --globals-only` (with password hashes), the config files in a `.tar.bz2` |
| Retention | 8 nightly sets (`find -mtime +7`). Nothing is deleted after a failed step. |

## Why

- The nightly dumps stay next to pgBackRest, to restore one database without touching the others.
- [systemd timers, not cron](../../decisions/systemd-timers-for-backups.md), so a missed run starts after the next boot and a failure leaves the unit `failed`.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lab` restored from a dump into a new database ([runbook](../../runbooks/restore-a-database-from-a-dump.md)) | Row count and `sum(id)` match. |
