# Architecture

Status: the NUC runs RHEL 10.2 as a KVM host with Cockpit. db1 and db2 are cloned from the base VM image. db1 runs PostgreSQL 18, with its data on a separate disk mounted on `/pgdata`, and db2 connects to it on port 5433. db2 has a data disk for the backups, mounted on `/srv/backup` and shared with db1 over NFS. A systemd timer backs up the databases on db1 every day to the NFS share on db2.

## Machines

| Host | Role | OS | CPU / RAM | Disk | Status |
|---|---|---|---|---|---|
| desktop | Workstation, git, SSH, Ansible (phase 4) | Fedora 44 | i3-12100F / 16 GB | — | in use |
| nuc | VM host with KVM and Cockpit, no monitor | RHEL 10.2 | i3-1315U / 16 GB | 120 GB SSD | in use |
| rhel-base | Base VM image. Only used for cloning | RHEL 10.2 | 2 CPU / 2 GB | 20 GB | built |
| db1 | PostgreSQL primary | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| db2 | Backup storage (NFS), PostgreSQL replica in phase 3 | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| k3s | Kubernetes (phase 6) | clone of rhel-base | 2 CPU / 4 GB | 30 GB | planned |

RAM on the NUC: host about 2 GB, db1 and db2 3 GB each, later k3s 4 GB. That is about 12 of 16 GB.

## NUC disk

Installed with `kickstart/nuc-host.ks`.

```
/dev/sda (120 GB = about 111.8 GiB)
├─ sda1  600 MiB  EFI    → /boot/efi
├─ sda2  1 GiB    xfs    → /boot
├─ sda3  35 GiB   LVM    → VG rhel
│   ├─ LV root  30 GiB  xfs → /
│   └─ LV swap   4 GiB
└─ sda4  rest     LVM    → VG vms
    └─ LV images 60 GiB xfs → /var/lib/libvirt/images   (VM disks)
       about 15 GiB left free on purpose, to practise extending an LV
```

The system and the VM disks are in separate volume groups. If the VMs fill their disk, the host keeps working.

## Base VM image

Installed with `kickstart/rhel-base-vm.ks` and `virt-install`. It is never used directly, only cloned.

| Part | Setup |
|---|---|
| Firmware | UEFI |
| Disk | 20 GiB thin qcow2 (`rhel-base.qcow2`) in the `default` pool |
| Network | DHCP on the `default` network, fixed IP from a reservation |
| Console | Serial console on `ttyS0` (`virsh console rhel-base`) |
| Root account | Locked (`rootpw --lock`). Admin work goes through `sudo`. Emergency mode asks for the root password, so it gives no shell on these VMs, and after Enter the boot goes on (tested on db2). |
| Extra packages | `qemu-guest-agent`, `tuned` (profile `virtual-guest`) |
| Firewall | `public` zone: `ssh`, plus the defaults `cockpit` and `dhcpv6-client` |
| Subscription | Not registered. Each clone is registered on its own. |
| Autostart | Off |

```
/dev/vda (20 GiB)
├─ vda1  600 MiB  EFI  → /boot/efi
├─ vda2  2 GiB    xfs  → /boot
└─ vda3  rest     LVM  → VG rhel
    ├─ LV root  15 GiB  xfs → /
    └─ LV swap   2 GiB
       about 420 MiB left free
```

## Clones

db1 and db2 are made from `rhel-base` with `virt-clone`. `rhel-base` must be shut off while it is cloned. `virt-clone` copies the disk and the UEFI variables (NVRAM) and gives the clone a new VM UUID and the MAC address I choose.

| Part | db1 | db2 |
|---|---|---|
| MAC | `52:54:00:00:00:11` | `52:54:00:00:00:12` |
| IP | `192.168.122.11` | `192.168.122.12` |
| RAM | 3 GB | 3 GB |
| Subscription | registered | registered |
| Autostart | on | on |

A clone starts with the same identity as `rhel-base`. Before the first SSH login, I change it in the serial console:

