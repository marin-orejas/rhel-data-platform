# PostgreSQL on db1 and db2

PostgreSQL 18 from AppStream runs on db1 as the primary and on db2 as a read-only standby that streams WAL from db1. Clients connect to db1 on port 5433. One role from db2 tests remote access.

Verified by: [`checks/06-postgres.sh`](../../checks/06-postgres.sh) (db1), [`checks/07-postgres-remote.sh`](../../checks/07-postgres-remote.sh) (db2)

## Setup

### Both hosts

| Part | Setup |
|---|---|
| Package | `postgresql18-server`, and on db1 `postgresql18-contrib` for `pg_waldump`. RHEL 10 has no modules: each major version has its own package name, and only one version can be installed. |
| Service | `postgresql`, enabled. The vendor unit is not changed. A drop-in, `/etc/systemd/system/postgresql.service.d/override.conf`, sets `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`, so the server does not start without the data disk. |
| Data directory | `/pgdata/pgsql/data`. On db1 it was created with `postgresql-setup --initdb`. On db2 it is a copy of db1, see [Replication](#replication). |
| Settings | `port = 5433` and `listen_addresses = '*'`, set on db1 with `ALTER SYSTEM`. They are in `postgresql.auto.conf`, and `postgresql.conf` stays as `initdb` made it. db2 got both files with the copy. |
| SELinux | Local rules for `/pgdata` and port 5433, and on db1 the module `pg_archive_nfs`, see [SELinux](system.md#selinux). The server runs in the `postgresql_t` domain. |
| Firewall | `5433/tcp` in the `public` zone, see [Firewall](system.md#firewall) |
| Logs | The logging collector, on by default in RHEL, writes the server log to `/pgdata/pgsql/data/log/postgresql-<day>.log`. The journal shows only the first lines of each start. |
| Admin access | `sudo -iu postgres psql`. The postgres user's `/var/lib/pgsql/.bash_profile` (a config file of the package) sets `PGDATA=/pgdata/pgsql/data` and `PGPORT=5433`. |

### db1

| Part | Setup |
|---|---|
| Client authentication | `pg_hba.conf` keeps the default local rules and has two more lines: `host postgres remote_test 192.168.122.12/32 scram-sha-256` and `host replication replicator 192.168.122.12/32 scram-sha-256`. db2 has the same file, copied with the data directory. |
| Roles | `remote_test`: login only, no other attributes. It tests remote access from db2. Its password is stored only in `~/.pgpass` on db2 (mode 600). `replicator`: `LOGIN` and `REPLICATION`, no superuser, for the standby. Its password is stored only in `/var/lib/pgsql/.pgpass` on db2 (owner `postgres`, mode 600). |
| Test data | Database `lab` with the table `items`, 10,000 rows |

### Replication

| Part | Setup |
|---|---|
| Type | Physical streaming replication, asynchronous: db1 confirms a commit without waiting for db2. |
| Standby | db2, built with `pg_basebackup -R` from db1. The empty file `standby.signal` in the data directory keeps it a standby. It accepts read-only queries (`hot_standby = on`, the default). Procedure: [Build a standby with pg_basebackup](../runbooks/build-a-standby.md). |
| Connection | `primary_conninfo` in `postgresql.auto.conf` on db2: `host=192.168.122.11 port=5433 user=replicator`, with the password from `passfile`. |
| Slot | Physical slot `db2` on db1, used through `primary_slot_name = 'db2'` on db2. db1 keeps WAL until db2 has received it. |
| Slot limit | `max_slot_wal_keep_size = 1GB` on db1. If db2 falls further behind, db1 removes the WAL anyway, the slot becomes `lost`, and db2 has to be built again. |
| Other settings | The defaults: `wal_level = replica`, `max_wal_senders = 10`, `max_replication_slots = 10` |
| Archiving | `archive_mode = on` and the pgBackRest `archive_command` came with the copy. A standby with `archive_mode = on` does not archive, so only db1 archives. |

## Layout

```
/pgdata                 root:root           mount point of LV data/pgdata
└─ pgsql                postgres:postgres   700
    └─ data             postgres:postgres   700   the cluster (PGDATA)
```

A connection from db2 must pass four checks on db1:

```
db2                                db1
psql + ~/.pgpass ── TCP 5433 ──►   firewalld     public zone allows 5433/tcp
                                   SELinux       port 5433 → postgresql_port_t
                                   postgres      listens on all addresses, port 5433
                                   pg_hba.conf   remote_test from 192.168.122.12, scram-sha-256
```

Replication from db1 to db2:

```
db1 (primary)                                      db2 (standby, read-only)
walsender ◄── TCP 5433, replicator, slot db2 ───── walreceiver
                                                        │
                                                   startup process replays the WAL
                                                        ▼
                                                   /pgdata/pgsql/data, standby.signal
```

## Why

- The data directory is not the mount point itself, and its parent belongs to `postgres`, as the PostgreSQL docs recommend. If the disk is not mounted, `/pgdata/pgsql/data` does not exist, so nothing can create a cluster on the root disk by mistake. The `postgres`-owned parent leaves room for upgrades, which keep the old cluster next to the new one (`data-old`).
- The server listens on all addresses, not only on the IP of db1. The unit does not wait for the network, so at boot the IP may not exist yet, and the server would start on localhost only. See [ADR 0002](../decisions/0002-listen-on-all-addresses.md).
- Port 5433 instead of the default 5432, to practise moving a service to another port through every layer. The firewalld service `postgresql` is not used, because it opens 5432. See [ADR 0005](../decisions/0005-postgresql-on-port-5433.md).
- db2 has the same data directory, drop-in, SELinux rules and port as db1, so the two hosts can swap roles in a failover without changes on disk.
- `replicator` can only read the WAL stream. `pg_hba.conf` lets it in only for replication and only from db2.
- Replication is asynchronous, and the slot is capped at 1 GB: a standby that is gone for a long time costs a rebuild of db2, not a full `/pgdata` on db1. See [ADR 0007](../decisions/0007-asynchronous-replication-with-a-capped-slot.md).
- Lag is read in bytes on db1: `pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)` from `pg_stat_replication`. The time columns there are empty when nothing is written, and the time since the last replayed commit on db2 grows while db1 is idle.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-27 | `pg_basebackup` from db1 to db2 | 52,552 kB copied in 0.8 s |
| 2026-10-27 | Streaming | db2 streams on timeline 3 through the slot `db2`; a row inserted on db1 is readable on db2 |
| 2026-10-27 | A write on db2 | `CREATE TABLE` fails with `cannot execute CREATE TABLE in a read-only transaction` |
| 2026-10-27 | Lag at rest | 0 bytes not replayed; `write_lag`, `flush_lag` and `replay_lag` empty. On db2, `now() - pg_last_xact_replay_timestamp()` showed 26 min, the time since the last commit on db1. |
| 2026-10-27 | Lag during one `INSERT` of 1,000,000 rows (2.8 s on db1), sampled every 0.5 s | Up to 17.9 MB not replayed and `replay_lag` up to 0.33 s, while the WAL not sent was often 0: the replay on db2 was slower than the network. 0 bytes again within 0.5 s after the `INSERT` ended. |
| 2026-10-27 | db2 stopped while db1 wrote 300,000 rows | The slot kept 47 MB of WAL (`safe_wal_size` 982 MB). After the start, db2 caught up and the slot kept 0 bytes. |
| 2026-10-27 | A read on db2 right after its start | It still showed the data from before the stop (1,000,000 rows instead of 1,300,000): a hot standby accepts queries before it has caught up. |
