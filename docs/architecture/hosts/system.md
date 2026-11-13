# System settings

Every host runs SELinux in enforcing mode, firewalld, key-only SSH, a tuned profile of its own and a persistent journal. db1 and db2 also have the group `dba`, with a shared directory on db1.

Checks: [05](../../../checks/05-storage.sh), [08](../../../checks/08-tuned-dba.sh), [10](../../../checks/10-nfs.sh), [13](../../../checks/13-pitr.sh), [14](../../../checks/14-pgbackrest.sh), [18](../../../checks/18-base-role.sh) · Managed by: [Role base](../ansible/base.md), [Role nfs](../ansible/nfs.md) · Files: [`tuned/`](../../../tuned/)

## Setup

### SELinux

SELinux is enforcing on every host.

| Part | Setup |
|---|---|
| `/pgdata` label | `/pgdata(/.*)?` → `postgresql_db_t` on db1 and db2 (`semanage fcontext`, then `restorecon`) |
| Port 5433 | TCP 5433 → `postgresql_port_t` on db1 and db2 (`semanage port`) |
| Module `pg_archive_nfs` | Version 1.1 on db1. The archiver (`postgresql_t`) may create, write and rename files on the NFS share (`nfs_t`), not delete them. |
| Module source | Built with [Build an SELinux module from denials](../../runbooks/build-an-selinux-module.md), loaded by the role `nfs` |
| `/srv/backup` on db2 | `var_t`, the default for `/srv`. The NFS export booleans are on by default. |

### Firewall

Every host runs firewalld with the zone `public`.

| Part | nuc | db1 | db2 |
|---|---|---|---|
| Allowed | `ssh`, `cockpit` and the other defaults of the zone | `ssh`, `cockpit`, `dhcpv6-client`, `5433/tcp` | `ssh`, `cockpit`, `dhcpv6-client`, `nfs` (NFSv4 only, no `showmount -e`), `5433/tcp` |
| Other zones | `virbr0` in the zone `libvirt` | None | None |

### SSH

| Part | Setup |
|---|---|
| Login | Key only, no password or root login, on every host |
| Drop-in | `/etc/ssh/sshd_config.d/10-hardening.conf`, read before `50-redhat.conf` |

### Tuning

| Part | nuc | db1, db2 |
|---|---|---|
| Profile | `virtual-host-nuc` | `postgresql-guest` |
| Includes | `virtual-host` | `postgresql` (`tuned-profiles-postgresql`) |
| Dropped | `[cpu] boost` | `[cpu] boost`, `[scheduler]` |
| File | `/etc/tuned/profiles/virtual-host-nuc/tuned.conf`, from `tuned/` | `/etc/tuned/profiles/postgresql-guest/tuned.conf`, from the role `base` |

### Journal

| Part | Setup |
|---|---|
| Storage | Persistent on nuc, db1 and db2 |
| Drop-in | `/etc/systemd/journald.conf.d/50-persistent-storage.conf` with `Storage=persistent` |

### DBA group and shared directory

| Part | Setup |
|---|---|
| Group | `dba`, GID 2000 on db1 and db2. `makilele` is a member, UID 1000 on both. |
| Shared directory | `/srv/dba` on db1, `root:dba`, mode `2770` |
| Default ACL | `default:group:dba:rwx` on `/srv/dba` |

## Why

- `[cpu] boost` is dropped, because a VM has no `boost` and `intel_pstate` on the NUC has no `boost` file either, so `tuned-adm verify` failed. Turbo stays on.
- `[scheduler]` is dropped on db1 and db2, because the plugin writes to `debugfs`, which Secure Boot lockdown blocks even for root.
- A module of its own for the archiver, because no boolean lets `postgresql_t` write to `nfs_t`.
- The GID of `dba` is fixed, because NFS compares numeric IDs, not names.
- `/srv/dba` has setgid and a default ACL, so every new file gets the group `dba` with write access, whatever the umask of its creator.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-05 | `cp` of a `600` file into `/srv/dba` | The ACL mask became `---` and the group could not read it. `chmod g+rw` fixed it. |
| 2026-10-05 | `mv` of a file into `/srv/dba` on the same file system | It kept its own group and got no ACL. `chgrp dba` and `chmod g+rw` fixed it. |
| 2026-10-08 | `tuned-adm verify` on nuc, db1 and db2, after a reboot | Passes on all three. |

## History

- `virtual-guest-lab` (db2, lessons 10–17): `include=virtual-guest`, `[cpu] drop=boost`. Still in `/etc/tuned/profiles/` on db2, not active.