| Part | Why it must change | How |
|---|---|---|
| Hostname | Copied from `rhel-base` | `hostnamectl set-hostname` |
| Machine ID | Copied. systemd and the journal use it as the unique ID of the system. | Delete `/etc/machine-id`, then run `systemd-machine-id-setup`. In a VM, the new ID is the VM UUID without dashes. |
| SSH host keys | Copied. All clones would have the same keys. | Delete `/etc/ssh/ssh_host_*`. `sshd-keygen` creates new keys at the next boot. |
| Subscription | Each system needs its own identity | `subscription-manager register`, after the hostname change |

## Data disks

Each VM keeps its data on a separate disk, because VG `rhel` has only about 420 MiB free. A full data disk also cannot fill the root file system.

| Part | db1 | db2 |
|---|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2 in the `default` pool | `db2-data.qcow2`, the same |
| Attached as | `vdb` (virtio), with `virsh attach-disk --live --config` | the same |
| Partition table | GPT, one partition of type Linux LVM | the same |
| LVM | PV `/dev/vdb1`, VG `data`, LV `pgdata` (7 GiB) | PV `/dev/vdb1`, VG `data`, LV `backup` (3 GiB) |
| File system | XFS, label `pgdata` | XFS, label `backup` |
| Mount | `/pgdata`, in `/etc/fstab` by file system UUID | `/srv/backup`, in `/etc/fstab` by file system UUID |
| SELinux | `postgresql_db_t`, see "PostgreSQL on db1" | `var_t`, the default for `/srv`. A new XFS file system has no label on its root directory, so the mount point showed `unlabeled_t` until `restorecon`. |

```
db1: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ LV pgdata  7 GiB  xfs → /pgdata
       about 3 GiB left free for later growth

db2: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ LV backup  3 GiB  xfs → /srv/backup
       about 7 GiB left free: 5 GiB for the data directory of the replica (phase 3), the rest to practise extending an LV
```

LV `pgdata` started at 5 GiB and was grown to 7 GiB while PostgreSQL ran, with `lvextend -r -L 7G data/pgdata`. The VG had free space, so the PV did not change. `-r` also grows the file system (`xfs_growfs`); without it the LV grows, but `df` and PostgreSQL still see the old size. XFS grows while mounted but cannot shrink, so an LV gets more space in small steps. The file system UUID stays the same, so `/etc/fstab` does not change.

## PostgreSQL on db1

PostgreSQL 18 from AppStream. It runs only on db1 for now. It accepts local connections, and one role from db2 over the network on port 5433. db2 has only the client package, `postgresql18`.

| Part | Setup |
|---|---|
| Package | `postgresql18-server`. RHEL 10 has no modules: each major version has its own package name, and only one version can be installed. |
| Service | `postgresql`, enabled. The vendor unit is not changed. A drop-in, `/etc/systemd/system/postgresql.service.d/override.conf`, sets `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`, so the server does not start without the data disk. |
| Data directory | `/pgdata/pgsql/data`, created with `postgresql-setup --initdb` |
| Settings | `port = 5433` and `listen_addresses = '*'`, set with `ALTER SYSTEM`. They are in `postgresql.auto.conf`, and `postgresql.conf` stays as `initdb` made it. The server listens on all addresses, not only on the IP of db1: the unit does not wait for the network, so at boot the IP may not exist yet, and the server would start on localhost only. |
| SELinux | Local rule `/pgdata(/.*)?` → `postgresql_db_t` (`semanage fcontext`), applied with `restorecon`. Local port rule: TCP 5433 → `postgresql_port_t` (`semanage port`). The server runs in the `postgresql_t` domain. |
| Firewall | `5433/tcp` in the `public` zone. The firewalld service `postgresql` is not used, because it opens 5432. |
| Client authentication | `pg_hba.conf` keeps the default local rules and has one more line: `host postgres remote_test 192.168.122.12/32 scram-sha-256` |
| Roles | `remote_test`: login only, no other attributes. It tests remote access from db2. Its password is stored only in `~/.pgpass` on db2 (mode 600). |
| Logs | The logging collector, on by default in RHEL, writes the server log to `/pgdata/pgsql/data/log/postgresql-<day>.log`. The journal shows only the first lines of each start. |
| Admin access | `sudo -iu postgres psql`. The postgres user's `/var/lib/pgsql/.bash_profile` (a config file of the package) sets `PGDATA=/pgdata/pgsql/data` and `PGPORT=5433`. |

