# NFS share

db2 shares `/srv/backup` with db1 over NFS, so the backups of db1 are not on the same machine as the database. db1 mounts the share with autofs when a program opens it.

Verified by: [`checks/10-nfs.sh`](../../checks/10-nfs.sh) (db1 and db2)

## Setup

### Export on db2

| Part | Setup |
|---|---|
| Package | `nfs-utils` on db2 and db1 |
| Service | `nfs-server` on db2, enabled |
| Export | `/etc/exports.d/backup.exports`: `/srv/backup 192.168.122.11(rw)`, the other options default (`sync`, `sec=sys`, `root_squash`) |
| Firewall, SELinux | Service `nfs`, `var_t` on the export, see [System settings](system.md) |
| Owners | `postgres` (UID 26) and `dba` (GID 2000) have the same IDs on both hosts |

### autofs on db1

| Part | Setup |
|---|---|
| Package | `autofs`, service enabled |
| Master map | `/etc/auto.master.d/db2.autofs`: `/mnt/db2 /etc/auto.db2` |
| Map | `/etc/auto.db2`: `backup -rw,sync db2:/srv/backup`, so the share is `/mnt/db2/backup` |
| Unmount | After 300 s without use, the default |

## Layout

```
/srv/backup          root:root           755    mount point of LV data/backup, exported
├─ pgsql             postgres:dba        2750   nightly dumps
│   ├─ wal           postgres:dba        2750   WAL archive by hand, no longer written
│   └─ base          postgres:dba        2750   base backups by hand, no longer written
└─ pgbackrest        postgres:postgres   750    pgBackRest repository
```

What is stored there: [Backups](backups.md).

## Why

- Only db1 may mount the share: with `sec=sys` the server trusts the UID that the client sends.
- autofs instead of `/etc/fstab`, so the boot of db1 does not wait for db2. See [ADR 0006](../decisions/0006-autofs-for-the-nfs-share.md).
- `hard` (the default) makes a write wait while db2 is down instead of failing, see the test in [Backups](backups.md#tested).
- db2 runs on the same NUC and SSD, so the share protects against the loss of db1, not of the NUC.
