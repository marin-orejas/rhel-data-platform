# Decisions

Architecture decision records: one page per choice between real options, with its context and consequences. A record is never deleted. When a decision changes, a new record replaces it, and the old one's status points to the new one.

| # | Decision | Date | Status |
|---|---|---|---|
| [0001](0001-a-separate-data-disk-per-vm.md) | A separate data disk per VM | 2026-10-01 | Accepted |
| [0002](0002-listen-on-all-addresses.md) | PostgreSQL listens on all addresses | 2026-10-05 | Accepted |
| [0003](0003-systemd-timers-for-backups.md) | systemd timers for backups, not cron | 2026-10-06 | Accepted |
| [0004](0004-pgbackrest-with-its-repository-on-nfs.md) | pgBackRest, with its repository on the NFS share | 2026-10-26 | Accepted |
| [0005](0005-postgresql-on-port-5433.md) | PostgreSQL on port 5433 | 2026-10-05 | Accepted |
| [0006](0006-autofs-for-the-nfs-share.md) | autofs for the NFS share on db1 | 2026-10-07 | Accepted |