```
/pgdata                 root:root           mount point of LV data/pgdata
└─ pgsql                postgres:postgres   700
    └─ data             postgres:postgres   700   the cluster (PGDATA)
```

The data directory is not the mount point itself, and its parent belongs to `postgres`, as the PostgreSQL docs recommend. If the disk is not mounted, `/pgdata/pgsql/data` does not exist, so nothing can create a cluster on the root disk by mistake. The `postgres`-owned parent leaves room for upgrades, which keep the old cluster next to the new one (`data-old`).

A connection from db2 must pass four checks on db1:

```
db2                                db1
psql + ~/.pgpass ── TCP 5433 ──►   firewalld     public zone allows 5433/tcp
                                   SELinux       port 5433 → postgresql_port_t
                                   postgres      listens on all addresses, port 5433
                                   pg_hba.conf   remote_test from 192.168.122.12, scram-sha-256
```

## Tuning

The NUC, db1 and db2 use their own tuned profiles. Each one includes a profile from a package and removes only the parts that cannot work on that host. The files are in `tuned/` and are installed as `/etc/tuned/profiles/<name>/tuned.conf`. Profiles in `/etc/tuned/profiles/` take priority over the ones from packages in `/usr/lib/tuned/profiles/`.

| Part | nuc: `virtual-host-nuc` | db1: `postgresql-guest` | db2: `virtual-guest-lab` | Why |
|---|---|---|---|---|
| `[main]` | `include=virtual-host` | `include=postgresql`, from the package `tuned-profiles-postgresql` | `include=virtual-guest`, the profile of the base VM image | The NUC runs the VMs. db1 runs PostgreSQL. db2 does not run a database server until phase 3. |
| `[cpu]` | `drop=boost` | `drop=boost` | `drop=boost` | The option comes from `throughput-performance`, which all three bases include. A VM has no CPU frequency driver, so `boost` does not exist. The NUC uses the `intel_pstate` driver, which has no `boost` file either, so tuned reads nothing there. Turbo stays on (`/sys/devices/system/cpu/intel_pstate/no_turbo` is `0`). |
| `[scheduler]` | — | `enabled=false` | — | Its settings live in `debugfs`. With Secure Boot the kernel runs in lockdown mode (`integrity`) and blocks access to them, even for root. The NUC and db2 do not need this: `tuned-adm verify` passes there without it. |

What the bases set:
- `virtual-host`: background writeback from 5 % of memory (`dirty_background_bytes = 5%`) and no CPU idle states deeper than C3, on top of `throughput-performance`.
- `postgresql`: `vm.swappiness = 3`, background writeback from 64 MiB of dirty pages, writers wait at 512 MiB, transparent huge pages off, no deep CPU idle states (`force_latency=1`).
- `virtual-guest`: `vm.swappiness = 30`, on top of `throughput-performance`.

`tuned-adm verify` passes on the NUC, db1 and db2, also after a reboot.

## DBA group and shared directory

The DBA team works under personal accounts in the group `dba`, not as `postgres` or root.

| Part | Setup |
|---|---|
| Group | `dba`, GID 2000, on db1 and db2. The GID is fixed because NFS compares numeric IDs, not names. `makilele` is a member and has UID 1000 on both hosts. |
| Shared directory | `/srv/dba` on db1, owned by `root:dba`, mode `2770`. Others have no access. |
| setgid | New files and directories get the group `dba`, not the creator's primary group. |
| Default ACL | `default:group:dba:rwx`. New files are writable by the group whatever the creator's umask is. The tools (`getfacl`, `setfacl`) come from the package `acl`, installed on db1 only. |
| umask | `0022` in SSH sessions. No file sets it: the shell inherits it from `sshd`. A `umask` in `~/.bashrc` does not apply to systemd services. |

Two cases where a file does not get the group's rights:
- `cp` creates the file with the source's mode. With a source of `600`, the ACL mask becomes `---` and the group cannot read it. `chmod g+rw` sets the mask again.
- `mv` within one file system keeps the file's owner, group and mode. The file gets neither the group `dba` nor the ACL. `chgrp dba` and `chmod g+rw` fix it.

## Backups

`scripts/pg-backup.sh` backs up PostgreSQL on db1. It is installed as `/usr/local/bin/pg-backup.sh` (`root:root`, `755`) and runs as `postgres`. It connects over the local socket with `peer` authentication, so it needs no password. The systemd timer `pg-backup.timer` starts it every day at 02:00.

