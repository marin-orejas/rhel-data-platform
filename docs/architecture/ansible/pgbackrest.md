# Role pgbackrest

The role `pgbackrest` keeps pgBackRest and its backup timers on db1 and db2, with the timers on only where the backups run.

Checks: [14](../../../checks/14-pgbackrest.sh), [23](../../../checks/23-standby-backup-roles.sh) · Files: [`ansible/roles/pgbackrest/`](../../../ansible/roles/pgbackrest/)

## Setup

| Part | Setup |
|---|---|
| Keeps | The PGDG key, `pgdg-common.repo`, the package, `/etc/pgbackrest.conf` from a template, the service and both timers ([pgBackRest](../backups/pgbackrest.md#setup)) |
| PGDG key | `roles/pgbackrest/files/PGDG-RPM-GPG-KEY-RHEL`, imported by `rpm_key` only when its fingerprint matches the one in the task |
| Timers | Enabled where `pgbackrest_timers` is true (db1). Elsewhere they are disabled and stopped. |
| Repository directory | Made where `pgbackrest_create_repo` is true (db2) |
| Repository path | `pgbackrest_repo_path` in each host's file in `inventory/host_vars/` |

## Why

- The timers run only on db1, so only the primary takes backups, and a timer started by hand on db2 is stopped by the next run. db2 has the same package and config, because it archives with `pgbackrest` after a failover.
- The PGDG key is kept in the role and imported only with its fingerprint, so a different key file fails the run instead of being trusted.

## Limits

- A dry run on a new host fails at the key import: the copy of the key is only reported, so `rpm_key` finds no file. A dry run is for a host that already has pgBackRest.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-06 | Role `pgbackrest` over pgBackRest set up by hand on db1: `--check --diff`, a run and a second run | Dry run: db1 `changed=1` (the `# Ansible managed` line in `/etc/pgbackrest.conf`), db2 failed at the key import. The run installed pgBackRest 2.60.0 on db2 with the timers disabled. Second run `changed=0`. `pgbackrest info` on db2 reads the local repository, `pgbackrest check` on db1 archives to the share. |
