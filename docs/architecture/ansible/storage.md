# System role storage

The system role `storage` keeps the data disks of db1 and db2 as `inventory/host_vars/` describes them.

Checks: [19](../../../checks/19-storage-postgresql.sh) · Files: [`ansible/playbooks/storage.yml`](../../../ansible/playbooks/storage.yml)

## Setup

| Part | Setup |
|---|---|
| Role | `fedora.linux_system_roles.storage` ([Ansible control node](control-node.md)) |
| Safe mode | `storage_safe_mode: true` in `playbooks/storage.yml` |
| Disks | `storage_pools` in each host's file in `inventory/host_vars/` ([VMs, Data disks](../hosts/vms.md#data-disks)) |
| blivet | `python3-blivet` and the `libblockdev` plugins on db1 and db2. The role needs them also in a dry run. |

## Why

- The data disks use the system role `storage` with safe mode on, so a wrong description fails instead of formatting a volume with data. The layout is in `host_vars`, because db1 and db2 have different volumes.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-31 | Role `storage` on the data disks built by hand: `--check --diff`, then a run | The dry run changed no disk and no line in `/etc/fstab`. The run reported `changed=0` on db1 and db2. |
