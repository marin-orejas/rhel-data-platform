# Backups

Backups of db1 go to the NFS share on db2. pgBackRest backs up the cluster and archives every WAL segment, for a restore to any time in the last 7 to 14 days. A nightly dump of each database restores one database to 02:00.

Verified by: [`checks/09-backup.sh`](../../checks/09-backup.sh) (dumps), [`checks/14-pgbackrest.sh`](../../checks/14-pgbackrest.sh) (pgBackRest), [`checks/23-standby-backup-roles.sh`](../../checks/23-standby-backup-roles.sh) (the role `pgbackrest` and the restore test, desktop), [`checks/13-pitr.sh`](../../checks/13-pitr.sh) (the archive by hand)
Repo files: [`ansible/roles/pgdump/`](../../ansible/roles/pgdump/), [`ansible/roles/pgbackrest/`](../../ansible/roles/pgbackrest/), [`ansible/playbooks/restore-test.yml`](../../ansible/playbooks/restore-test.yml)

## Setup

### pgBackRest

| Part | Setup |
|---|---|
| Package | `pgbackrest` 2.60 on db1 and db2, installed by the Ansible role `pgbackrest` ([Ansible](ansible.md)) from the PGDG "common" repository (`pgdg-common.repo`), limited by `includepkgs` to `pgbackrest` and `pgdg-libssh2` |
| Config | `/etc/pgbackrest.conf` from the role's template `pgbackrest.conf.j2`, stanza `main` |
| Repository | `/mnt/db2/backup/pgbackrest` on db1, which is `/srv/backup/pgbackrest` on db2. Each host's config names its own path. |
| Archive command | `pgbackrest --stanza=main archive-push %p`, in `postgresql.conf` from the Ansible role `postgresql` ([Ansible](ansible.md)) |
| SELinux | module `pg_archive_nfs`, see [SELinux](system.md#selinux) |
| Service | `pgbackrest@.service`, the instance is the backup type: `pgbackrest@full`, `pgbackrest@diff` |
| Retry | A failed run starts again after 1 min, at most 3 starts in 10 min (`Restart=on-failure`, `RestartSec=1min`, `StartLimitBurst=3`). Then the unit stays `failed`. |
| Schedule | Full on Sunday, differential Monday to Saturday, both at 01:00 (`pgbackrest-full.timer`, `pgbackrest-diff.timer`). The backups run only on db1, as `postgres`. On db2 the timers are disabled and stopped. |
| Retention | `repo1-retention-full=2`: the two newest fulls, the backups that depend on them, and their WAL |
| Restore test | `ansible/playbooks/restore-test.yml`, started by hand from the desktop, runs on db2: the newest backup and the WAL archive after it go into a temporary copy beside the standby. The copy must leave recovery and hold the same data as the standby ([Ansible](ansible.md)). |

### Nightly dumps

| Part | Setup |
|---|---|
| Script | `pg-backup.sh` in the role `pgdump`, as `/usr/local/bin/pg-backup.sh`, run as `postgres` over the local socket |
| Service | `pg-backup.service`, oneshot, `Wants=` and `After=autofs.service`. Only the timer starts it. |
| Retry | The same as for `pgbackrest@.service` |
| Timer | `pg-backup.timer`, every day at 02:00, `Persistent=true` |
| Destination | `/mnt/db2/backup/pgsql`, `postgres:dba`, mode `2750`. The files are `640`. |
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

- A full on Sunday and a differential on the other nights, so a restore needs at most a full and one differential. Only the full catches up after an outage (`Persistent=true`), because two backups at once would fail on the stanza lock, and a missed differential leaves no line in the journal.
- The nightly dumps stay next to pgBackRest, to restore one database without touching the others.
- The [repository is on the NFS share](../decisions/pgbackrest-with-its-repository-on-nfs.md) to keep the lab small, but db1 can delete its own backups.
- The restore test runs on db2, beside the standby, so db1 is never touched and the backup is read from the local repository. Archiving is off in the copy. After its promote the copy is on a new timeline, and its WAL in the stanza would clash with the timeline a real failover takes.
- [systemd timers, not cron](../decisions/systemd-timers-for-backups.md), so a missed run starts after the next boot and a failure leaves the unit `failed`. Both services retry a failed run, because the run after a boot can start before db2 is up, and `After=` orders units only on one host.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lab` restored from a dump into a new database ([runbook](../runbooks/restore-a-database-from-a-dump.md)) | Row count and `sum(id)` match |
| 2026-10-25 | db2 shut down while db1 wrote 3 WAL segments | The archiver waited on the `hard` mount and `failed_count` stayed the same. All 3 were archived 10 s after db2 came back. |
| 2026-10-26 | Restore by hand to 4 s before a `DROP TABLE` ([runbook](../runbooks/restore-to-a-time-by-hand.md)) | Outage 9 min 31 s, almost all of it typing. The replay of 8 segments took 0.67 s. |
| 2026-10-26 | Full backup of the 50.6 MB cluster by `pgbackrest@full` | 19.4 s, 11.1 MB in the repository |
| 2026-10-26 | Differential after 200,000 new rows, incremental after 100,000 more | 1.4 s and 1.5 s. The incremental copied the whole changed table file. |
| 2026-10-26 | Restore with pgBackRest to 5 s before a `DROP TABLE` ([runbook](../runbooks/restore-to-a-time-with-pgbackrest.md)) | Outage 1.1 s, `--delta` restore 0.41 s. All 300,000 rows came back with the same `sum(id)`. |
| 2026-10-26 | A third full backup | Removed the first full, its differential and incremental, and their WAL |
| 2026-11-07 | `ansible/playbooks/restore-test.yml` on db2: the newest backup (a differential of 2026-10-31) and the WAL after it restored into a temporary copy | Restore 9.1 s (163.7 MB), replay of 18 WAL segments in 1.37 s, the whole run 18.1 s. The copy left recovery on timeline 6 with the same data as the standby, and the repository got no `00000006.history`. |

## History

- `/srv/backup/pgsql/wal` and `base` on db2: the WAL archive by hand (`cp`) and its base backup from `pg_basebackup`, 2026-10-25 to 2026-10-26, up to segment `00000002000000000000000E`. Nothing writes there any more.
