# 0006. autofs for the NFS share on db1

Date: 2026-10-07
Status: Accepted

## Context

db1 writes its backups to the NFS share from db2. The share could be mounted at boot from `/etc/fstab`, or on demand by autofs. This is a learning lab, and autofs is an RHCSA topic.

## Decision

autofs mounts the share on db1 with an indirect map: `/mnt/db2` in `/etc/auto.master.d/db2.autofs`, the key `backup` in `/etc/auto.db2`, options `-rw,sync`, and the default timeout of 300 seconds. Nothing in `/etc/fstab`.

## Consequences

- The share is mounted only while a backup or the WAL archiver uses it, and is unmounted after 5 minutes without use.
- Nothing mounts the share at boot, so the boot of db1 does not wait for db2.
- systemd does not know the autofs paths, so `RequiresMountsFor=` cannot be used. The backup units have `Wants=` and `After=autofs.service` instead.
- `ls /mnt/db2` shows nothing until a program opens `/mnt/db2/backup`, which can be confusing when the share is checked by hand.

Details: [NFS share](../architecture/nfs.md)
