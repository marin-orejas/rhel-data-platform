# Ansible playbooks

The playbooks in `playbooks/` run the roles on the group `db`. `site.yml` builds db1 and db2 from fresh clones, and `restore-test.yml` restores the newest pgBackRest backup on db2 and compares it with the standby. GitHub Actions checks the code on every push.

Checks: [23](../../../checks/23-standby-backup-roles.sh), [24](../../../checks/24-fresh-clones.sh) · Files: [`ansible/playbooks/`](../../../ansible/playbooks/), [`.github/workflows/ansible.yml`](../../../.github/workflows/ansible.yml)

## Setup

### Playbooks

| Part | Setup |
|---|---|
| `bootstrap.yml` | The users tasks of the role `base`, run once on a fresh clone with `-u makilele -K`. They make the user `ansible` that the other playbooks log in as. |
| `site.yml` | Imports the six playbooks below in this order, with one `PLAY RECAP` for both hosts. |
| `base.yml` | Role `base` on group `db` ([Role base](base.md)) |
| `storage.yml` | System role `storage` on group `db`, with tasks before it for the data VG and after it for the SELinux labels ([System role storage](storage.md)) |
| `postgresql.yml` | Role `postgresql` on group `db` ([Role postgresql](postgresql.md)) |
| `nfs.yml` | Role `nfs` on group `db` ([Role nfs](nfs.md)) |
| `pgbackrest.yml` | Role `pgbackrest` on group `db` ([Role pgbackrest](pgbackrest.md)) |
| `pgdump.yml` | Role `pgdump` on group `db` ([Role pgdump](pgdump.md)) |

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

### GitHub Actions

| Part | Setup |
|---|---|
| Workflow | `.github/workflows/ansible.yml`, on a push that changes `ansible/` or the workflow |
| Runner | `ubuntu-24.04`, Python 3.14, `ansible-core` 2.20.7 and `ansible-lint` 26.10.1 from pip |
| Collections | `requirements.yml`, the versions of the [Ansible control node](control-node.md#setup) |
| Vault | The runner has no Vault password. A dummy password file lets the syntax check start, and nothing in the checks decrypts. |
| Syntax check | `--syntax-check` of `site.yml`, `bootstrap.yml` and `restore-test.yml` |
| Lint | `ansible-lint`, with `offline: true` in `.ansible-lint` |

## Why

- `base` comes first in `site.yml` and the backups last, because each role needs what an earlier one made: `/pgdata` for `postgresql`, the user `postgres` for the pgBackRest repository, and the share for `archive-push` on db1.
- `bootstrap.yml` is a playbook of its own, so `site.yml` never needs a password.
- The read of the copy repeats with `until` until it connects, because `pg_ctl -w` returns as soon as the copy starts its recovery. With `hot_standby=off` the copy accepts connections only after the replay and the promote, so the first read already sees the end state.

## Limits

- The inventory fixes db1 as the primary: `pgbackrest_timers`, `pgdump_enabled` and `postgresql_build_standby` name the hosts. After a failover, a run would start the data disk of db1 as a second primary and keep the backups on db1, and no runbook step moves them to db2 yet.
- CI runs only the syntax check and `ansible-lint`, and `ansible-lint` runs only there. A dry run and a real run need the hosts, so they run from the desktop, and a lint finding shows only after the push.
- One dry run of `site.yml` before the first reboot of the fresh clones reported a change that was not captured. It did not come back after the reboot.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-11 | GitHub Actions on a push: syntax check and `ansible-lint` | 1 min 0 s, 0 failures, profile `production` (run 43091095974). The first run failed with 18 findings, all fixed in the code. |
| 2026-11-12 | `site.yml` on fresh clones of `rhel-base` with the old data disks ([runbook](../../runbooks/rebuild-the-db-hosts-from-fresh-clones.md)) | db1 3 min 46 s, `changed=49`. After the fixes in [System role storage](storage.md), the second run took 1 min 38 s with `changed=0` on both. |
