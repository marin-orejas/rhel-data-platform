# Restore to a set time by hand

## When to use

Only for the archive by hand in `/mnt/db2/backup/pgsql/wal` and `base`, which ends at segment `00000002000000000000000E`. Every later time is in the pgBackRest repository: use [Restore to a set time with pgBackRest](restore-to-a-time-with-pgbackrest.md). The archive by hand: [Backups, History](../architecture/backups.md#history).

## Before you start

- The target time, with the time zone offset. The replay stops before the first commit after it.
- The base backup directory that ended before the target. In the commands below, `<stamp>` is its name, for example `2026-10-25_1613`.
- The restore goes in place on db1. The broken cluster is moved aside, not deleted, so the restore can be undone.

## Steps

1. **db1**: stop the server.

   ```bash
   sudo systemctl stop postgresql
   ```

2. **db1**: move the broken cluster aside and create an empty data directory.

   ```bash
   sudo -iu postgres mv /pgdata/pgsql/data /pgdata/pgsql/data-broken
   sudo -iu postgres mkdir -m 700 /pgdata/pgsql/data
   ```

3. **db1**: extract the base backup, and its WAL into `pg_wal`. The files get `postgresql_db_t` from `/pgdata`, so `restorecon` is not needed.

   ```bash
   sudo -iu postgres tar -xzf /mnt/db2/backup/pgsql/base/<stamp>/base.tar.gz -C /pgdata/pgsql/data
   sudo -iu postgres tar -xzf /mnt/db2/backup/pgsql/base/<stamp>/pg_wal.tar.gz -C /pgdata/pgsql/data/pg_wal
   ```

4. **db1**: append the recovery settings to `/pgdata/pgsql/data/postgresql.auto.conf` with an editor, because `ALTER SYSTEM` needs a running server. With `pause`, the replay stops at the target and the database stays read-only, so the data can be checked first. Write the target time in place of `<time>`:

   ```
   restore_command = 'cp /mnt/db2/backup/pgsql/wal/%f %p'
   recovery_target_time = '<time>'
   recovery_target_action = 'pause'
   ```

5. **db1**: create `recovery.signal` and start the server.

   ```bash
   sudo -iu postgres touch /pgdata/pgsql/data/recovery.signal
   sudo systemctl start postgresql
   ```

6. **db1**: check the data while the server is paused, then end the recovery.

   ```bash
   sudo -iu postgres psql -c "SELECT pg_wal_replay_resume();"
   ```

7. **db1**: remove the recovery settings.

   ```bash
   sudo -iu postgres psql -c "ALTER SYSTEM RESET restore_command;"
   sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_time;"
   sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_action;"
   ```

## Check

- `SELECT pg_is_in_recovery();` returns `f`, and PostgreSQL has removed `recovery.signal` itself.
- New WAL files start with the next timeline number, and the archive has a `.history` file for it.
- `cp: cannot stat` in the server log for a `.history` file and for the segment after the end of the archive is normal: recovery asks for files that may not exist.

Last tested: 2026-10-26 on db1, a dropped table restored to 4 seconds before the drop, outage 9 min 31 s