| Part | Setup |
|---|---|
| Service | `systemd/pg-backup.service`, installed in `/etc/systemd/system/`. `Type=oneshot`, `User=postgres`, `After=postgresql.service autofs.service`, `Wants=autofs.service`. It has no `[Install]` section, so only the timer starts it. The output goes to the journal (`journalctl -u pg-backup.service`), and a failed backup leaves the unit in the `failed` state. |
| Timer | `systemd/pg-backup.timer`, enabled. `OnCalendar=*-*-* 02:00:00` and `Persistent=true`: a run missed while db1 was off starts right after the next boot. |
| Order at boot | A run missed at 02:00 starts during the next boot, maybe before autofs, so the service waits for `autofs.service`. `RequiresMountsFor=` would not help: systemd knows the mounts from fstab and mount units, but not the ones that autofs makes when a program opens the path. |
| Destination | `/mnt/db2/backup/pgsql` on db1, given as the first argument. It is `/srv/backup/pgsql` on db2 (see "NFS share on db2"). Owned by `postgres:dba`, mode `2750`. Nothing is stored on db1. |
| Databases | One plain SQL dump per database, compressed with gzip: `<database>-<YYYY-MM-DD_HHMM>.sql.gz`. Templates are skipped. A database that does not accept connections makes the backup fail instead of being skipped. |
| Roles | `pg_dumpall --globals-only`, in `globals-<stamp>.sql.gz`. It includes the password hashes of the roles. |
| Config files | `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` from the data directory, in `config-<stamp>.tar.bz2`. The package `bzip2` is installed on db1 for this. |
| Permissions | The script sets `umask 027`, and the directory has setgid, so every file is `640 postgres:dba`. The group `dba` can read the backups but cannot change or delete them. Others have no access. |
| Port | The script sets `PGPORT=5433` unless the caller sets it. `sudo -u`, cron and systemd do not read the `.bash_profile` of postgres. |
| Retention | `find -mtime +7` (the second argument, default 7) deletes the files that are at least 8 days old, because `find` rounds the age down to whole days. After each nightly run, 8 sets are kept: that night's and the 7 before it. Nothing is deleted when any step has failed. |
| Exit code | `0` when every step has succeeded, `1` when any step has failed, `2` on a usage error |
| Test data | Database `lab` with the table `items`, 10,000 rows |

Restore of one database into a new one, tested with `lab` from a dump on db2. The row count and `sum(id)` match the original. `ON_ERROR_STOP=1` makes psql stop at the first error and exit with a non-zero code.

```
sudo -iu postgres createdb lab_restore
zcat /mnt/db2/backup/pgsql/lab-<stamp>.sql.gz | sudo -iu postgres psql -v ON_ERROR_STOP=1 -d lab_restore
```

## NFS share on db2

db2 shares `/srv/backup` with db1 over NFS, for the backups of db1. Then they are not on the same machine as the database. db2 runs on the same NUC and SSD, so this protects against the loss of db1, not of the NUC.

| Part | Setup |
|---|---|
| Package | `nfs-utils` on db2 (server) and db1 (client). Without it, `mount -t nfs` on the client fails with `NFS: mount program didn't pass remote address`. |
| Service | `nfs-server` on db2, enabled |
| Export | `/etc/exports.d/backup.exports`: `/srv/backup 192.168.122.11(rw)`. The defaults apply, among them `sync`, `sec=sys` and `root_squash` (`exportfs -v` shows them all). `/etc/exports` stays empty. |
| Clients | db1 only, by IP. With `sec=sys` the server trusts the UID and GID that the client sends, so no other host may mount the share. |
| Firewall | Service `nfs` (TCP 2049) in the `public` zone of db2. Only NFSv4 gets through, so `showmount -e db2` does not work: it uses `rpcbind` and `mountd` from NFSv3. |
| SELinux | The booleans `nfs_export_all_ro` and `nfs_export_all_rw` are on by default, so nfsd may share `/srv/backup` with its `var_t` label. On db1, the files on the share have the label `nfs_t`. |
| Owners | NFS sends numeric IDs. `postgres` (UID 26) and `dba` (GID 2000) have the same IDs on both hosts, so the files have the same owner on db1 and db2. |
| root | `root_squash` maps root on db1 to `nobody` on db2, so root on db1 cannot write to the share. |

