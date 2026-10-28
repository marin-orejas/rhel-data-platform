# Backups

Backups of db1 go to the NFS share on db2. pgBackRest backs up the cluster and archives every WAL segment, for a restore to any time in the last 7 to 14 days. A nightly dump of each database restores one database to 02:00.

Verified by: [`checks/09-backup.sh`](../../checks/09-backup.sh) (dumps), [`checks/14-pgbackrest.sh`](../../checks/14-pgbackrest.sh) (pgBackRest), [`checks/13-pitr.sh`](../../checks/13-pitr.sh) (the archive by hand)
Repo files: [`scripts/pg-backup.sh`](../../scripts/pg-backup.sh), [`systemd/`](../../systemd/), [`pgbackrest/`](../../pgbackrest/)

## Setup

### pgBackRest

| Part | Setup |
|---|---|
| Package | `pgbackrest` 2.60 from the PGDG "common" repository (`pgbackrest/pgdg-common.repo`), limited by `includepkgs` to `pgbackrest` and `pgdg-libssh2` |
| Config | `pgbackrest/pgbackrest.conf` as `/etc/pgbackrest.conf`, stanza `main` |
| Repository | `/mnt/db2/backup/pgbackrest` on db1, which is `/srv/backup/pgbackrest` on db2. pgBackRest runs only on db1, as `postgres`. |
| Archive command | `pgbackrest --stanza=main archive-push %p`, set with `ALTER SYSTEM` |
| SELinux | module `pg_archive_nfs`, see [SELinux](system.md#selinux) |
| Service | `systemd/pgbackrest@.service`, the instance is the backup type: `pgbackrest@full`, `pgbackrest@diff` |
| Schedule | Full on Sunday, differential Monday to Saturday, both at 01:00 (`pgbackrest-full.timer`, `pgbackrest-diff.timer`) |
| Retention | `repo1-retention-full=2`: the two newest fulls, the backups that depend on them, and their WAL |

### Nightly dumps

| Part | Setup |
|---|---|
| Script | `scripts/pg-backup.sh` as `/usr/local/bin/pg-backup.sh`, run as `postgres` over the local socket |
| Service | `systemd/pg-backup.service`, oneshot, `Wants=` and `After=autofs.service`; only the timer starts it |
| Timer | `systemd/pg-backup.timer`, every day at 02:00, `Persistent=true` |
| Destination | `/mnt/db2/backup/pgsql`, `postgres:dba`, mode `2750`; the files are `640` |
| Contents | One gzip SQL dump per database, the roles from `pg_dumpall --globals-only` (with password hashes), the config files in a `.tar.bz2` |
| Retention | 8 nightly sets (`find -mtime +7`). Nothing is deleted after a failed step. |

## Layout

```
db1                                               db2: /srv/backup
postgres ── archive-push, every WAL segment ──►   pgbackrest/archive/main
pgbackrest@full (Sun) / @diff (Mon–Sat), 01:00 ►  pgbackrest/backup/main
pg-backup.sh, every night at 02:00 ───────────►   pgsql/
```

## Why

- A full on Sunday and a differential on the other nights: a restore needs at most a full and one differential.
- The diff timer has no `Persistent=`. After an outage the full catches up at boot, and a second backup at the same time would fail on the stanza lock.
- The nightly dumps stay next to pgBackRest, to restore one database without touching the others.
- The repository is on the NFS share to keep the lab small, but db1 can delete its own backups. See [ADR 0004](../decisions/0004-pgbackrest-with-its-repository-on-nfs.md).
- systemd timers, not cron, so a missed run starts after the next boot and a failure leaves the unit `failed`. See [ADR 0003](../decisions/0003-systemd-timers-for-backups.md).

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lab` restored from a dump into a new database ([runbook](../runbooks/restore-a-database-from-a-dump.md)) | Row count and `sum(id)` match |
| 2026-10-25 | db2 shut down while db1 wrote 3 WAL segments | The archiver waited on the `hard` mount and `failed_count` stayed the same. All 3 were archived 10 s after db2 came back. |
| 2026-10-26 | Restore by hand to 4 s before a `DROP TABLE` ([runbook](../runbooks/restore-to-a-time-by-hand.md)) | Outage 9 min 31 s, almost all of it typing; the replay of 8 segments took 0.67 s |
| 2026-10-26 | Full backup of the 50.6 MB cluster by `pgbackrest@full` | 19.4 s, 11.1 MB in the repository |
| 2026-10-26 | Differential after 200,000 new rows, incremental after 100,000 more | 1.4 s and 1.5 s. The incremental copied the whole changed table file. |
| 2026-10-26 | Restore with pgBackRest to 5 s before a `DROP TABLE` ([runbook](../runbooks/restore-to-a-time-with-pgbackrest.md)) | Outage 1.1 s, `--delta` restore 0.41 s; 300,000 rows back with the same `sum(id)` |
| 2026-10-26 | A third full backup | Removed the first full, its differential and incremental, and their WAL |

## History

- `/srv/backup/pgsql/wal` and `base` on db2: the WAL archive by hand (`cp`) and its base backup from `pg_basebackup`, 2026-10-25 to 2026-10-26, up to segment `00000002000000000000000E`. Nothing writes there any more.
