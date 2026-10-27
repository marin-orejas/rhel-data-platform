# 0004. pgBackRest, with its repository on the NFS share

Date: 2026-10-26
Status: Accepted

## Context

Point-in-time recovery first ran by hand: `archive_command` with `cp` and base backups from `pg_basebackup`, on the NFS share from db2. It worked, but `cp` can leave a partial segment after a crash, nothing deleted old backups or WAL, and the tested restore took 9 min 31 s of typing. pgBackRest can keep its repository on a separate repository host, reached over SSH or TLS, or on a path that the database host can write.

## Decision

pgBackRest 2.60 from PGDG archives the WAL and takes the backups (a full on Sunday, a differential on the other nights, two fulls kept). It runs only on db1, as `postgres`, with the repository in `/mnt/db2/backup/pgbackrest`, on the existing NFS share. There is no repository host.

## Consequences

- A segment is written under a temporary name and renamed, so a partial segment never has its final name. WAL is compressed with zstd.
- `expire` removes old backups and their WAL. A restore to any time in the last 7 to 14 days is possible.
- The tested restore to a set time took one command and an outage of 1.1 s.
- db1 can change and delete its own backups. A compromised or broken db1 can take its backups with it. A production setup would use a separate repository host.
- The SELinux module `pg_archive_nfs` needed version 1.1, with rules for directories and `rename` on NFS.
- The package comes from outside RHEL, limited with `includepkgs` so no PGDG package can replace PostgreSQL from AppStream.

Details: [Backups, pgBackRest](../architecture/backups.md#pgbackrest)
