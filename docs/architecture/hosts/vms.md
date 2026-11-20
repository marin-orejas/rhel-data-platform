# VMs

db1, db2 and the Kubernetes nodes k8s1, k8s2 and k8s3 are clones of the base VM image `rhel-base`. db1, db2, k8s2 and k8s3 keep their data on a second disk with its own volume group. The nodes have no swap and run CRI-O with the Kubernetes 1.36 packages.

Checks: [05](../../../checks/05-storage.sh), [10](../../../checks/10-nfs.sh), [15](../../../checks/15-replication.sh), [24](../../../checks/24-fresh-clones.sh), [25](../../../checks/25-nodes.sh), [26](../../../checks/26-cluster.sh), [31](../../../checks/31-storage.sh) · Managed by: [System role storage](../ansible/storage.md) · Files: [`kickstart/rhel-base-vm.ks`](../../../kickstart/rhel-base-vm.ks), [`kubernetes/nodes/`](../../../kubernetes/nodes/)

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

| Part | db1 | db2 | k8s1–k8s3 |
|---|---|---|---|
| MAC | `52:54:00:00:00:11` | `52:54:00:00:00:12` | `52:54:00:00:00:21` to `:23` |
| IP | `192.168.122.11` | `192.168.122.12` | `192.168.122.21` to `.23` |
| RAM | 3 GB | 3 GB | 3 GiB on k8s1, 2.5 GiB on k8s2 and k8s3 |
| Release | RHEL 10.3, from `dnf -y upgrade` after the clone | Same as db1 | Same as db1 |
| Subscription, autostart | Registered, autostart off | Same as db1 | Same as db1 |

### Data disks

