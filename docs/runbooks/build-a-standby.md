# Build a standby with pg_basebackup

## When to use

When db2 needs a new read-only copy of db1 that streams WAL from it. How replication is set up: [PostgreSQL, Replication](../architecture/postgresql.md#replication).

## Before you start

- The Ansible role `postgresql` has run on db1. It keeps the role `replicator`, the slot `db2` and the `pg_hba.conf` rule for `replicator` from db2, see [Ansible](../architecture/ansible.md).
- `ansible/inventory/host_vars/db2.yml` has `postgresql_build_standby: true` and `postgresql_peer_address: 192.168.122.11`.
- The Vault value `postgresql_replicator_password` is the password of `replicator` on db1.
- `/pgdata` on db2 has room for a second copy beside the old one (`df -h /pgdata`).

## Steps

1. **db2**: stop the server.

   ```bash
   sudo systemctl stop postgresql
   ```

2. **db2**: move the old data directory aside. The role copies db1 only when `/pgdata/pgsql/data/PG_VERSION` is missing.

   ```bash
   sudo mv /pgdata/pgsql/data /pgdata/pgsql/data.old
   ```

3. **desktop**: run the playbook for db2 only, from `ansible/`, with no dry run first: on a missing data directory a dry run fails at the first file it would write there. The role copies db1 with `pg_basebackup` through the slot `db2` and `sslmode=verify-full`, writes `postgresql.auto.conf` and `standby.signal`, and starts the server.

   ```bash
   ansible-playbook playbooks/postgresql.yml --limit db2
   ```

4. **db2**: once the checks below pass, remove the old data directory.

   ```bash
   sudo rm -rf /pgdata/pgsql/data.old
   ```

## Check

- On db1, `pg_stat_replication` shows `192.168.122.12`, `streaming` and `async`, and the slot `db2` is active with `wal_status` `reserved`.
- On db2, `postgresql.auto.conf` has `primary_slot_name = 'db2'` and a `primary_conninfo` to `192.168.122.11` with `sslmode=verify-full`.
- Row counts and sums in `lab` are the same on both hosts.
- A second run of the playbook shows `changed=0` for db2.
- `checks/15-replication.sh` passes on both hosts and `checks/20-postgresql-templates.sh` on the desktop.

Last tested: 2026-11-07 on db2, about 205 MB copied in 2 s, streaming 19 s after the playbook started
