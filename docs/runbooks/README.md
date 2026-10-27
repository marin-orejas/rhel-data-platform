# Runbooks

Procedures that were run and checked on the lab. Each one ends with the date of its last test. What the procedures act on is in [Architecture](../architecture/).

| Runbook | When to use | Last tested |
|---|---|---|
| [Clone a VM from the base image](clone-a-vm.md) | a new VM from `rhel-base` | 2026-09-29 |
| [Grow a data volume while PostgreSQL runs](grow-a-data-volume.md) | `/pgdata` is close to full | 2026-10-07 |
| [Restore a database from a nightly dump](restore-a-database-from-a-dump.md) | one database back to 02:00 | 2026-10-07 |
| [Restore to a set time with pgBackRest](restore-to-a-time-with-pgbackrest.md) | the cluster back to a time before a bad change | 2026-10-26 |
| [Restore to a set time by hand](restore-to-a-time-by-hand.md) | a time in the old archive by hand | 2026-10-26 |
| [Build an SELinux module from denials](build-an-selinux-module.md) | SELinux blocks a service and no boolean helps | 2026-10-26 |
| [Build a standby with pg_basebackup](build-a-standby.md) | a new read-only copy of db1 on db2 | 2026-10-27 |
