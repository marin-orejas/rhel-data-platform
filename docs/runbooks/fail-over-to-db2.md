# Fail over to db2 and bring db1 back

## When to use

When PostgreSQL on db1 has failed and db2 must take over the writes, and later to make db1 the primary again. How replication is set up: [PostgreSQL, Replication](../architecture/postgresql.md#replication).

## Before you start

- db2 streams from db1, and data checksums are on, so `pg_rewind` can run.
- `pg_hba.conf` is the same on both hosts and lets the other host in as `replicator` and `rewind`. `/var/lib/pgsql/.pgpass` on each host holds both passwords for the other host.
- The client names both servers with `target_session_attrs=read-write`, so it follows the primary without a change.

## Steps

1. **db1**: keep PostgreSQL from starting again, by hand or at boot.

   ```bash
   sudo systemctl mask postgresql
   ```

2. **db2**: check that everything received is replayed: `all_replayed` must be `t`.

   ```bash
   sudo -iu postgres psql -c "SELECT pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() AS all_replayed"
   ```

3. **db2**: promote. It answers `t` and starts a new timeline.

   ```bash
   sudo -iu postgres psql -c 'SELECT pg_promote()'
   ```

4. **db2**: create the slot for db1.

   ```bash
   sudo -iu postgres psql -c "SELECT pg_create_physical_replication_slot('db1')"
   ```

5. **db1**: rewind to db2. After a crash, `--dry-run` fails with `target server must be shut down cleanly`, because only the real run does the crash recovery.

   ```bash
   sudo -iu postgres pg_rewind -D /pgdata/pgsql/data --source-server="host=192.168.122.12 port=5433 dbname=postgres user=rewind" --progress
   ```

6. **db1**: `pg_rewind` copied `postgresql.auto.conf` from db2, which points at db1 itself. Point it at db2 and the slot `db1`.

   ```bash
   sudo -u postgres sed -i -e '/^primary_conninfo/d' -e '/^primary_slot_name/d' /pgdata/pgsql/data/postgresql.auto.conf
   printf '%s\n' "primary_conninfo = 'host=192.168.122.12 port=5433 user=replicator passfile=''/var/lib/pgsql/.pgpass'''" "primary_slot_name = 'db1'" | sudo -u postgres tee -a /pgdata/pgsql/data/postgresql.auto.conf
   ```

7. **db1**: start as a standby.

   ```bash
   sudo -u postgres touch /pgdata/pgsql/data/standby.signal
   sudo systemctl unmask postgresql
   sudo systemctl start postgresql
   ```

8. **db1**: `pg_rewind` emptied `pg_replslot`. Create the slot for db2 again, for the way back.

   ```bash
   sudo -iu postgres psql -c "SELECT pg_create_physical_replication_slot('db2')"
   ```

9. **db2**: to switch back, stop cleanly and make db2 a standby before anything else.

   ```bash
   sudo systemctl stop postgresql
   sudo -u postgres touch /pgdata/pgsql/data/standby.signal
   ```

10. **db2**: read the shutdown checkpoint. The state must be `shut down`.

    ```bash
    sudo -iu postgres pg_controldata -D /pgdata/pgsql/data | grep -E 'cluster state|Latest checkpoint location'
    ```

11. **db1**: check that `pg_last_wal_replay_lsn()` is at or past that checkpoint, then promote. No `pg_rewind` is needed after a clean stop.

    ```bash
    sudo -iu postgres psql -c 'SELECT pg_last_wal_replay_lsn()' -c 'SELECT pg_promote()'
    ```

12. **db2**: start as a standby. Its `primary_conninfo` from `pg_basebackup -R` already points at db1 and the slot `db2`. Then drop the slot `db1`.

    ```bash
    sudo systemctl start postgresql
    sudo -iu postgres psql -c "SELECT pg_drop_replication_slot('db1')"
    ```

## Check

- The client log shows `ok` lines on the new primary, and no ID it confirmed before the switch is missing there.
- The standby shows `walreceiver streaming` and the primary `walsender replicator … streaming` at the same position. On db1 as the primary, [`checks/15-replication.sh`](../../checks/15-replication.sh) passes.

Last tested: 2026-10-29 on db1 and db2, failover in 5 min 51 s with no rows lost, back to db1 without `pg_rewind`
