# Architecture

Status: the NUC runs RHEL 10.2 as a KVM host with Cockpit. db1 and db2 are cloned from the base VM image. db1 runs PostgreSQL 18, with its data on a separate disk mounted on `/pgdata`, and db2 connects to it on port 5433. db2 has a data disk for the backups, mounted on `/srv/backup` and shared with db1 over NFS. A systemd timer backs up the databases on db1 every day to the NFS share on db2. pgBackRest also backs up the whole cluster to that share, a full backup on Sunday and a differential on the other nights, and archives every WAL segment there. A restore to a set time has been tested, by hand and with pgBackRest.

## Machines

| Host | Role | OS | CPU / RAM | Disk | Status |
|---|---|---|---|---|---|
| desktop | Workstation, git, SSH, Ansible (phase 4) | Fedora 44 | i3-12100F / 16 GB | — | in use |
| nuc | VM host with KVM and Cockpit, no monitor | RHEL 10.2 | i3-1315U / 16 GB | 120 GB SSD | in use |
| rhel-base | Base VM image. Only used for cloning | RHEL 10.2 | 2 CPU / 2 GB | 20 GB | built |
| db1 | PostgreSQL primary | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| db2 | Backup storage (NFS), PostgreSQL replica in phase 3 | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| k3s | Kubernetes (phase 9) | clone of rhel-base | 2 CPU / 4 GB | 30 GB | planned |

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
| Package | `postgresql18-server`, and `postgresql18-contrib` for `pg_waldump`. RHEL 10 has no modules: each major version has its own package name, and only one version can be installed. |
| Service | `postgresql`, enabled. The vendor unit is not changed. A drop-in, `/etc/systemd/system/postgresql.service.d/override.conf`, sets `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`, so the server does not start without the data disk. |
| Data directory | `/pgdata/pgsql/data`, created with `postgresql-setup --initdb` |
| Settings | `port = 5433` and `listen_addresses = '*'`, set with `ALTER SYSTEM`. They are in `postgresql.auto.conf`, and `postgresql.conf` stays as `initdb` made it. The server listens on all addresses, not only on the IP of db1: the unit does not wait for the network, so at boot the IP may not exist yet, and the server would start on localhost only. |
| SELinux | Local rule `/pgdata(/.*)?` → `postgresql_db_t` (`semanage fcontext`), applied with `restorecon`. Local port rule: TCP 5433 → `postgresql_port_t` (`semanage port`). The server runs in the `postgresql_t` domain. The local module `pg_archive_nfs` lets it write WAL to NFS, see "pgBackRest". |
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
| Retention | `find -mtime +7` (the second argument, default 7) deletes the files that are at least 8 days old, because `find` rounds the age down to whole days. After each nightly run, 8 sets are kept: that night's and the 7 before it. Nothing is deleted when any step has failed. Only files directly in the destination are deleted, so `wal` and `base` below it are not touched. |
| Exit code | `0` when every step has succeeded, `1` when any step has failed, `2` on a usage error |
| Test data | Database `lab` with the table `items`, 10,000 rows |

Restore of one database into a new one, tested with `lab` from a dump on db2. The row count and `sum(id)` match the original. `ON_ERROR_STOP=1` makes psql stop at the first error and exit with a non-zero code.

```
sudo -iu postgres createdb lab_restore
zcat /mnt/db2/backup/pgsql/lab-<stamp>.sql.gz | sudo -iu postgres psql -v ON_ERROR_STOP=1 -d lab_restore
```

## WAL archiving and base backups by hand

The nightly dumps restore a database only to the state at 02:00. From 2026-10-25, PostgreSQL on db1 also copied every full WAL segment to the NFS share on db2, next to a base backup. Together they are what point-in-time recovery needs. On 2026-10-26, pgBackRest replaced this method (see "pgBackRest"). The `wal` and `base` directories still hold that archive, up to segment `00000002000000000000000E`, and its base backup. Nothing writes to them any more.