| Part | db1 | db2 | k8s2, k8s3 |
|---|---|---|---|
| Image | `db1-data.qcow2`, 10 GiB thin qcow2, `vdb` | `db2-data.qcow2`, 10 GiB thin qcow2, `vdb` | `k8s2-data.qcow2` and `k8s3-data.qcow2`, 5 GiB thin qcow2, `vdb` |
| LVM | PV `/dev/vdb1`, VG `data` | Same as db1 | Same as db1 |
| LVs | `pgdata` 7 GiB on `/pgdata`, XFS | `backup` 3 GiB on `/srv/backup` and `pgdata` 5 GiB on `/pgdata`, both XFS | One per Kubernetes volume, made by [TopoLVM](../kubernetes/storage.md#topolvm) |
| Mount | `/etc/fstab` by file system UUID | Same as db1 | None in `/etc/fstab`. TopoLVM mounts each volume for its pod. |
| LVM devices file | `/etc/lvm/devices/system.devices` lists `vda3` and `vdb1`. A new clone of `rhel-base` lists only `vda3`. | Same as db1 | Same as db1 |
| Rebuild | The data disk stays and goes to the new clone as `vdb` ([Rebuild the db hosts from fresh clones](../../runbooks/rebuild-the-db-hosts-from-fresh-clones.md)). | Same as db1 | Not done yet (item 44) |

### Kubernetes nodes

The same on k8s1, k8s2 and k8s3, set up by hand. Copies of the two repo files, `k8s.conf`, the pause drop-in and the NetworkManager drop-in are in `kubernetes/nodes/`, under the same paths.

| Part | Setup |
|---|---|
| Swap | None. LV `rhel/swap` and its line in `/etc/fstab` are removed. |
| Kernel arguments | No `resume=` or `rd.lvm.lv=rhel/swap` in any boot entry, in `GRUB_CMDLINE_LINUX` or in `/etc/kernel/cmdline` |
| Sysctl | `net.ipv4.ip_forward = 1` in `/etc/sysctl.d/k8s.conf` |
| NetworkManager | `/etc/NetworkManager/conf.d/calico.conf` leaves the Calico interfaces (`cali*`, `vxlan.calico` and the others from the Calico docs) unmanaged. |
| Repo `kubernetes` | `https://pkgs.k8s.io/core:/stable:/v1.36/rpm/`. Its `exclude=` line hides `kubelet`, `kubeadm`, `kubectl`, `cri-tools` and `kubernetes-cni` unless `dnf` runs with `--disableexcludes=kubernetes`. |
| Repo `cri-o` | `https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.36/rpm/` |
| Packages | `container-selinux` from AppStream, `cri-o` 1.36.8, `kubelet`, `kubeadm` and `kubectl` 1.36.6, `cri-tools` 1.36.0, `kubernetes-cni` 1.9.1 |
| Version locks | `dnf versionlock` holds `cri-o`, `kubelet`, `kubeadm` and `kubectl` at these versions. |
| Pause image | `/etc/crio/crio.conf.d/20-pause-image.conf` sets `pause_image = "registry.k8s.io/pause:3.10.2"`, the image kubeadm 1.36.6 expects. |
| CRI-O service | `crio` enabled and running |
| Kubelet service | `kubelet` enabled and running, with the config from `kubeadm init` on k8s1 and `kubeadm join` on the workers ([Kubernetes cluster](../kubernetes/cluster.md)) |

## Layout

The system disks and the data disks:

```
rhel-base, db1, db2: /dev/vda (20 GiB)
├─ vda1  600 MiB  EFI  → /boot/efi
├─ vda2  2 GiB    xfs  → /boot
└─ vda3  rest     LVM  → VG rhel
    ├─ LV root  15 GiB  xfs → /
    └─ LV swap   2 GiB
       about 420 MiB left free

k8s1, k8s2, k8s3: /dev/vda (20 GiB)
├─ vda1  600 MiB  EFI  → /boot/efi
├─ vda2  2 GiB    xfs  → /boot
└─ vda3  rest     LVM  → VG rhel
    └─ LV root  15 GiB  xfs → /
       2.41 GiB left free (LV swap removed)

db1: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ LV pgdata  7 GiB  xfs → /pgdata
       about 3 GiB left free for later growth

db2: /dev/vdb (10 GiB)
└─ vdb1  whole disk  LVM  → VG data
    ├─ LV backup  3 GiB  xfs → /srv/backup
    └─ LV pgdata  5 GiB  xfs → /pgdata
       about 2 GiB left free to practise extending an LV

k8s2, k8s3: /dev/vdb (5 GiB)
└─ vdb1  whole disk  LVM  → VG data
    └─ one LV per Kubernetes volume  xfs → its pod
```

## Why

- [A separate data disk per VM](../../decisions/a-separate-data-disk-per-vm.md), because VG `rhel` has only about 420 MiB free, and a full data disk cannot fill `/`.
- A clone gets a new hostname, machine ID, SSH host keys and registration before its first SSH login, because it copies all four from `rhel-base`. systemd and the journal use the machine ID as the unique ID of the system, the same host keys on every clone would make them interchangeable to SSH, and each registered system needs its own identity.
- The nodes have no swap, because the kubelet does not start when it finds swap. The LV is removed, not only turned off, so no boot can turn it on again.
- No file in `/etc/modules-load.d/`: the kernel loads `overlay` at the first overlay mount, and `br_netfilter` matters only for a bridge network, which CRI-O ships disabled.
- k8s1 has 3 GiB, because at 2.5 GiB it ran so short of memory after a reboot that it stopped answering ([Tested](#tested)). It has no swap to fall back on, and the API server grows with every CRD.

## Limits

- No role keeps the node setup yet. A rebuilt node needs the packages, the locks and the files from `kubernetes/nodes/` by hand again.
- kdump reserves 256 MiB on every VM (`crashkernel=`). With the kernel's own share, a worker shows about 2139 MiB of its 2.5 GiB in `MemTotal`, and k8s1 2578 MiB of its 3 GiB.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-07 | `lvextend -r -L 7G data/pgdata` while a `psql` session was open ([runbook](../../runbooks/grow-a-data-volume.md)) | `pgdata` grew from 5 GiB to 7 GiB. The session stayed, and the fstab UUID did not change. |
| 2026-11-14 | Reboot of k8s1 after the swap LV and its kernel arguments were removed | No swap, 0 failed units, initrd 1.844 s. The boot does not wait for the removed LV. |
| 2026-11-14 | `kubeadm init phase preflight` on k8s1 | Exit 0 with two warnings: firewalld is active, and CRI-O used `pause:3.10.1`, not `3.10.2`. The pause drop-in was written after this run. |
| 2026-11-20 | Reboot of k8s1, k8s2 and k8s3 at once (`ansible.builtin.reboot`), k8s1 at 2.5 GiB, then at 3 GiB | At 2.5 GiB k8s1 stopped answering ssh and port 6443 about 6 min 30 s after the boot, until `virsh reset`. After it `kube-apiserver` used 651 MiB, with 474 of 2139 MiB `available`. At 3 GiB checks 25 to 31 passed. |
