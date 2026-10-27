# VMs

db1 and db2 are clones of the base VM image `rhel-base`. Each one keeps its data on a second disk with its own volume group.

Verified by: [`checks/05-storage.sh`](../../checks/05-storage.sh) (db1), [`checks/10-nfs.sh`](../../checks/10-nfs.sh) and [`checks/15-replication.sh`](../../checks/15-replication.sh) (db2)
Repo files: [`kickstart/rhel-base-vm.ks`](../../kickstart/rhel-base-vm.ks)

## Setup

### Base VM image

Installed with `kickstart/rhel-base-vm.ks` and `virt-install`. It is never used directly, only cloned.

| Part | Setup |
|---|---|
| Firmware | UEFI |
| Disk | 20 GiB thin qcow2 (`rhel-base.qcow2`) in the `default` pool |
| Network | DHCP on the `default` network, fixed IP from a reservation |
| Console | Serial console on `ttyS0` (`virsh console rhel-base`) |
| Root account | Locked (`rootpw --lock`). Admin work goes through `sudo`. Emergency mode asks for the root password, so it gives no shell on these VMs, and after Enter the boot goes on (tested on db2). |
| Extra packages | `qemu-guest-agent`, `tuned` (profile `virtual-guest`) |
| Firewall | the defaults, see [Firewall](system.md#firewall) |
| Subscription | Not registered. Each clone is registered on its own. |
| Autostart | Off |

### Clones

db1 and db2 are made from `rhel-base` with `virt-clone`, while `rhel-base` is shut off. `virt-clone` copies the disk and the UEFI variables (NVRAM) and gives the clone a new VM UUID and a chosen MAC address. Procedure: [Clone a VM from the base image](../runbooks/clone-a-vm.md).

| Part | db1 | db2 |
|---|---|---|
| MAC | `52:54:00:00:00:11` | `52:54:00:00:00:12` |
| IP | `192.168.122.11` | `192.168.122.12` |
| RAM | 3 GB | 3 GB |
| Subscription | registered | registered |
| Autostart | on | on |

A clone starts with the same identity as `rhel-base`. These parts change in the serial console, before the first SSH login:

| Part | Why it must change | How |
|---|---|---|
| Hostname | Copied from `rhel-base` | `hostnamectl set-hostname` |
| Machine ID | Copied. systemd and the journal use it as the unique ID of the system. | Delete `/etc/machine-id`, then run `systemd-machine-id-setup`. In a VM, the new ID is the VM UUID without dashes. |
| SSH host keys | Copied. All clones would have the same keys. | Delete `/etc/ssh/ssh_host_*`. `sshd-keygen` creates new keys at the next boot. |
| Subscription | Each system needs its own identity | `subscription-manager register`, after the hostname change |

### Data disks

| Part | db1 | db2 |
|---|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2 in the `default` pool | `db2-data.qcow2`, the same |
| Attached as | `vdb` (virtio), with `virsh attach-disk --live --config` | the same |
| Partition table | GPT, one partition of type Linux LVM | the same |
| LVM | PV `/dev/vdb1`, VG `data`, LV `pgdata` (7 GiB) | PV `/dev/vdb1`, VG `data`, LV `backup` (3 GiB) and LV `pgdata` (5 GiB) |
| File system | XFS, label `pgdata` | XFS, labels `backup` and `pgdata` |
| Mount | `/pgdata`, in `/etc/fstab` by file system UUID | `/srv/backup` and `/pgdata`, in `/etc/fstab` by file system UUID |
| SELinux | `postgresql_db_t`, see [SELinux](system.md#selinux) | `var_t` on `/srv/backup` (the default for `/srv`), `postgresql_db_t` on `/pgdata`, see [SELinux](system.md#selinux) |

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

- Each VM keeps its data on a separate disk, because VG `rhel` has only about 420 MiB free. A full data disk also cannot fill the root file system. See [ADR 0001](../decisions/0001-a-separate-data-disk-per-vm.md).

## Tested

- LV `pgdata` started at 5 GiB and was grown to 7 GiB while PostgreSQL ran, with `lvextend -r -L 7G data/pgdata`. The VG had free space, so the PV did not change. `-r` also grows the file system (`xfs_growfs`); without it the LV grows, but `df` and PostgreSQL still see the old size. XFS grows while mounted but cannot shrink, so an LV gets more space in small steps. The file system UUID stays the same, so `/etc/fstab` does not change. Procedure: [Grow a data volume while PostgreSQL runs](../runbooks/grow-a-data-volume.md).