| Part | Setup |
|---|---|
| Settings | `archive_mode = on` and `archive_command`, set with `ALTER SYSTEM`. `wal_level` stays `replica`, the default. `archive_mode` needs a restart, `archive_command` only a reload. |
| Archive command | `test ! -f /mnt/db2/backup/pgsql/wal/%f && cp %p /mnt/db2/backup/pgsql/wal/%f`. It returns 0 only when the copy has succeeded, and it never overwrites a segment that is already there. `cp` writes the file in place and does not call fsync, so a crash of db2 during a copy can leave a partial segment. |
| Archive | `/mnt/db2/backup/pgsql/wal`, which is `/srv/backup/pgsql/wal` on db2. 16 MiB per segment, mode 600, so the group `dba` cannot read them. Nothing deletes old segments yet. |
| Segment switch | `archive_timeout` stays 0. A segment is archived when it is full, or after `SELECT pg_switch_wal()`. A clean shutdown of the server archives the current segment too. |
| Failed archiving | The segment stays in `pg_wal`, with a `.ready` file in `pg_wal/archive_status`, and the archiver tries again about every minute. Nothing is lost, but `pg_wal` grows. `pg_stat_archiver` counts the failures, and the server log shows the error. |
| db2 down | The share is mounted `hard`, so `cp` waits until db2 answers again instead of failing. The archiver stops on that segment, the next ones wait in `pg_wal` with `.ready` files, and the database keeps working. Tested with db2 shut down while three segments were written: `failed_count` did not change, and all three were archived within 10 seconds after db2 came back. So monitoring has to watch the age of `last_archived_time` and the number of `.ready` files, not only the failures. A long outage fills `/pgdata`. |
| SELinux | The archiver runs in the domain `postgresql_t`, and the policy does not let it use files labeled `nfs_t`; no boolean changes that. The local module `selinux/pg_archive_nfs.te` allows it to create, write and read files there, but not to delete or rename them. The rules come from `audit2allow`, after one archive run with `postgresql_t` in permissive mode (`semanage permissive -a`, then `-d`). |
| Base backup | `pg_basebackup -Ft -z -X stream -c fast` as postgres, over the local socket (`local replication all peer` in `pg_hba.conf`), into `/mnt/db2/backup/pgsql/base/<YYYY-MM-DD_HHMM>`. It writes `base.tar.gz`, `pg_wal.tar.gz` with the WAL from the time of the backup, and `backup_manifest`. The first one: 32 MB of data, 4.3 MB compressed, 1.3 s. |
| Verification | `pg_verifybackup -n <dir>` checks every file against the manifest. `-n` is needed because `pg_waldump` cannot read WAL from a tar file. |
| Backup record | At the end of a backup, PostgreSQL archives a small `.backup` file with the start and stop WAL locations and the label. A restore from that backup needs the archived WAL from the start segment on. |

The module is built and loaded on db1 from its source:

```
checkmodule -M -m -o pg_archive_nfs.mod pg_archive_nfs.te
semodule_package -o pg_archive_nfs.pp -m pg_archive_nfs.mod
sudo semodule -i pg_archive_nfs.pp
```

## Point-in-time recovery

Tested on db1 on 2026-10-26: a table was created after the base backup and then dropped, and the cluster was restored to a time between the two.

| Part | Setup |
|---|---|
| Method | In place on db1. The broken cluster is moved to `/pgdata/pgsql/data-broken`, not deleted, so the restore can be undone. A real restore would go to a separate host first; the lab has none. |
| Base backup | `base.tar.gz` is extracted into a new, empty `/pgdata/pgsql/data` (owner postgres, mode 700), and `pg_wal.tar.gz` into its `pg_wal`. The files get `postgresql_db_t` from `/pgdata`, so `restorecon` changes nothing. |
| Settings | Appended to `postgresql.auto.conf` while the server is down, because `ALTER SYSTEM` needs a running server: `restore_command = 'cp /mnt/db2/backup/pgsql/wal/%f %p'`, `recovery_target_time` with the time zone offset, and `recovery_target_action = 'pause'`. An empty `recovery.signal` in the data directory starts the recovery. |
| Check before promote | `pause` stops the replay at the target and leaves the database read-only, so the data can be checked first. `SELECT pg_wal_replay_resume()` then ends the recovery. |
| After promote | The server continues on timeline 2: new WAL files begin with `00000002`, and `00000002.history` in the archive records where it branched off. PostgreSQL removes `recovery.signal` itself. The three settings are removed with `ALTER SYSTEM RESET`, so a later recovery or replica does not inherit the old target. |
| Lost data | The replay stops before the first commit after the target. A good row inserted 4 seconds after the target was lost together with the dropped table. |
| Log | `cp: cannot stat` for `00000002.history` and for the first segment after the end of the archive is normal: recovery asks for files that may not exist. |

