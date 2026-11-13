# System role storage

The system role `storage` keeps the data disks of db1 and db2 as `inventory/host_vars/` describes them. Tasks before it in `playbooks/storage.yml` activate the data VG on a fresh clone and stop on an inactive LV, and a task after it sets the SELinux labels.

Checks: [19](../../../checks/19-storage-postgresql.sh), [24](../../../checks/24-fresh-clones.sh) · Files: [`ansible/playbooks/storage.yml`](../../../ansible/playbooks/storage.yml)

## Setup

| Part | Setup |
|---|---|
| Role | `fedora.linux_system_roles.storage` ([Ansible control node](control-node.md)) |
| VG import | `vgimportdevices data && vgchange -ay data`, only when `vgs --devicesfile "" data` finds the VG and `vgs data` does not ([VMs, Data disks](../hosts/vms.md#data-disks)) |
| Guard | The play stops when `lvs -o lv_active_locally data` shows an inactive LV. It is skipped when the disk has no VG `data`. |
| Safe mode | `storage_safe_mode: true` in `playbooks/storage.yml` |
| Disks | `storage_pools` in each host's file in `inventory/host_vars/` ([VMs, Data disks](../hosts/vms.md#data-disks)) |
| blivet | `python3-blivet`, `vdo` and the `libblockdev` plugins, installed by the role in a real run. A dry run needs them on the host already. |
| SELinux labels | `restorecon -Rv` on each mount point of `storage_pools`, `changed` only when it relabels a file |

## Why

- The data disks use the system role `storage` with safe mode on, so a wrong description fails instead of formatting a volume with data. The layout is in `host_vars`, because db1 and db2 have different volumes.
- The play adds the data disk to the LVM devices file, because LVM ignores a disk the file does not list, and a clone of `rhel-base` lists only `vda3`. The devices file stays on, so LVM still skips disks the host does not own.
- The play runs `restorecon` after the role, because a new XFS from the role is `unlabeled_t`, and PostgreSQL cannot open `/pgdata` until the rule from the role `base` is applied.

## Limits

- The system role formats an existing LV that is not active, despite `storage_safe_mode`, because blivet sees no file system on it. The guard stops the play first, so the role runs only through `playbooks/storage.yml`.
- The tasks before the role name the VG `data`, as both hosts do in `inventory/host_vars/`. A pool with another name gets no import and no guard.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-31 | Role `storage` on the data disks built by hand: `--check --diff`, then a run | The dry run changed no disk and no line in `/etc/fstab`. The run reported `changed=0` on db1 and db2. |
