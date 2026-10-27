# Build a standby with pg_basebackup

## When to use

When db2 needs a new read-only copy of db1 that streams WAL from it. How replication is set up: [PostgreSQL, Replication](../architecture/postgresql.md#replication).

## Before you start

- db2 has `postgresql18-server`, `/pgdata` mounted, the drop-in, the SELinux rules and port 5433 open, as on db1. See [PostgreSQL, Both hosts](../architecture/postgresql.md#both-hosts).
- `/pgdata/pgsql` on db2 is empty, owned by `postgres`, mode 700. The server on db2 is stopped.
- A new password for the role `replicator`.

## Steps

1. **db1**: create the replication role and set its password. In `sudo -iu postgres psql`:

   ```sql
   CREATE ROLE replicator WITH REPLICATION LOGIN;
   \password replicator
   ```

2. **db1**: allow the role from db2, for replication only, and reload.

   ```bash
   echo 'host    replication     replicator      192.168.122.12/32       scram-sha-256' | sudo tee -a /pgdata/pgsql/data/pg_hba.conf
   sudo systemctl reload postgresql
   ```

3. **db1**: create the slot and cap the WAL it may keep. In `sudo -iu postgres psql`:

   ```sql
   SELECT pg_create_physical_replication_slot('db2');
   ALTER SYSTEM SET max_slot_wal_keep_size = '1GB';
   SELECT pg_reload_conf();
   ```

4. **db2**: store the password for the `postgres` user. The database field must be `replication`. `read -s` keeps the password off the screen and out of the shell history.

   ```bash
   read -rsp 'replicator password: ' pw; echo
   printf '192.168.122.11:5433:replication:replicator:%s\n' "$pw" | sudo -u postgres bash -c 'umask 077; cat > /var/lib/pgsql/.pgpass'
   unset pw
   ```

5. **db2**: copy the cluster from db1. `-R` writes `standby.signal` and `primary_conninfo`, and `-S db2` uses the slot and writes `primary_slot_name`.

   ```bash
   sudo -iu postgres pg_basebackup -h 192.168.122.11 -p 5433 -U replicator -D /pgdata/pgsql/data -S db2 -R -X stream -c fast -P
   ```

6. **db2**: check that `primary_conninfo` has `passfile=` and no `password=`.

   ```bash
   sudo tail -5 /pgdata/pgsql/data/postgresql.auto.conf
   ```

7. **db2**: enable and start the server.

   ```bash
   sudo systemctl enable --now postgresql
   ```

## Check

- On db2, `SELECT pg_is_in_recovery();` returns `t`, and `pg_stat_wal_receiver` shows `streaming`, the slot `db2` and the timeline of db1.
- On db1, `pg_stat_replication` shows `192.168.122.12`, `streaming` and `async`, and the slot `db2` is active.
- A row written on db1 is readable on db2. A write on db2 fails with `cannot execute ... in a read-only transaction`.

Last tested: 2026-10-27 on db1 and db2, 52,552 kB copied in 0.8 s, streaming on timeline 3