| Measured | Time |
|---|---|
| Outage, from `systemctl stop` to promote | 9 min 31 s |
| Server start to the pause at the target | 0.85 s |
| Replay of 8 segments (`…06` to `…0D`) | 0.67 s |

Almost the whole outage was manual work: moving, extracting, editing the settings and checking the data. The replay itself took under a second.

```
sudo systemctl stop postgresql
sudo -iu postgres mv /pgdata/pgsql/data /pgdata/pgsql/data-broken
sudo -iu postgres mkdir -m 700 /pgdata/pgsql/data
sudo -iu postgres tar -xzf /mnt/db2/backup/pgsql/base/<stamp>/base.tar.gz -C /pgdata/pgsql/data
sudo -iu postgres tar -xzf /mnt/db2/backup/pgsql/base/<stamp>/pg_wal.tar.gz -C /pgdata/pgsql/data/pg_wal
# append the three settings to /pgdata/pgsql/data/postgresql.auto.conf
sudo -iu postgres touch /pgdata/pgsql/data/recovery.signal
sudo systemctl start postgresql
# check the data while the server is paused, then
sudo -iu postgres psql -c "SELECT pg_wal_replay_resume();"
sudo -iu postgres psql -c "ALTER SYSTEM RESET restore_command;"
sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_time;"
sudo -iu postgres psql -c "ALTER SYSTEM RESET recovery_target_action;"
```

## pgBackRest

Since 2026-10-26, pgBackRest archives the WAL of db1 and backs up the cluster to the NFS share on db2. It replaces the `cp` archive command and `pg_basebackup` from "WAL archiving and base backups by hand".

| Part | Setup |
|---|---|
| Package | `pgbackrest` 2.60 from the "common" repository of PGDG, the PostgreSQL project's own packages. RHEL has no pgBackRest package. The repository file is `pgbackrest/pgdg-common.repo`, installed in `/etc/yum.repos.d/`, with the GPG key in `/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL`. `includepkgs` lets dnf see only `pgbackrest` and `pgdg-libssh2`, a library it needs that RHEL does not ship, so no PGDG package can replace PostgreSQL from AppStream. |
| Config | `pgbackrest/pgbackrest.conf`, installed as `/etc/pgbackrest.conf`. One stanza, `main`, for the cluster in `/pgdata/pgsql/data` on port 5433. |
| Repository | `/mnt/db2/backup/pgbackrest` on db1, which is `/srv/backup/pgbackrest` on db2. pgBackRest runs only on db1, as `postgres`, and writes to the NFS share. This keeps the lab simple, but db1 can change and delete its own backups. A production setup would use a separate repository host. |
| Stanza | Created with `pgbackrest --stanza=main stanza-create`. The repository has `archive/main` for WAL and `backup/main` for backups. |
| Archive command | `pgbackrest --stanza=main archive-push %p`, set with `ALTER SYSTEM` and a reload. It checks that the segment belongs to this cluster, compresses it with zstd and writes it to a temporary file that it renames, so a partial segment never has its final name. The segments are in `archive/main/18-1/`, one directory for every 256 segments. |
| SELinux | `archive-push` runs in `postgresql_t`, like `cp` did. Version 1.1 of the module `pg_archive_nfs` also lets it create, list and check directories and rename files on NFS. The rules come from two permissive runs: on the empty repository the directories did not exist yet, so the first run never checked `getattr` on them, and archiving failed in enforcing mode. |
| Test | `pgbackrest --stanza=main check` switches to a new WAL segment and waits up to 60 seconds until it is in the repository. |
| Backups | A full backup copies every file of the cluster. A differential copies the files changed since the last full, and an incremental the files changed since the last backup of any type; the rest of the set refers to the earlier backups. A changed file is copied whole. Every backup waits until its WAL is in the archive. |
| Service | `systemd/pgbackrest@.service`, a template unit installed in `/etc/systemd/system/`. `Type=oneshot`, `User=postgres`, `ExecStart=/usr/bin/pgbackrest --stanza=main --type=%i backup`, with the same `Wants=` and `After=` as `pg-backup.service`. The instance name is the backup type: `pgbackrest@full.service`, `pgbackrest@diff.service`. |
| Schedule | `systemd/pgbackrest-full.timer`: Sunday at 01:00, `Persistent=true`. `systemd/pgbackrest-diff.timer`: Monday to Saturday at 01:00, without `Persistent=`, because after an outage the full catches up at boot, and a second backup at the same time would fail on the stanza lock. A restore needs at most a full and one differential. The nightly dumps at 02:00 stay, for the restore of a single database. |
| Retention | `repo1-retention-full=2`. After each backup, `expire` keeps the two newest full backups: a third full removes the oldest one with every backup that refers to it. It also removes the archived WAL from before the start of the oldest full that is kept. With a weekly full, a restore to any time in the last 7 to 14 days is possible. Tested: the third full removed the first full, its differential and incremental, and their WAL. |

