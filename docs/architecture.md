# Architecture

Status: the NUC runs RHEL 10.2 as a KVM host with Cockpit. db1 and db2 are cloned from the base VM image. db1 has a data disk mounted on `/pgdata`. PostgreSQL is not installed yet.

## Machines

| Host | Role | OS | CPU / RAM | Disk | Status |
|---|---|---|---|---|---|
| desktop | Workstation, git, SSH, Ansible (phase 4) | Fedora 44 | i3-12100F / 16 GB | — | in use |
| nuc | VM host with KVM and Cockpit, no monitor | RHEL 10.2 | i3-1315U / 16 GB | 120 GB SSD | in use |
| rhel-base | Base VM image. Only used for cloning | RHEL 10.2 | 2 CPU / 2 GB | 20 GB | built |
| db1 | PostgreSQL primary | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | cloned |
| db2 | PostgreSQL replica, backup storage (NFS) | clone of rhel-base | 2 CPU / 3 GB | 20 GB | cloned |
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

## db1 data disk

The data goes on a separate disk, because VG `rhel` on the VMs has only about 420 MiB free.

| Part | Setup |
|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2 in the `default` pool |
| Attached as | `vdb` (virtio), with `virsh attach-disk --live --config` |
| Partition table | GPT, one partition of type Linux LVM |
| LVM | PV `/dev/vdb1`, VG `data`, LV `pgdata` (5 GiB) |
| File system | XFS, label `pgdata` |
| Mount | `/pgdata`, in `/etc/fstab` by file system UUID |

```
/dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ LV pgdata  5 GiB  xfs → /pgdata
       about 5 GiB left free on purpose, to practise extending an LV
```

## Virtualization

| Part | Setup |
|---|---|
| Hypervisor | KVM with QEMU (`qemu-kvm`), managed by libvirt |
| libvirt | Modular daemons (`virtqemud`, `virtnetworkd`, `virtstoraged` and others), started by their sockets. My user is in the `libvirt` group, and `virsh` uses `qemu:///system` by default. |
| Storage pool | `default`: a directory pool on `/var/lib/libvirt/images` (LV `vms/images`, 60 GiB), autostart |
| Network | `default`: NAT on `virbr0` (`192.168.122.1/24`), autostart, firewalld zone `libvirt` |
| Tuning | tuned profile `virtual-host` |
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

Planned:
- A data disk for db2, for the NFS backup share (phase 1).
- The PostgreSQL data directory under `/pgdata` (phase 1).
- A fixed IP for k3s: `.20`.
- Each VM opens only the ports it needs (SSH, later PostgreSQL and NFS).
