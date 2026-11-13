# pgBackRest

pgBackRest backs up the cluster on db1 and archives every WAL segment to the NFS share on db2, for a restore to any time in the last 7 to 14 days. The backups run only on db1, and a playbook tests the newest one on db2.

Checks: [13](../../../checks/13-pitr.sh), [14](../../../checks/14-pgbackrest.sh), [23](../../../checks/23-standby-backup-roles.sh) · Managed by: [Role pgbackrest](../ansible/pgbackrest.md), [Role postgresql](../ansible/postgresql.md)

## Setup

| Part | Setup |
|---|---|
| Package | `pgbackrest` 2.60 on db1 and db2, from the PGDG "common" repository (`pgdg-common.repo`) |
| Repository filter | `includepkgs` limits `pgdg-common.repo` to `pgbackrest` and `pgdg-libssh2`. |
| Config | `/etc/pgbackrest.conf`, stanza `main` |
| Repository | `/mnt/db2/backup/pgbackrest` on db1, which is `/srv/backup/pgbackrest` on db2. Each host's config names its own path. |
| Archive command | `pgbackrest --stanza=main archive-push %p` in `postgresql.conf` ([PostgreSQL server](../postgresql/server.md#setup)) |
| SELinux | Module `pg_archive_nfs` ([System settings, SELinux](../hosts/system.md#selinux)) |
| Service | `pgbackrest@.service`. The instance is the backup type (`pgbackrest@full`, `pgbackrest@diff`). |
| Retry | A failed run starts again after 1 min, at most 3 starts in 10 min (`Restart=on-failure`, `RestartSec=1min`, `StartLimitBurst=3`). Then the unit stays `failed`. |
| Schedule | Full on Sunday, differential Monday to Saturday, both at 01:00 (`pgbackrest-full.timer`, `pgbackrest-diff.timer`) |
| Hosts | The backups run only on db1, as `postgres`. On db2 the timers are disabled and stopped. |
| Retention | `repo1-retention-full=2`: the two newest fulls, the backups that depend on them, and their WAL |
| Restore test | The newest backup and the WAL after it go into a temporary copy on db2, beside the standby. The copy must leave recovery and hold the same data as the standby. |
| Restore test playbook | `ansible/playbooks/restore-test.yml`, started by hand from the desktop ([Ansible playbooks](../ansible/playbooks.md)) |

## Why

- A full on Sunday and a differential on the other nights, so a restore needs at most a full and one differential. Only the full catches up after an outage (`Persistent=true`), because two backups at once would fail on the stanza lock, and a missed differential leaves no line in the journal.
- The [repository is on the NFS share](../../decisions/pgbackrest-with-its-repository-on-nfs.md) to keep the lab small, but db1 can delete its own backups.
- The service retries a failed run, because the run after a boot can start before db2 is up, and `After=` orders units only on one host. The nightly dumps retry the same way.
- The restore test runs on db2 beside the standby, so db1 is never touched and the backup is read from the local repository. Archiving is off in the copy, because its WAL on a new timeline would clash with the timeline of a real failover.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-26 | Restore by hand to 4 s before a `DROP TABLE` ([runbook](../../runbooks/restore-to-a-time-by-hand.md)) | Outage 9 min 31 s, almost all of it typing. The replay of 8 segments took 0.67 s. |
| 2026-10-26 | Full backup of the 50.6 MB cluster by `pgbackrest@full` | 19.4 s, 11.1 MB in the repository |
| 2026-10-26 | Differential after 200,000 new rows, incremental after 100,000 more | 1.4 s and 1.5 s. The incremental copied the whole changed table file. |
| 2026-10-26 | Restore with pgBackRest to 5 s before a `DROP TABLE` ([runbook](../../runbooks/restore-to-a-time-with-pgbackrest.md)) | Outage 1.1 s, `--delta` restore 0.41 s. All 300,000 rows came back with the same `sum(id)`. |
| 2026-10-26 | A third full backup | Removed the first full, its differential and incremental, and their WAL. |
| 2026-11-07 | `ansible/playbooks/restore-test.yml` on db2: the newest backup (a differential of 2026-10-31) and the WAL after it restored into a temporary copy | Restore 9.1 s (163.7 MB), replay of 18 WAL segments in 1.37 s, the whole run 18.1 s. The copy left recovery on timeline 6 with the same data as the standby, and the repository got no `00000006.history`. |

## History

- `/srv/backup/pgsql/wal` and `base` (db2, lesson 13): the WAL archive by hand (`cp`) and its base backup from `pg_basebackup`, up to segment `00000002000000000000000E`. Nothing writes there any more.
