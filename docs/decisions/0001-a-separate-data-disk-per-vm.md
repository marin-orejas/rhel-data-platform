# 0001. A separate data disk per VM

Date: 2026-10-01
Status: Accepted

## Context

The VMs are clones of `rhel-base`, whose 20 GiB system disk leaves only about 420 MiB free in VG `rhel`. db1 needs room for the PostgreSQL cluster, and db2 for the backups and later a replica. A database that fills the root file system can take the whole host down with it.

## Decision

Each VM gets a second thin qcow2 disk of 10 GiB with its own volume group `data`: LV `pgdata` on `/pgdata` on db1 and LV `backup` on `/srv/backup` on db2, XFS, mounted by UUID. The PostgreSQL unit has `RequiresMountsFor=/pgdata`, and the cluster lives in `/pgdata/pgsql/data`, not on the mount point.

## Consequences

- A full data disk makes PostgreSQL fail its writes, but the root file system and the host keep working. Tested on 2026-10-07: the `INSERT` failed with `No space left on device`.
- The VG keeps free space, so the LV can grow while PostgreSQL runs ([Grow a data volume](../runbooks/grow-a-data-volume.md)). XFS cannot shrink, so it grows in small steps.
- Without the disk, the server does not start, and no cluster can be created on the root disk by mistake.
- One more disk to attach and set up on every new VM.

Details: [VMs, Data disks](../architecture/vms.md#data-disks)
