# 0007. Asynchronous streaming replication with a capped slot

Date: 2026-10-27
Status: Accepted

## Context

db2 needs a copy of db1 that follows every change, for read-only queries now and for a failover later. Streaming replication can be synchronous, where db1 waits for db2 before it confirms a commit, or asynchronous. The standby can keep up through a replication slot on db1, through `wal_keep_size` (a fixed amount of WAL kept on db1), or by fetching old WAL from the archive. A slot without a limit keeps WAL on db1 for as long as db2 is away. db1 has a 7 GiB `/pgdata`, and pgBackRest runs only on db1.

## Decision

Physical streaming replication from db1 to db2, asynchronous. db2 uses the physical slot `db2` on db1, capped with `max_slot_wal_keep_size = 1GB`. db2 has no `restore_command`, so it does not fetch WAL from the archive.

## Consequences

- A commit on db1 does not wait for db2, and db1 keeps working when db2 is down.
- A crash of db1 can lose the commits that have not reached db2 yet. Under a bulk load of 1,000,000 rows, db2 was up to 17.9 MB and 0.33 s behind.
- While db2 is down, the slot keeps its WAL on db1: 47 MB for 300,000 rows in the test.
- If db2 falls more than 1 GB behind, db1 removes the WAL, the slot becomes `lost`, and db2 must be built again with `pg_basebackup`. db1 never fills `/pgdata` because of the standby.
- A synchronous standby on the same NUC would protect nothing extra against a NUC failure, but would slow every commit and stop writes when db2 is down.

Details: [PostgreSQL, Replication](../architecture/postgresql.md#replication)
