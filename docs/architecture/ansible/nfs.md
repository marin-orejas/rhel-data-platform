# Role nfs

The role `nfs` keeps the NFS export on db2, and autofs and the SELinux module of the archiver on db1.

Checks: [10](../../../checks/10-nfs.sh) · Files: [`ansible/roles/nfs/`](../../../ansible/roles/nfs/)

## Setup

| Part | Setup |
|---|---|
| Server tasks | Where `nfs_exports` is set: db2 ([NFS share, Export on db2](../backups/nfs.md#export-on-db2)) |
| autofs tasks | Where `nfs_autofs_maps` is set: db1 ([NFS share, autofs on db1](../backups/nfs.md#autofs-on-db1)) |
| Reload | A changed file reloads `nfs-server` or `autofs`. |
| SELinux module | `roles/nfs/files/pg_archive_nfs.te`, copied to `/usr/local/share/selinux/` on db1 ([System settings, SELinux](../hosts/system.md#selinux)) |
| Module build | The role builds and loads the module when the copy changes or `semodule -l` does not list it. |

## Why

- The module build runs `cd` inside its command, because `chdir` fails a dry run while the directory does not exist yet.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-06 | Role `nfs` over the export, autofs and module made by hand: `--check --diff`, a run and a second run | Dry run: db2 `changed=0`, db1 `changed=1` (the module source, new on the host). The run loaded the same module 1.1 again. Second run `changed=0`, check 10 passes, and `pgbackrest check` archives to the share. |
