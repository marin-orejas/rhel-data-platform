# Streaming replication

db2 is a read-only standby that streams WAL from db1 over TLS. A failover by hand makes db2 the primary, and `pg_rewind` brings db1 back as its standby.

Checks: [15](../../../checks/15-replication.sh), [16](../../../checks/16-failover.sh) · Managed by: [Role postgresql](../ansible/postgresql.md) · Files: [`scripts/failover-client.sh`](../../../scripts/failover-client.sh)

## Setup

| Part | Setup |
|---|---|
| Type | Physical streaming, asynchronous |
| Standby | db2, copied from db1 with `pg_basebackup` ([Build a standby](../../runbooks/build-a-standby.md)). It answers read-only queries. |
| Connection | `primary_conninfo` on db2: `host=192.168.122.11 port=5433 user=replicator sslmode=verify-full`, the password from `passfile`. db1 has the same with `host=192.168.122.12`, used after a failover. |
| Slot | Physical slot `db2` on db1, capped with `max_slot_wal_keep_size = 1GB` |
| `replicator` | `LOGIN REPLICATION`, on db1 |
| `rewind` | Login, `EXECUTE` on the four file functions `pg_rewind` needs |
| `.pgpass` of `postgres` | On both hosts, with the `replicator` and `rewind` passwords for the other host, mode 600 |
| Archiving | db2 has the same `archive_mode = on` and archive command. A standby does not archive. |
| `pg_rewind` | Possible because data checksums are on, the PostgreSQL 18 default. |
| Client | `scripts/failover-client.sh`, run by hand on db2. It names both servers with `target_session_attrs=read-write`, so libpq picks the one that accepts writes. |

## Layout

Where the writes and the WAL go while db1 is the primary:

```mermaid
flowchart LR
    client["failover-client.sh<br/>on db2"] -- "writes, to the read-write host" --> db1["db1<br/>primary"]
    db1 -- "WAL, slot db2, TLS, 5433" --> db2["db2<br/>standby"]
```

## Why

- [Asynchronous, with a slot capped at 1 GB](../../decisions/asynchronous-replication-with-a-capped-slot.md): a long db2 outage costs a rebuild of db2, not a full `/pgdata` on db1.

## Limits

- Archiving from db2 as a primary is not tested, although db2 has pgBackRest with a local repository ([pgBackRest](../backups/pgbackrest.md)).

## Tested

Lag is read in bytes on db1, from `pg_stat_replication`.

| Date | Test | Result |
|---|---|---|
| 2026-10-27 | `pg_basebackup` from db1 to db2 | 52,552 kB in 0.8 s |
| 2026-10-27 | Lag with nothing written | 0 bytes, but `now() - pg_last_xact_replay_timestamp()` on db2 showed 26 min: the time since the last commit, not lag. |
| 2026-10-27 | Lag during one `INSERT` of 1,000,000 rows on db1 (2.8 s) | Up to 17.9 MB not replayed, `replay_lag` up to 0.33 s, 0 again within 0.5 s |
| 2026-10-27 | db2 stopped while db1 wrote 300,000 rows | The slot kept 47 MB of WAL, and db2 caught up after its start. |
| 2026-10-27 | A read on db2 right after its start | Showed the old data for a moment: a hot standby answers before it has caught up. |
| 2026-10-27 | A write on db2 | `cannot execute CREATE TABLE in a read-only transaction` |
| 2026-10-29 | Failover: PostgreSQL on db1 killed with `kill -9`, db2 promoted by hand ([runbook](../../runbooks/fail-over-to-db2.md)) | Writes stopped for 5 min 51 s, the promotion itself about 1 s. None of the 631 rows db1 confirmed was lost. |
| 2026-10-29 | `pg_rewind` of db1 after the failover | Diverged at `0/340628B8` on timeline 3. Copied 181 MB of 340 MB, then db1 streamed from db2 on timeline 4. |
| 2026-10-29 | Planned switchover back: db2 stopped cleanly, db1 promoted | No `pg_rewind`, db2 followed on timeline 5. Writes stopped for about 6 min, by hand with a pause. The promotion took about 1 s. |
