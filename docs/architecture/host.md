# NUC host

The NUC runs RHEL 10.2 without a monitor. It is the KVM host for every VM in the lab, reached over SSH and Cockpit from the home network.

Repo files: [`kickstart/nuc-host.ks`](../../kickstart/nuc-host.ks), [`tuned/virtual-host-nuc/tuned.conf`](../../tuned/virtual-host-nuc/tuned.conf)

## Setup

### Virtualization

| Part | Setup |
|---|---|
| Hypervisor | KVM with QEMU, managed by libvirt (`qemu:///system`); the admin user is in the group `libvirt` |
| Storage pool | `default`: `/var/lib/libvirt/images` on LV `vms/images` (60 GiB), autostart |
| Network | `default`: NAT on `virbr0` (`192.168.122.1/24`), autostart |
| Tuning | tuned profile `virtual-host-nuc`, see [Tuning](system.md#tuning) |
| VM shutdown | `libvirt-guests` shuts the running VMs down cleanly with the NUC (`ON_SHUTDOWN=shutdown`, `ON_BOOT=ignore`) |
| Web console | Cockpit with `cockpit-machines`, `https://192.168.1.50:9090` |

### Network and access

| Part | Setup |
|---|---|
| Home network | Wi-Fi with the static IP `192.168.1.50`, power saving off |
| Wired fallback | `enp85s0` has the same static IP: plug in the cable and reboot |
| SSH | Key login only; no password or root login (`/etc/ssh/sshd_config.d/10-hardening.conf`) |
| VM addresses | A DHCP reservation per MAC address: rhel-base `.10`, db1 `.11`, db2 `.12`. The names resolve between the VMs. |
| From the desktop | `ProxyJump nuc` in `~/.ssh/config`, so `ssh db1` works directly |

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
