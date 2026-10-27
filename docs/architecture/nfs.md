# NFS share

db2 shares `/srv/backup` with db1 over NFS, so that the backups of db1 are not on the same machine as the database. db1 mounts the share with autofs when a program opens it.

Verified by: [`checks/10-nfs.sh`](../../checks/10-nfs.sh) (db1 and db2)

## Setup

### Export on db2

| Part | Setup |
|---|---|
| Package | `nfs-utils` on db2 (server) and db1 (client). Without it, `mount -t nfs` on the client fails with `NFS: mount program didn't pass remote address`. |
| Service | `nfs-server` on db2, enabled |
| Export | `/etc/exports.d/backup.exports`: `/srv/backup 192.168.122.11(rw)`. The defaults apply, among them `sync`, `sec=sys` and `root_squash` (`exportfs -v` shows them all). `/etc/exports` stays empty. |
| Clients | db1 only, by IP. With `sec=sys` the server trusts the UID and GID that the client sends, so no other host may mount the share. |
| Firewall | Service `nfs` (TCP 2049), see [Firewall](system.md#firewall) |
| SELinux | `var_t` on the export and `nfs_t` on the client, see [SELinux](system.md#selinux) |
| Owners | NFS sends numeric IDs. `postgres` (UID 26) and `dba` (GID 2000) have the same IDs on both hosts, so the files have the same owner on db1 and db2. |
| root | `root_squash` maps root on db1 to `nobody` on db2, so root on db1 cannot write to the share. |

### autofs on db1

autofs mounts the share when a program opens it, and unmounts it after 5 minutes without use. Nothing mounts it at boot. `ls /mnt/db2` shows nothing until a program opens `/mnt/db2/backup`.

| Part | Setup |
|---|---|
| Package | `autofs` on db1. Service `autofs`, enabled. |
| Master map | `/etc/auto.master.d/db2.autofs`: `/mnt/db2 /etc/auto.db2`. `/etc/auto.master` is not changed. |
| Map | `/etc/auto.db2`: `backup -rw,sync db2:/srv/backup`. It is an indirect map: the key `backup` becomes `/mnt/db2/backup`. |
| Options | `sync`, so every write waits until db2 confirms it. The dumps are small, so the slower writes do not matter. The rest are the defaults, among them NFSv4.2 and `hard`. |
| Timeout | 300 seconds, the default from `/etc/autofs.conf` |

## Layout

```
/srv/backup          root:root           755    mount point of LV data/backup, exported
├─ pgsql             postgres:dba        2750   for the backups of db1
│   ├─ wal           postgres:dba        2750   archived WAL segments, by hand
│   └─ base          postgres:dba        2750   base backups, one directory each
└─ pgbackrest        postgres:postgres   750    pgBackRest repository
```

What is stored there: [Backups](backups.md).

## Why

- autofs instead of a mount in `/etc/fstab`: the share is mounted only while it is used, and the boot of db1 does not wait for db2. See [ADR 0006](../decisions/0006-autofs-for-the-nfs-share.md).
- db2 runs on the same NUC and SSD, so the share protects against the loss of db1, not of the NUC.
- With `hard`, a write waits while db2 is down instead of failing. For WAL archiving this means the archiver waits and the database keeps working; see the test in [Backups, History](backups.md#history).