```
/srv/backup          root:root      755    mount point of LV data/backup, exported
└─ pgsql             postgres:dba   2750   for the backups of db1
```

db1 mounts the share with autofs when a program opens it, and unmounts it after 5 minutes without use. Nothing mounts it at boot.

| Part | Setup |
|---|---|
| Package | `autofs` on db1. Service `autofs`, enabled. |
| Master map | `/etc/auto.master.d/db2.autofs`: `/mnt/db2 /etc/auto.db2`. `/etc/auto.master` is not changed. |
| Map | `/etc/auto.db2`: `backup -rw,sync db2:/srv/backup`. It is an indirect map: the key `backup` becomes `/mnt/db2/backup`. |
| Options | `sync`, so every write waits until db2 confirms it. The dumps are small, so the slower writes do not matter. The rest are the defaults, among them NFSv4.2 and `hard`. |
| Timeout | 300 seconds, the default from `/etc/autofs.conf` |

`ls /mnt/db2` shows nothing until a program opens `/mnt/db2/backup`.

## Virtualization

| Part | Setup |
|---|---|
| Hypervisor | KVM with QEMU (`qemu-kvm`), managed by libvirt |
| libvirt | Modular daemons (`virtqemud`, `virtnetworkd`, `virtstoraged` and others), started by their sockets. My user is in the `libvirt` group, and `virsh` uses `qemu:///system` by default. |
| Storage pool | `default`: a directory pool on `/var/lib/libvirt/images` (LV `vms/images`, 60 GiB), autostart |
| Network | `default`: NAT on `virbr0` (`192.168.122.1/24`), autostart, firewalld zone `libvirt` |
| Tuning | tuned profile `virtual-host-nuc`, see "Tuning" |
| VM shutdown | `libvirt-guests` shuts down the running VMs cleanly when the NUC shuts down (`ON_SHUTDOWN=shutdown`, up to 120 s each). It does not start VMs at boot (`ON_BOOT=ignore`); autostart does that. Config: `/etc/sysconfig/libvirt-guests`. |
| Web console | Cockpit with `cockpit-machines`, `https://192.168.1.50:9090` |

## Journal

The journal is persistent on nuc, db1 and db2, so the logs survive a reboot (`journalctl --list-boots`).

| Part | Setup |
|---|---|
| Config | Drop-in `/etc/systemd/journald.conf.d/50-persistent-storage.conf` with `Storage=persistent`. The defaults stay in `/usr/lib/systemd/journald.conf`. |
| Logs | `/var/log/journal/<machine-id>/` |
| Access | Group `systemd-journal` and an ACL for `wheel`, set with `systemd-tmpfiles --create --prefix /var/log/journal` |

## Network and access

- The NUC is on the home network over Wi-Fi (5 GHz, NetworkManager profile `wifi-5g`) with the static IP `192.168.1.50`. Wi-Fi power saving is off to keep SSH responsive.
- The wired NIC (`enp85s0`) keeps the same static IP from the kickstart and is the fallback: plug in the cable and reboot. Only one of the two can hold the address at a time.
- SSH to the NUC works only with a key. Password login and root login are turned off in `/etc/ssh/sshd_config.d/10-hardening.conf`.
- Cockpit uses password login. The `cockpit` service is allowed in the firewalld `public` zone, so it is reachable from the home network.

- The VMs are on the libvirt `default` network. Each VM gets a fixed IP from a DHCP reservation by MAC address: `rhel-base` `.10`, `db1` `.11`, `db2` `.12`.
- The names in the reservations also work as DNS names inside the network, served by the network's dnsmasq. From db1, `db2` resolves to `192.168.122.12`.
- From the desktop I reach the VMs through the NUC with `ProxyJump nuc` in `~/.ssh/config`, so `ssh db1` and `ssh db2` work directly.
- Besides the defaults (`ssh`, `cockpit`, `dhcpv6-client`), db1 opens `5433/tcp` for PostgreSQL. db2 opens the service `nfs` (TCP 2049).

Planned:
- A fixed IP for k3s: `.20`.
