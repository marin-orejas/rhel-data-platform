# Grow a data volume while PostgreSQL runs

## When to use

When `/pgdata` on db1 (LV `data/pgdata`) is close to full and VG `data` still has free space. The same steps work for `data/backup` on db2. The layout of the data disks: [VMs, Data disks](../architecture/vms.md#data-disks).

## Before you start

- XFS grows while it is mounted but cannot shrink, so the LV grows in small steps.
- `lvextend` takes the LV (`data/pgdata`, `/dev/data/pgdata` or `/dev/mapper/data-pgdata`), not the mount point.
- `-L 7G` is the new absolute size, and `-L +1G` grows by 1 GiB. `lvextend` never shrinks, so an absolute size smaller than the LV changes nothing.

## Steps

1. **db1**: check the free space in the VG and the size of the LV.

   ```bash
   sudo vgs data
   sudo lvs data
   ```

2. **db1**: grow the LV and its file system in one step. `-r` runs `xfs_growfs`, and without it `df` and PostgreSQL still see the old size.

   ```bash
   sudo lvextend -r -L 7G data/pgdata
   ```

## Check

- `df -h /pgdata` and `sudo lvs data` show the new size.
- A `psql` session that was open during the extend has the same `pg_backend_pid()` before and after it.
- The file system UUID is the same, so `/etc/fstab` does not change. `checks/05-storage.sh` expects the new size and passes after a reboot.

Last tested: 2026-10-07 on db1, `pgdata` grown from 5 GiB to 7 GiB with an open `psql` session
