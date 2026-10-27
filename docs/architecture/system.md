# System settings on every host

Settings that every host has in its own form: SELinux, the firewall, tuned, the persistent journal, and the DBA group with its shared directory.

Verified by: [`checks/05-storage.sh`](../../checks/05-storage.sh) (journal), [`checks/08-tuned-dba.sh`](../../checks/08-tuned-dba.sh) (tuned, `dba`), [`checks/13-pitr.sh`](../../checks/13-pitr.sh) and [`checks/14-pgbackrest.sh`](../../checks/14-pgbackrest.sh) (the SELinux module)
Repo files: [`selinux/pg_archive_nfs.te`](../../selinux/pg_archive_nfs.te), [`tuned/`](../../tuned/)

## Setup

### SELinux

Enforcing on every host. The local changes:

| Host | Change | Why |
|---|---|---|
| db1 | File context rule `/pgdata(/.*)?` → `postgresql_db_t` (`semanage fcontext`), applied with `restorecon` | PostgreSQL may use its data directory on the data disk |
| db1 | Port rule TCP 5433 → `postgresql_port_t` (`semanage port`) | PostgreSQL may listen on 5433 |
| db1 | Module `pg_archive_nfs`, version 1.1 | The archiver may write WAL to the NFS share |
| db2 | None. `/srv/backup` has `var_t`, the default for `/srv`. | A new XFS file system has no label on its root directory, so the mount point showed `unlabeled_t` until `restorecon`. |
| db2 | None. The booleans `nfs_export_all_ro` and `nfs_export_all_rw` are on by default. | nfsd may share `/srv/backup` with its `var_t` label |

On db1, the files on the NFS share have the label `nfs_t`. The archiver runs in the domain `postgresql_t`, and the policy does not let it use files labeled `nfs_t`; no boolean changes that. The module `pg_archive_nfs` (`selinux/pg_archive_nfs.te`) allows it to create, write, read and rename files and to create, list and check directories there, but not to delete files. Version 1.0 was for the `cp` archive command; version 1.1 added the directory rules and `rename` for pgBackRest. How the rules were found: [Build an SELinux module from denials](../runbooks/build-an-selinux-module.md).

### Firewall

firewalld, zone `public` on every host:

| Host | Allowed | Why |
|---|---|---|
| nuc | `ssh`, `cockpit` and the other defaults of the zone | Cockpit is reachable from the home network |
| db1 | `ssh`, `cockpit`, `dhcpv6-client`, `5433/tcp` | PostgreSQL on port 5433. The firewalld service `postgresql` is not used, because it opens 5432. |
| db2 | `ssh`, `cockpit`, `dhcpv6-client`, service `nfs` (TCP 2049) | Only NFSv4 gets through, so `showmount -e db2` does not work: it uses `rpcbind` and `mountd` from NFSv3. |

On the nuc, `virbr0` is in the zone `libvirt`.

### Tuning

The nuc, db1 and db2 use their own tuned profiles. Each one includes a profile from a package and removes only the parts that cannot work on that host. The files are in `tuned/` and are installed as `/etc/tuned/profiles/<name>/tuned.conf`. Profiles in `/etc/tuned/profiles/` take priority over the ones from packages in `/usr/lib/tuned/profiles/`.

| Part | nuc: `virtual-host-nuc` | db1: `postgresql-guest` | db2: `virtual-guest-lab` | Why |
|---|---|---|---|---|
| `[main]` | `include=virtual-host` | `include=postgresql`, from the package `tuned-profiles-postgresql` | `include=virtual-guest`, the profile of the base VM image | The nuc runs the VMs. db1 runs PostgreSQL. db2 does not run a database server until phase 3. |
| `[cpu]` | `drop=boost` | `drop=boost` | `drop=boost` | The option comes from `throughput-performance`, which all three bases include. A VM has no CPU frequency driver, so `boost` does not exist. The nuc uses the `intel_pstate` driver, which has no `boost` file either, so tuned reads nothing there. Turbo stays on (`/sys/devices/system/cpu/intel_pstate/no_turbo` is `0`). |
| `[scheduler]` | — | `enabled=false` | — | Its settings live in `debugfs`. With Secure Boot the kernel runs in lockdown mode (`integrity`) and blocks access to them, even for root. The nuc and db2 do not need this: `tuned-adm verify` passes there without it. |

What the bases set:
- `virtual-host`: background writeback from 5 % of memory (`dirty_background_bytes = 5%`) and no CPU idle states deeper than C3, on top of `throughput-performance`.
- `postgresql`: `vm.swappiness = 3`, background writeback from 64 MiB of dirty pages, writers wait at 512 MiB, transparent huge pages off, no deep CPU idle states (`force_latency=1`).
- `virtual-guest`: `vm.swappiness = 30`, on top of `throughput-performance`.

### Journal

The journal is persistent on nuc, db1 and db2, so the logs survive a reboot (`journalctl --list-boots`).

| Part | Setup |
|---|---|
| Config | Drop-in `/etc/systemd/journald.conf.d/50-persistent-storage.conf` with `Storage=persistent`. The defaults stay in `/usr/lib/systemd/journald.conf`. |
| Logs | `/var/log/journal/<machine-id>/` |
| Access | Group `systemd-journal` and an ACL for `wheel`, set with `systemd-tmpfiles --create --prefix /var/log/journal` |

### DBA group and shared directory

The DBA team works under personal accounts in the group `dba`, not as `postgres` or root.

| Part | Setup |
|---|---|
| Group | `dba`, GID 2000, on db1 and db2. The GID is fixed because NFS compares numeric IDs, not names. `makilele` is a member and has UID 1000 on both hosts. |
| Shared directory | `/srv/dba` on db1, owned by `root:dba`, mode `2770`. Others have no access. |
| setgid | New files and directories get the group `dba`, not the creator's primary group. |
| Default ACL | `default:group:dba:rwx`. New files are writable by the group whatever the creator's umask is. The tools (`getfacl`, `setfacl`) come from the package `acl`, installed on db1 only. |
| umask | `0022` in SSH sessions. No file sets it: the shell inherits it from `sshd`. A `umask` in `~/.bashrc` does not apply to systemd services. |

## Tested

- `tuned-adm verify` passes on the nuc, db1 and db2, also after a reboot.
- Two cases where a file in `/srv/dba` does not get the group's rights:
  - `cp` creates the file with the source's mode. With a source of `600`, the ACL mask becomes `---` and the group cannot read it. `chmod g+rw` sets the mask again.
  - `mv` within one file system keeps the file's owner, group and mode. The file gets neither the group `dba` nor the ACL. `chgrp dba` and `chmod g+rw` fix it.
