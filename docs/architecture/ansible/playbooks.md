# Ansible playbooks

The playbooks in `playbooks/` run the roles on the group `db`. `restore-test.yml` restores the newest pgBackRest backup on db2 and compares it with the standby.

Checks: [23](../../../checks/23-standby-backup-roles.sh) · Files: [`ansible/playbooks/`](../../../ansible/playbooks/)

## Setup

### Playbooks

| Part | Setup |
|---|---|
| `base.yml` | Role `base` on group `db` ([Role base](base.md)) |
| `storage.yml` | System role `storage` on group `db` ([System role storage](storage.md)) |
| `postgresql.yml` | Role `postgresql` on group `db` ([Role postgresql](postgresql.md)) |
| `nfs.yml` | Role `nfs` on group `db` ([Role nfs](nfs.md)) |
| `pgbackrest.yml` | Role `pgbackrest` on group `db` ([Role pgbackrest](pgbackrest.md)) |

### Restore test

What the test proves: [pgBackRest, Setup](../backups/pgbackrest.md#setup).

| Part | Setup |
|---|---|
| Hosts | db2, as `postgres`, without facts |
| Guard | A copy left by an earlier run stops the play. |
| Restore | A `block` restores the newest backup to `/pgdata/pgsql/restore-test` with `--archive-mode=off`. |
| Start | `pg_ctl` starts the copy on port 5434 with `listen_addresses=''` and `hot_standby=off`. |
| Compare | Four values from `lab`, read on the copy and on the standby. `assert` checks that the copy is out of recovery and has the same values. |
| Cleanup | `always` stops and removes the copy, also after a failed task. |

## Why

- The read of the copy repeats with `until` until it connects, because `pg_ctl -w` returns as soon as the copy starts its recovery. With `hot_standby=off` the copy accepts connections only after the replay and the promote, so the first read already sees the end state.
