# Architecture

Status: plan. I update this file as I build the lab.

## Machines

| Host | Role | OS | CPU / RAM | Disk |
|---|---|---|---|---|
| desktop | Workstation, git, SSH, Ansible (phase 4) | Fedora 44 | i3-12100F / 16 GB | — |
| nuc | VM host with KVM and Cockpit, no monitor | RHEL 10.2 | i3-1315U / 16 GB | 120 GB SSD |
| rhel-base | Base VM image. Only used for cloning | RHEL 10.2 | 2 CPU / 2 GB | 20 GB |
| db1 | PostgreSQL primary | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data |
| db2 | PostgreSQL replica, backup storage (NFS) | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data |
| k3s | Kubernetes (phase 6) | clone of rhel-base | 2 CPU / 4 GB | 30 GB |

RAM on the NUC: host about 2 GB, db1 and db2 3 GB each, k3s 4 GB. That is about 12 of 16 GB.

## NUC disk

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

## Network

- The NUC has a static IP on the home network.
- The VMs use the libvirt `default` network (`192.168.122.0/24`) with fixed IPs: `rhel-base .10`, `db1 .11`, `db2 .12`, `k3s .20`.
- From the desktop I reach the VMs through the NUC (`ProxyJump` in `~/.ssh/config`).
- Each VM opens only the ports it needs (SSH, later PostgreSQL and NFS).
