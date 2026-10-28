# System settings on every host

SELinux, the firewall, tuned, the persistent journal, and the DBA group with its shared directory.

Verified by: [`checks/05-storage.sh`](../../checks/05-storage.sh) (journal), [`checks/08-tuned-dba.sh`](../../checks/08-tuned-dba.sh) (tuned, `dba`), [`checks/13-pitr.sh`](../../checks/13-pitr.sh) and [`checks/14-pgbackrest.sh`](../../checks/14-pgbackrest.sh) (the SELinux module)
Repo files: [`selinux/pg_archive_nfs.te`](../../selinux/pg_archive_nfs.te), [`tuned/`](../../tuned/)

## Setup

### SELinux

Enforcing on every host.

| Host | Local change |
|---|---|
| db1, db2 | `/pgdata(/.*)?` → `postgresql_db_t` (`semanage fcontext`, then `restorecon`) |
| db1, db2 | TCP 5433 → `postgresql_port_t` (`semanage port`) |
| db1 | Module `pg_archive_nfs` 1.1: the archiver (`postgresql_t`) may create, write and rename files on the NFS share (`nfs_t`), not delete them. No boolean allows this. Built with [Build an SELinux module from denials](../runbooks/build-an-selinux-module.md). |
| db2 | None. `/srv/backup` keeps `var_t`, the default for `/srv`, and the NFS export booleans are on by default. |

### Firewall

firewalld, zone `public` on every host.

| Host | Allowed |
|---|---|
| nuc | `ssh`, `cockpit` and the other defaults of the zone; `virbr0` is in the zone `libvirt` |
| db1 | `ssh`, `cockpit`, `dhcpv6-client`, `5433/tcp` |
| db2 | `ssh`, `cockpit`, `dhcpv6-client`, `nfs` (NFSv4 only, so `showmount -e` does not work), `5433/tcp` |

### Tuning

Each host has its own tuned profile in `tuned/`, installed as `/etc/tuned/profiles/<name>/tuned.conf`. Each one includes a profile from a package and drops only what fails on that host.

| Host | Profile | Base | Dropped |
|---|---|---|---|
| nuc | `virtual-host-nuc` | `virtual-host` | `[cpu] boost` |
| db1 | `postgresql-guest` | `postgresql` (`tuned-profiles-postgresql`) | `[cpu] boost`, `[scheduler]` |
| db2 | `virtual-guest-lab` | `virtual-guest` | `[cpu] boost` |

### Journal

Persistent on nuc, db1 and db2: drop-in `/etc/systemd/journald.conf.d/50-persistent-storage.conf` with `Storage=persistent`.

### DBA group and shared directory

| Part | Setup |
|---|---|
| Group | `dba`, GID 2000 on db1 and db2. `makilele` is a member, UID 1000 on both. |
| Shared directory | `/srv/dba` on db1, `root:dba`, mode `2770` |
| Default ACL | `default:group:dba:rwx` on `/srv/dba` |

## Why

- `boost` does not exist in a VM, and `intel_pstate` on the nuc has no `boost` file either, so `tuned-adm verify` failed until it was dropped. Turbo stays on.
- The tuned scheduler plugin writes to `debugfs`, which Secure Boot lockdown blocks even for root.
- The GID of `dba` is fixed, because NFS compares numeric IDs, not names.
- setgid and the default ACL give every new file in `/srv/dba` the group `dba` with write access, whatever the creator's umask is.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-08 | `tuned-adm verify` on nuc, db1 and db2, after a reboot | Passes |
| 2026-10-05 | `cp` of a `600` file into `/srv/dba` | The ACL mask became `---` and the group could not read it; `chmod g+rw` fixed it |
| 2026-10-05 | `mv` of a file into `/srv/dba` on the same file system | It kept its own group and got no ACL; `chgrp dba` and `chmod g+rw` fixed it |
