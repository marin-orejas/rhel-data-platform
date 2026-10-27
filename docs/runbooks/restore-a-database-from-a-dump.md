# Restore a database from a nightly dump

## When to use

To bring back one database, or to look at an old copy of it next to the live one. A dump restores the state of the nightly run at 02:00. To restore the whole cluster to a set time, use [Restore to a set time with pgBackRest](restore-to-a-time-with-pgbackrest.md). How the dumps are made: [Backups, Nightly dumps](../architecture/backups.md#nightly-dumps).

## Before you start

- The dumps are in `/mnt/db2/backup/pgsql` on db1. autofs mounts the share when it is opened.
- Pick the dump by its stamp: `ls /mnt/db2/backup/pgsql/lab-*.sql.gz`. In the commands below, `<stamp>` is that part of the file name, for example `2026-10-07_0200`.

## Steps

1. **db1**: create an empty database for the restore.

   ```bash
   sudo -iu postgres createdb lab_restore
   ```

2. **db1**: load the dump into it. `ON_ERROR_STOP=1` stops psql at the first error and gives a non-zero exit code. It is a psql variable, so it goes with `-v`, not `-c`.

   ```bash
   zcat /mnt/db2/backup/pgsql/lab-<stamp>.sql.gz | sudo -iu postgres psql -v ON_ERROR_STOP=1 -d lab_restore
   ```

## Check

The row count and `sum(id)` of each table match the original: `SELECT count(*), sum(id) FROM items;` in `lab` and in `lab_restore`.

Last tested: 2026-10-07 on db1, `lab` restored from a dump on db2, row count and `sum(id)` matched
