# NUC host

The NUC runs RHEL 10.2 without a monitor. It is the KVM host for every VM in the lab, and it is reached over SSH and Cockpit from the home network.

Repo files: [`kickstart/nuc-host.ks`](../../kickstart/nuc-host.ks), [`tuned/virtual-host-nuc/tuned.conf`](../../tuned/virtual-host-nuc/tuned.conf)

## Setup

### Virtualization

| Part | Setup |
|---|---|
| Hypervisor | KVM with QEMU (`qemu-kvm`), managed by libvirt |
| libvirt | Modular daemons (`virtqemud`, `virtnetworkd`, `virtstoraged` and others), started by their sockets. The admin user is in the `libvirt` group, and `virsh` uses `qemu:///system` by default. |
| Storage pool | `default`: a directory pool on `/var/lib/libvirt/images` (LV `vms/images`, 60 GiB), autostart |
| Network | `default`: NAT on `virbr0` (`192.168.122.1/24`), autostart, firewalld zone `libvirt` |
| Tuning | tuned profile `virtual-host-nuc`, see [Tuning](system.md#tuning) |
| VM shutdown | `libvirt-guests` shuts down the running VMs cleanly when the NUC shuts down (`ON_SHUTDOWN=shutdown`, up to 120 s each). It does not start VMs at boot (`ON_BOOT=ignore`); autostart does that. Config: `/etc/sysconfig/libvirt-guests`. |
| Web console | Cockpit with `cockpit-machines`, `https://192.168.1.50:9090` |

### Network and access

| Part | Setup |
|---|---|
| Home network | Wi-Fi (5 GHz, NetworkManager profile `wifi-5g`) with the static IP `192.168.1.50`. Wi-Fi power saving is off to keep SSH responsive. |
| Wired fallback | The wired NIC (`enp85s0`) keeps the same static IP from the kickstart: plug in the cable and reboot. Only one of the two can hold the address at a time. |
| SSH | Key login only. Password login and root login are turned off in `/etc/ssh/sshd_config.d/10-hardening.conf`. |
| Cockpit | Password login. Reachable from the home network, see [Firewall](system.md#firewall). |
| VM addresses | Each VM on the `default` network gets a fixed IP from a DHCP reservation by MAC address: rhel-base `.10`, db1 `.11`, db2 `.12`. |
| VM names | The names in the reservations also work as DNS names inside the network, served by its dnsmasq. From db1, `db2` resolves to `192.168.122.12`. |
| From the desktop | `ProxyJump nuc` in `~/.ssh/config` on the desktop, so `ssh db1` and `ssh db2` work directly |

## Layout

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

## Why

- The system and the VM disks are in separate volume groups. If the VMs fill their disk, the host keeps working.

## Planned

- A fixed IP for k3s: `.20` (phase 9).
