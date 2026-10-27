# Backups

Backups of db1 go to the NFS share on db2 in two forms. pgBackRest backs up the whole cluster and archives every WAL segment, for a restore to any time in the last 7 to 14 days. A nightly dump of each database restores one database to the state at 02:00. Nothing is stored on db1.

Verified by: [`checks/09-backup.sh`](../../checks/09-backup.sh) (dumps), [`checks/14-pgbackrest.sh`](../../checks/14-pgbackrest.sh) (pgBackRest), [`checks/13-pitr.sh`](../../checks/13-pitr.sh) (the archive by hand)
Repo files: [`scripts/pg-backup.sh`](../../scripts/pg-backup.sh), [`systemd/`](../../systemd/), [`pgbackrest/`](../../pgbackrest/)

## Setup

### pgBackRest

Since 2026-10-26, pgBackRest archives the WAL of db1 and backs up the cluster.

| Part | Setup |
|---|---|
| Package | `pgbackrest` 2.60 from the "common" repository of PGDG, the PostgreSQL project's own packages. RHEL has no pgBackRest package. The repository file is `pgbackrest/pgdg-common.repo`, installed in `/etc/yum.repos.d/`, with the GPG key in `/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL`. `includepkgs` lets dnf see only `pgbackrest` and `pgdg-libssh2`, a library it needs that RHEL does not ship, so no PGDG package can replace PostgreSQL from AppStream. |
| Config | `pgbackrest/pgbackrest.conf`, installed as `/etc/pgbackrest.conf`. One stanza, `main`, for the cluster in `/pgdata/pgsql/data` on port 5433. |
| Repository | `/mnt/db2/backup/pgbackrest` on db1, which is `/srv/backup/pgbackrest` on db2. pgBackRest runs only on db1, as `postgres`, and writes to the NFS share. |
| Stanza | Created with `pgbackrest --stanza=main stanza-create`. The repository has `archive/main` for WAL and `backup/main` for backups. |
| Archive command | `pgbackrest --stanza=main archive-push %p`, set with `ALTER SYSTEM` and a reload. It checks that the segment belongs to this cluster, compresses it with zstd and writes it to a temporary file that it renames, so a partial segment never has its final name. The segments are in `archive/main/18-1/`, one directory for every 256 segments. |
| SELinux | `archive-push` runs in `postgresql_t` and needs the module `pg_archive_nfs`, see [SELinux](system.md#selinux) |
| Test | `pgbackrest --stanza=main check` switches to a new WAL segment and waits up to 60 seconds until it is in the repository. |
| Backups | A full backup copies every file of the cluster. A differential copies the files changed since the last full, and an incremental the files changed since the last backup of any type; the rest of the set refers to the earlier backups. A changed file is copied whole. Every backup waits until its WAL is in the archive. |
| Service | `systemd/pgbackrest@.service`, a template unit installed in `/etc/systemd/system/`. `Type=oneshot`, `User=postgres`, `ExecStart=/usr/bin/pgbackrest --stanza=main --type=%i backup`, with the same `Wants=` and `After=` as `pg-backup.service`. The instance name is the backup type: `pgbackrest@full.service`, `pgbackrest@diff.service`. |
| Schedule | `systemd/pgbackrest-full.timer`: Sunday at 01:00, `Persistent=true`. `systemd/pgbackrest-diff.timer`: Monday to Saturday at 01:00, without `Persistent=`. |
| Retention | `repo1-retention-full=2`. After each backup, `expire` keeps the two newest full backups: a third full removes the oldest one with every backup that refers to it. It also removes the archived WAL from before the start of the oldest full that is kept. |

### Nightly dumps

`scripts/pg-backup.sh` is installed as `/usr/local/bin/pg-backup.sh` (`root:root`, `755`) and runs as `postgres`. It connects over the local socket with `peer` authentication, so it needs no password. The systemd timer `pg-backup.timer` starts it every day at 02:00.

| Part | Setup |
|---|---|
| Service | `systemd/pg-backup.service`, installed in `/etc/systemd/system/`. `Type=oneshot`, `User=postgres`, `After=postgresql.service autofs.service`, `Wants=autofs.service`. It has no `[Install]` section, so only the timer starts it. The output goes to the journal (`journalctl -u pg-backup.service`), and a failed backup leaves the unit in the `failed` state. |
| Timer | `systemd/pg-backup.timer`, enabled. `OnCalendar=*-*-* 02:00:00` and `Persistent=true`: a run missed while db1 was off starts right after the next boot. |
| Destination | `/mnt/db2/backup/pgsql` on db1, given as the first argument. It is `/srv/backup/pgsql` on db2 (see [NFS share](nfs.md)). Owned by `postgres:dba`, mode `2750`. |
| Databases | One plain SQL dump per database, compressed with gzip: `<database>-<YYYY-MM-DD_HHMM>.sql.gz`. Templates are skipped. A database that does not accept connections makes the backup fail instead of being skipped. |
| Roles | `pg_dumpall --globals-only`, in `globals-<stamp>.sql.gz`. It includes the password hashes of the roles. |
| Config files | `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` from the data directory, in `config-<stamp>.tar.bz2`. The package `bzip2` is installed on db1 for this. |
| Permissions | The script sets `umask 027`, and the directory has setgid, so every file is `640 postgres:dba`. The group `dba` can read the backups but cannot change or delete them. Others have no access. |
| Port | The script sets `PGPORT=5433` unless the caller sets it. `sudo -u`, cron and systemd do not read the `.bash_profile` of postgres. |
| Retention | `find -mtime +7` (the second argument, default 7) deletes the files that are at least 8 days old, because `find` rounds the age down to whole days. After each nightly run, 8 sets are kept: that night's and the 7 before it. Nothing is deleted when any step has failed. Only files directly in the destination are deleted, so `wal` and `base` below it are not touched. |
| Exit code | `0` when every step has succeeded, `1` when any step has failed, `2` on a usage error |

## Layout

```
db1                                               db2: /srv/backup
postgres ── archive-push, every WAL segment ──►   pgbackrest/archive/main
pgbackrest@full (Sun) / @diff (Mon–Sat), 01:00 ►  pgbackrest/backup/main
pg-backup.sh, every night at 02:00 ───────────►   pgsql/
```

## Why

- A full on Sunday and a differential on the other nights: a restore needs at most a full and one differential.
- The diff timer has no `Persistent=`, because after an outage the full catches up at boot, and a second backup at the same time would fail on the stanza lock.
- With two fulls kept and a weekly full, a restore to any time in the last 7 to 14 days is possible.
- The nightly dumps stay next to pgBackRest, for the restore of a single database.
- The repository is on the NFS share, not on a separate repository host. This keeps the lab simple, but db1 can change and delete its own backups. A production setup would use a repository host. See [ADR 0004](../decisions/0004-pgbackrest-with-its-repository-on-nfs.md).
- All backups run from systemd timers, not cron: a missed run starts after the next boot, and a failure leaves the unit `failed`. See [ADR 0003](../decisions/0003-systemd-timers-for-backups.md).
- The dump service waits for `autofs.service`, because a run missed at 02:00 starts during the next boot, maybe before autofs. `RequiresMountsFor=` would not help: systemd knows the mounts from fstab and mount units, but not the ones that autofs makes when a program opens the path.

## Tested

Backups, measured on 2026-10-26. Between the backups, the test table `pgbr_test` in `lab` got 200,000 rows (14 MB) and then 100,000 more.

| Backup | Time | Copied | In the repository |
|---|---|---|---|
| Full, 31.1 MB cluster | 17.8 s | 31.1 MB, 1282 files | 3.7 MB |
| Differential | 1.4 s | 15.4 MB | 5.2 MB |
| Incremental | 1.5 s | 19.7 MB | 7.4 MB |
| Full, 50.6 MB, by `pgbackrest@full.service` | 19.4 s | 50.6 MB | 11.1 MB |

The full writes all 1282 files to the share, which is mounted with `sync`. A differential or incremental writes only the changed files. The incremental copied the whole file of `pgbr_test`, not only the 100,000 new rows. Retention: the third full removed the first full, its differential and incremental, and their WAL.

Restore to a set time with pgBackRest, on 2026-10-26: the table `pgbr_test` (300,000 rows) was dropped, and the cluster was restored to 5 seconds before the drop. Procedure: [Restore to a set time with pgBackRest](../runbooks/restore-to-a-time-with-pgbackrest.md).

| Part | Result |
|---|---|
| Backup set | pgBackRest picked the newest backup that ended before the target, the full backup `20261026-194628F`. |
| Data | `pgbr_test` came back with 300,000 rows and the same `sum(id)`. `items` (10,000 rows) and `pitr_test` (1,000 rows) did not change. |
| After promote | The server continues on timeline 3, and a new full backup was taken on it. |
| Outage, from `systemctl stop` to promote | 1.1 s |
| `pgbackrest restore` with `--delta`, 1287 files checked | 0.41 s |
| Server start to the promote | 0.28 s |

The restore by hand took 9 min 31 s, almost all of it typing. With pgBackRest the same restore was one command. `--delta` also made it short: the data directory was intact, so only the changed files came from the share. After the loss of the data disk, all 50.6 MB would be copied.

Restore of one database from a dump: `lab` was restored into a new database from a dump on db2, and the row count and `sum(id)` match the original. Procedure: [Restore a database from a nightly dump](../runbooks/restore-a-database-from-a-dump.md).

## History

### WAL archive and base backups by hand

From 2026-10-25 to 2026-10-26, PostgreSQL copied every full WAL segment with `cp` to `/mnt/db2/backup/pgsql/wal`, next to base backups from `pg_basebackup` in `/mnt/db2/backup/pgsql/base`. pgBackRest replaced this method. The two directories still hold that archive, up to segment `00000002000000000000000E`, and its base backup. Nothing writes to them any more.

| Part | Setup |
|---|---|
| Settings | `archive_mode = on` and `archive_command`, set with `ALTER SYSTEM`. `wal_level` stays `replica`, the default. `archive_mode` needs a restart, `archive_command` only a reload. `archive_mode` stays on for pgBackRest. |
| Archive command | `test ! -f /mnt/db2/backup/pgsql/wal/%f && cp %p /mnt/db2/backup/pgsql/wal/%f`. It returned 0 only when the copy had succeeded, and it never overwrote a segment that was already there. `cp` writes the file in place and does not call fsync, so a crash of db2 during a copy could leave a partial segment. |
| Archive | 16 MiB per segment, mode 600, so the group `dba` cannot read them. Nothing deletes old segments. |
| Segment switch | `archive_timeout` stays 0. A segment is archived when it is full, or after `SELECT pg_switch_wal()`. A clean shutdown of the server archives the current segment too. |
| Failed archiving | The segment stays in `pg_wal`, with a `.ready` file in `pg_wal/archive_status`, and the archiver tries again about every minute. Nothing is lost, but `pg_wal` grows. `pg_stat_archiver` counts the failures, and the server log shows the error. |
| db2 down | The share is mounted `hard`, so `cp` waited until db2 answered again instead of failing. The archiver stopped on that segment, the next ones waited in `pg_wal` with `.ready` files, and the database kept working. Tested with db2 shut down while three segments were written: `failed_count` did not change, and all three were archived within 10 seconds after db2 came back. So monitoring has to watch the age of `last_archived_time` and the number of `.ready` files, not only the failures. A long outage fills `/pgdata`. |
| Base backup | `pg_basebackup -Ft -z -X stream -c fast` as postgres, over the local socket (`local replication all peer` in `pg_hba.conf`), into `/mnt/db2/backup/pgsql/base/<YYYY-MM-DD_HHMM>`. It writes `base.tar.gz`, `pg_wal.tar.gz` with the WAL from the time of the backup, and `backup_manifest`. The first one: 32 MB of data, 4.3 MB compressed, 1.3 s. |
| Verification | `pg_verifybackup -n <dir>` checks every file against the manifest. `-n` is needed because `pg_waldump` cannot read WAL from a tar file. |
| Backup record | At the end of a backup, PostgreSQL archives a small `.backup` file with the start and stop WAL locations and the label. A restore from that backup needs the archived WAL from the start segment on. |

### Restore to a set time by hand

Tested on db1 on 2026-10-26: a table was created after the base backup and then dropped, and the cluster was restored in place to a time between the two, with `recovery_target_action = 'pause'` to check the data before the promote. The server then continued on timeline 2. A good row inserted 4 seconds after the target was lost together with the dropped table: the replay stops before the first commit after the target. Procedure: [Restore to a set time by hand](../runbooks/restore-to-a-time-by-hand.md).

| Measured | Time |
|---|---|
| Outage, from `systemctl stop` to promote | 9 min 31 s |
| Server start to the pause at the target | 0.85 s |
| Replay of 8 segments (`…06` to `…0D`) | 0.67 s |

Almost the whole outage was manual work: moving, extracting, editing the settings and checking the data. The replay itself took under a second. A real restore would go to a separate host first; the lab has none.
