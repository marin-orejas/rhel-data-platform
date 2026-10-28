# VMs

db1 and db2 are clones of the base VM image `rhel-base`. Each one keeps its data on a second disk with its own volume group.

Verified by: [`checks/05-storage.sh`](../../checks/05-storage.sh) (db1), [`checks/10-nfs.sh`](../../checks/10-nfs.sh) and [`checks/15-replication.sh`](../../checks/15-replication.sh) (db2)
Repo files: [`kickstart/rhel-base-vm.ks`](../../kickstart/rhel-base-vm.ks)

## Setup

### Base VM image

Installed with `kickstart/rhel-base-vm.ks` and `virt-install`, only used for cloning.

| Part | Setup |
|---|---|
| Firmware, disk | UEFI, 20 GiB thin qcow2 in the `default` pool |
| Network | DHCP on `default`, a fixed IP from a reservation |
| Console | Serial console on `ttyS0` (`virsh console <vm>`) |
| Root account | Locked; admin work goes through `sudo`. Emergency mode gives no shell. |
| Extra packages | `qemu-guest-agent`, `tuned` |
| Subscription, autostart | Not registered, autostart off |

### Clones

Made with `virt-clone` while `rhel-base` is shut off, see [Clone a VM from the base image](../runbooks/clone-a-vm.md).

| Part | db1 | db2 |
|---|---|---|
| MAC | `52:54:00:00:00:11` | `52:54:00:00:00:12` |
| IP | `192.168.122.11` | `192.168.122.12` |
| RAM | 3 GB | 3 GB |
| Subscription, autostart | registered, on | registered, on |

A clone starts with the identity of `rhel-base`. Four parts change before the first SSH login:

| Part | Why |
|---|---|
| Hostname | copied from `rhel-base` |
| Machine ID | copied; systemd and the journal use it as the system's unique ID |
| SSH host keys | copied; every clone would have the same keys |
| Subscription | each system needs its own identity |

### Data disks

| Part | db1 | db2 |
|---|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2, `vdb` | `db2-data.qcow2`, the same |
| LVM | PV `/dev/vdb1`, VG `data` | the same |
| LVs | `pgdata` 7 GiB, XFS, `/pgdata` | `backup` 3 GiB, `/srv/backup`; `pgdata` 5 GiB, `/pgdata`; both XFS |
| Mount | `/etc/fstab` by file system UUID | the same |

## Layout

```
rhel-base, db1, db2: /dev/vda (20 GiB)
├─ vda1  600 MiB  EFI  → /boot/efi
├─ vda2  2 GiB    xfs  → /boot
└─ vda3  rest     LVM  → VG rhel
    ├─ LV root  15 GiB  xfs → /
    └─ LV swap   2 GiB
       about 420 MiB left free

db1: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ LV pgdata  7 GiB  xfs → /pgdata
       about 3 GiB left free for later growth

db2: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    ├─ LV backup  3 GiB  xfs → /srv/backup
    └─ LV pgdata  5 GiB  xfs → /pgdata
       about 2 GiB left free to practise extending an LV
```

## Why

- A separate data disk per VM, because VG `rhel` has only about 420 MiB free, and a full data disk cannot fill `/`. See [ADR 0001](../decisions/0001-a-separate-data-disk-per-vm.md).

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lvextend -r -L 7G data/pgdata` while a `psql` session was open ([runbook](../runbooks/grow-a-data-volume.md)) | `pgdata` grew from 5 GiB to 7 GiB, the session stayed, the fstab UUID did not change |
