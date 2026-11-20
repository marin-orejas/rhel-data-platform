# TopoLVM with thick LVs

Date: 2026-11-19
Status: Accepted

## Context

The apps of later lessons, PostgreSQL with CloudNativePG first, need volumes that live on a worker, keep their data when the pod is made again, and grow while the pod runs. k8s2 and k8s3 each have a 5 GiB data disk with VG `data`, as db1 and db2 have theirs ([A separate data disk per VM](a-separate-data-disk-per-vm.md)). local-path-provisioner, the usual local storage of small clusters, makes each volume a directory on the node and ignores its size ("No support for the volume capacity limit currently", its README). So a volume has no size to grow, and one volume can fill the disk for all of them. TopoLVM is a CSI driver that makes each volume an LV in a volume group on its node. Its LVs are thick, or thin in a thin pool that can promise more space than the VG has.

## Decision

TopoLVM 0.42.1 makes the volumes of the default StorageClass `topolvm`: one thick LV in VG `data` per volume, with XFS, `WaitForFirstConsumer` and volume expansion on. It keeps no spare space in the VG (`spare-gb: 0`).

## Consequences

- A volume grows while its pod runs. `data-writer-0` went from 1Gi to 2Gi in about 1 s, with no restart.
- The capacity Kubernetes sees is the real free space of VG `data` on each worker, so the scheduler never places a volume that does not fit, and no volume stops because a pool is full.
- A thick LV takes its full size in the VG at once, even when the volume is nearly empty.
- No volume snapshots, because TopoLVM makes them only of thin LVs.
- A volume is bound to its worker. When that worker is down, its pod cannot start on the other one, and a lost data disk loses the volume.

Details: [Kubernetes storage](../architecture/kubernetes/storage.md)