Measured on 2026-10-26. Between the backups, the test table `pgbr_test` in `lab` got 200,000 rows (14 MB) and then 100,000 more.

| Backup | Time | Copied | In the repository |
|---|---|---|---|
| Full, 31.1 MB cluster | 17.8 s | 31.1 MB, 1282 files | 3.7 MB |
| Differential | 1.4 s | 15.4 MB | 5.2 MB |
| Incremental | 1.5 s | 19.7 MB | 7.4 MB |
| Full, 50.6 MB, by `pgbackrest@full.service` | 19.4 s | 50.6 MB | 11.1 MB |

The full writes all 1282 files to the share, which is mounted with `sync`. A differential or incremental writes only the changed files. The incremental copied the whole file of `pgbr_test`, not only the 100,000 new rows.

### Restore to a set time with pgBackRest

Tested on db1 on 2026-10-26, the same way as the restore by hand: the table `pgbr_test` (300,000 rows) was dropped, and the cluster was restored to 5 seconds before the drop.

| Part | Setup |
|---|---|
| Command | `pgbackrest --stanza=main --delta --type=time "--target=<time>" --target-action=promote restore`, as postgres, with the server stopped. The time comes from `SELECT now()`, with the time zone offset. |
| Backup set | pgBackRest picks the newest backup that ended before the target, here the full backup `20261026-194628F`. |
| `--delta` | The restore goes over the existing data directory. pgBackRest compares the checksum of every file with the backup, replaces the files that differ and removes the files that are not in the backup. |
| Settings | pgBackRest writes `restore_command = 'pgbackrest --stanza=main archive-get %f "%p"'`, `recovery_target_time` and `recovery_target_action = 'promote'` to `postgresql.auto.conf` and creates `recovery.signal`. |
| WAL | The commit of the drop must be in the archive, or the replay cannot see where to stop. `pgbackrest check` after the drop switched the segment and waited until it was archived. |
| After promote | The server continues on timeline 3. The three settings are removed with `ALTER SYSTEM RESET`, and a new full backup is taken on the new timeline. |
| Result | `pgbr_test` came back with 300,000 rows and the same `sum(id)`. `items` (10,000 rows) and `pitr_test` (1,000 rows) did not change. |

| Measured | Time |
|---|---|
| Outage, from `systemctl stop` to promote | 1.1 s |
| `pgbackrest restore` with `--delta`, 1287 files checked | 0.41 s |
| Server start to the promote | 0.28 s |

The restore by hand took 9 min 31 s, almost all of it typing. With pgBackRest the same restore was one command. `--delta` also made it short: the data directory was intact, so only the changed files came from the share. After the loss of the data disk, all 50.6 MB would be copied.

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
/srv/backup          root:root           755    mount point of LV data/backup, exported
├─ pgsql             postgres:dba        2750   for the backups of db1
│   ├─ wal           postgres:dba        2750   archived WAL segments, by hand
│   └─ base          postgres:dba        2750   base backups, one directory each
└─ pgbackrest        postgres:postgres   750    pgBackRest repository
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
