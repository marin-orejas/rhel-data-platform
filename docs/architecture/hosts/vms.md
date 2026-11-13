# VMs

db1 and db2 are clones of the base VM image `rhel-base`. Each one keeps its data on a second disk with its own volume group.

Checks: [05](../../../checks/05-storage.sh), [10](../../../checks/10-nfs.sh), [15](../../../checks/15-replication.sh) · Managed by: [System role storage](../ansible/storage.md) · Files: [`kickstart/rhel-base-vm.ks`](../../../kickstart/rhel-base-vm.ks)

## Setup

### Base VM image

`rhel-base` is installed with `kickstart/rhel-base-vm.ks` and `virt-install`, and it is only used for cloning.

| Part | Setup |
|---|---|
| Firmware, disk | UEFI, 20 GiB thin qcow2 in the pool `default` |
| Network | DHCP on `default`, a fixed IP from a reservation |
| Console | Serial console on `ttyS0` (`virsh console <vm>`) |
| Root account | Locked, so admin work goes through `sudo` and emergency mode gives no shell. |
| Extra packages | `qemu-guest-agent`, `tuned` |
| Subscription, autostart | Not registered, autostart off |

### Clones

The clones are made with `virt-clone` while `rhel-base` is shut off ([Clone a VM from the base image](../../runbooks/clone-a-vm.md)).

| Part | db1 | db2 |
|---|---|---|
| MAC | `52:54:00:00:00:11` | `52:54:00:00:00:12` |
| IP | `192.168.122.11` | `192.168.122.12` |
| RAM | 3 GB | 3 GB |
| Subscription, autostart | Registered, on | Registered, on |

### Data disks

| Part | db1 | db2 |
|---|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2, `vdb` | `db2-data.qcow2`, 10 GiB thin qcow2, `vdb` |
| LVM | PV `/dev/vdb1`, VG `data` | Same as db1 |
| LVs | `pgdata` 7 GiB on `/pgdata`, XFS | `backup` 3 GiB on `/srv/backup` and `pgdata` 5 GiB on `/pgdata`, both XFS |
| Mount | `/etc/fstab` by file system UUID | Same as db1 |

## Layout

The system disk of every VM and the data disks:

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

- [A separate data disk per VM](../../decisions/a-separate-data-disk-per-vm.md), because VG `rhel` has only about 420 MiB free, and a full data disk cannot fill `/`.
- A clone gets a new hostname, machine ID, SSH host keys and registration before its first SSH login, because it copies all four from `rhel-base`. systemd and the journal use the machine ID as the unique ID of the system, the same host keys on every clone would make them interchangeable to SSH, and each registered system needs its own identity.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lvextend -r -L 7G data/pgdata` while a `psql` session was open ([runbook](../../runbooks/grow-a-data-volume.md)) | `pgdata` grew from 5 GiB to 7 GiB. The session stayed, and the fstab UUID did not change. |
