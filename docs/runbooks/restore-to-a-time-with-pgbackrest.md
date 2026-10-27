# Restore to a set time with pgBackRest

## When to use

When a change destroyed data in the cluster on db1, such as a dropped table, and the whole cluster must go back to a time just before it. Everything written after that time is lost, in every database. To bring back only one database, use [Restore a database from a nightly dump](restore-a-database-from-a-dump.md). How pgBackRest is set up: [Backups, pgBackRest](../architecture/backups.md#pgbackrest).

## Before you start

- The target time, with the time zone offset, for example `2026-10-26 20:04:35.598575+01`. In the commands below it is `<time>`. The replay stops before the first commit after it.
- A backup that ended before the target. pgBackRest picks the newest one itself.

## Steps

1. **db1**: make sure that the WAL with the bad commit is in the archive. `check` switches to a new segment and waits until it is archived. Without that segment, the replay cannot see where to stop.

   ```bash
   sudo -iu postgres pgbackrest --stanza=main check
   ```

2. **db1**: stop the server.

   ```bash
   sudo systemctl stop postgresql
   ```

3. **db1**: restore over the existing data directory. `--delta` compares the checksum of every file with the backup, replaces the files that differ and removes the ones that are not in it. pgBackRest writes `restore_command = 'pgbackrest --stanza=main archive-get %f "%p"'`, `recovery_target_time` and `recovery_target_action = 'promote'` to `postgresql.auto.conf` and creates `recovery.signal`.

   ```bash
   sudo -iu postgres pgbackrest --stanza=main --delta --type=time "--target=<time>" --target-action=promote restore
   ```

4. **db1**: start the server. It replays the WAL up to the target and promotes.

   ```bash
   sudo systemctl start postgresql
   ```

5. **db1**: remove the recovery settings, so that a later recovery or a replica does not inherit the old target.

   ```bash
   sudo -iu postgres psql -c "ALTER SYSTEM RESET restore_command;"
   sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_time;"
   sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_action;"
   ```

6. **db1**: take a new full backup on the new timeline.

   ```bash
   sudo systemctl start pgbackrest@full.service
   ```

## Check

- `SELECT pg_is_in_recovery();` returns `f`.
- The lost data is back, and the other tables have their row counts and `sum(id)` from before.
- New WAL files start with the next timeline number (`00000003` after the test).
- `journalctl -u pgbackrest@full.service` shows the new full backup finished.

Last tested: 2026-10-26 on db1, `pgbr_test` (300,000 rows) back after a drop, outage 1.1 s
