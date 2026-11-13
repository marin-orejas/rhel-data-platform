# Role pgdump

The role `pgdump` keeps the nightly dumps on db1 and their directory on the NFS share of db2.

Checks: [09](../../../checks/09-backup.sh), [24](../../../checks/24-fresh-clones.sh) · Files: [`ansible/roles/pgdump/`](../../../ansible/roles/pgdump/)

## Setup

| Part | Setup |
|---|---|
| Keeps | `bzip2`, `pg-backup.sh`, `pg-backup.service` from a template and `pg-backup.timer` ([Nightly dumps](../backups/dumps.md#setup)) |
| Destination | `pgdump_dest` in each host's file in `inventory/host_vars/`, the argument of `pg-backup.sh` in the service |
| Dump directory | Made where `pgdump_create_dest` is true (db2) |
| Dumps | Where `pgdump_enabled` is true (db1), with the timer enabled and started |
| Reload | A changed unit file reloads systemd before the timer starts. |
