# PostgreSQL on db1 and db2

PostgreSQL 18 runs on db1 as the primary and on db2 as a read-only standby that streams WAL from db1. Clients connect to db1 on port 5433.

Verified by: [`checks/06-postgres.sh`](../../checks/06-postgres.sh) (db1 and db2), [`checks/07-postgres-remote.sh`](../../checks/07-postgres-remote.sh) (db2), [`checks/15-replication.sh`](../../checks/15-replication.sh) (db1 and db2), [`checks/16-failover.sh`](../../checks/16-failover.sh) (db2)

Repo files: [`scripts/failover-client.sh`](../../scripts/failover-client.sh)

## Setup

### Both hosts

| Part | Setup |
|---|---|
| Package | `postgresql18-server` from AppStream; on db1 also `postgresql18-contrib` for `pg_waldump` |
| Service | `postgresql`, enabled. Drop-in `postgresql.service.d/override.conf` with `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`. |
| Settings | `port = 5433` and `listen_addresses = '*'` in `postgresql.auto.conf`, set with `ALTER SYSTEM` |
| SELinux, firewall | Rules for `/pgdata` and port 5433, `5433/tcp` open, see [System settings](system.md) |
| Logs | `/pgdata/pgsql/data/log/postgresql-<day>.log` |
| Admin access | `sudo -iu postgres psql`; `/var/lib/pgsql/.bash_profile` sets `PGDATA` and `PGPORT=5433` |

### db1

| Part | Setup |
|---|---|
| `pg_hba.conf` | Lines for db2 (`192.168.122.12/32`, `scram-sha-256`): `remote_test` to `postgres` and `lab`, `rewind` to `postgres`, `replicator` for replication |
| Roles | `remote_test` (login, `SELECT` and `INSERT` on `lab.failover_test`), `replicator` (`LOGIN REPLICATION`), `rewind` (login, `EXECUTE` on the four file functions `pg_rewind` needs). Passwords only in `.pgpass` files, mode 600. |
| Test data | Database `lab` with the tables `items` (10,000 rows) and `failover_test`, written by the failover client |

### Replication

| Part | Setup |
|---|---|
| Type | Physical streaming, asynchronous |
| Standby | db2, built with `pg_basebackup -R`, see [Build a standby](../runbooks/build-a-standby.md). It answers read-only queries. |
| Connection | `primary_conninfo` on db2: `host=192.168.122.11 port=5433 user=replicator`, the password from `passfile` |
| Slot | Physical slot `db2` on db1, capped with `max_slot_wal_keep_size = 1GB` |
| Archiving | db2 has `archive_mode = on` from the copy. A standby does not archive, and as a primary db2 fails with exit code 127, because pgBackRest is only on db1. |
| `pg_hba.conf` on db2 | Copied from db1, plus db1 (`192.168.122.11/32`) as `replicator` and `rewind`, and `remote_test` to `lab` from db2 itself |
| `.pgpass` of `postgres` | On both hosts, with the `replicator` and `rewind` passwords for the other host |
| `pg_rewind` | Possible because data checksums are on, the PostgreSQL 18 default |
| Client | `scripts/failover-client.sh`, run by hand on db2. It names both servers with `target_session_attrs=read-write`, so libpq picks the one that accepts writes. |

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

## Why

- The cluster is one level below the mount point. If the disk is not mounted, `/pgdata/pgsql/data` does not exist, so no cluster gets created on the root disk by mistake.
- The server listens on all addresses, because the unit does not wait for the network. See [ADR 0002](../decisions/0002-listen-on-all-addresses.md).
- Port 5433, to practise moving a service through SELinux, the firewall and the clients. See [ADR 0005](../decisions/0005-postgresql-on-port-5433.md).
- db2 has the same data directory, drop-in, SELinux rules and port as db1, so the two can swap roles in a failover.
- Asynchronous, with a slot capped at 1 GB: a long db2 outage costs a rebuild of db2, not a full `/pgdata` on db1. See [ADR 0007](../decisions/0007-asynchronous-replication-with-a-capped-slot.md).

## Tested

Lag is read in bytes on db1, from `pg_stat_replication`.

| Date | Test | Result |
|---|---|---|
| 2026-10-27 | `pg_basebackup` from db1 to db2 | 52,552 kB in 0.8 s |
| 2026-10-27 | Lag with nothing written | 0 bytes, but `now() - pg_last_xact_replay_timestamp()` on db2 showed 26 min: the time since the last commit, not lag |
| 2026-10-27 | Lag during one `INSERT` of 1,000,000 rows on db1 (2.8 s) | Up to 17.9 MB not replayed, `replay_lag` up to 0.33 s, 0 again within 0.5 s |
| 2026-10-27 | db2 stopped while db1 wrote 300,000 rows | The slot kept 47 MB of WAL, and db2 caught up after its start |
| 2026-10-27 | A read on db2 right after its start | Showed the old data for a moment: a hot standby answers before it has caught up |
| 2026-10-27 | A write on db2 | `cannot execute CREATE TABLE in a read-only transaction` |
| 2026-10-29 | Failover: PostgreSQL on db1 killed with `kill -9`, db2 promoted by hand, see [Fail over to db2](../runbooks/fail-over-to-db2.md) | Writes stopped for 5 min 51 s, the promotion itself about 1 s; none of the 631 rows db1 confirmed was lost |
| 2026-10-29 | `pg_rewind` of db1 after the failover | Diverged at `0/340628B8` on timeline 3; copied 181 MB of 340 MB; db1 streamed from db2 on timeline 4 |
| 2026-10-29 | Planned switchover back: db2 stopped cleanly, db1 promoted | No `pg_rewind`, db2 followed on timeline 5. Writes stopped for about 6 min, by hand with a pause; the promotion about 1 s |
