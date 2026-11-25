# etcd backup

A systemd timer on k8s1 takes a snapshot of the etcd of the [Kubernetes cluster](cluster.md) every night and keeps the newest 7 in `/srv/etcd-backup`. A restore from a snapshot brings back the whole state of the cluster at the time of the snapshot.

Checks: [35](../../../checks/35-etcd-backup.sh) · Files: [`kubernetes/etcd/`](../../../kubernetes/etcd/)

## Setup

### Tools

| Part | Setup |
|---|---|
| etcd | `registry.k8s.io/etcd:3.6.8-0`, the static pod of kubeadm on k8s1, with its data in `/var/lib/etcd` |
| `etcdctl` and `etcdutl` | 3.6.8 from `etcd-v3.6.8-linux-amd64.tar.gz` of the etcd release on GitHub, checked with `sha256sum -c` against its `SHA256SUMS` |
| Install | `/usr/local/bin` on k8s1, mode 755, owner root, type `bin_t` |
| Client certificate | `healthcheck-client.crt` and `healthcheck-client.key` with `ca.crt` from `/etc/kubernetes/pki/etcd/` (the client-only certificate kubeadm makes for tools) |
| Endpoint | `https://127.0.0.1:2379`, run as root with the full path `/usr/local/bin/etcdctl` |

### Snapshot

| Part | Setup |
|---|---|
| Script | `/usr/local/bin/etcd-snapshot.sh`, mode 755, owner root, type `bin_t`. The endpoint and the certificate come from four `ETCDCTL_*` variables. |
| Steps | `etcdctl snapshot save` to `<name>.tmp`, then `etcdutl snapshot status` reads it, then `mv` gives it its name. A failed step removes the `.tmp` file and exits with 1. |
| Name | `etcd-<stamp>.db`, the stamp in UTC from `date -u +%Y%m%dT%H%M%SZ`, such as `etcd-20261125T155329Z.db` |
| File mode | 600, owner root, from `umask 077` |
| Service | `etcd-snapshot.service`, `Type=oneshot`, `After=kubelet.service`, as root (no `User=`). It has no `[Install]`, so only the timer starts it. |
| Retry | `Restart=on-failure` with `RestartSec=1min`, at most 10 starts in 15 min (for the boot run before etcd is up). A start by hand counts too. |
| Timer | `etcd-snapshot.timer`, `OnCalendar=*-*-* 01:00:00 UTC`, `Persistent=true`, enabled |
| Destination | `/srv/etcd-backup` on `/` of k8s1, mode 700, owner root, type `var_t` |
| Retention | The newest 7 `etcd-*.db` files by name (`head -n -7`), about 221 MB on `/` |

### Restore

| Part | Setup |
|---|---|
| Procedure | [Restore etcd from a snapshot](../../runbooks/restore-etcd-from-a-snapshot.md), with the four static pods stopped by moving their manifests out of `/etc/kubernetes/manifests/` |
| Data directory | A new `/var/lib/etcd`, the path in the etcd manifest (`kubeadm upgrade` writes the manifest from `etcd.local.dataDir`) |
| Member | `--name k8s1`, `--initial-cluster k8s1=https://192.168.122.21:2380` and `--initial-advertise-peer-urls https://192.168.122.21:2380`, the flags of the manifest |
| Revision | `--bump-revision 1000000000 --mark-compacted`, so the revision never goes back |
| Labels | `/var/lib/etcd` and `member` 700 root with the type `var_lib_t`, as `matchpathcon` expects |

## Layout

The snapshots on k8s1:

```
/srv/etcd-backup                 root  700  var_t
├── etcd-<stamp>.db              root  600  the newest 7, 32 MB each
└── manual-2026-11-25.db         root  600  the first snapshot, by hand
```

## Why

- `etcdctl` and `etcdutl` from the etcd release on the host, not from the etcd image, because a restore runs while the etcd pod is stopped. They have the version of the server, 3.6.8.
- `umask 077` and a destination only root reads, because a snapshot holds every object of the cluster, the Secrets too, without encryption. The service runs as root, because only root reads the client key.
- The snapshot keeps the name `.tmp` until `etcdutl snapshot status` reads it, so a broken file never gets the name `etcd-*.db` and never counts as one of the 7.
- The rotation counts files, not days, because the lab is off for days, and a snapshot is taken only while k8s1 runs.
- The timer and the stamp in UTC, so the names sort by time and the 01:00 run does not move with summer time.

## Limits

- The snapshots stay on the disk of k8s1, the only control plane node, so a lost k8s1 takes etcd and its backups with it. No copy leaves the host.
- A restore rolls back every object to the time of the snapshot, the CloudNativePG Cluster `pg` too. For about 20 s after it the API shows the pods as the snapshot saw them.
- After the restore, the operators with leader election restarted once. The CloudNativePG operator started before the API was up, went through `CrashLoopBackOff` and came back on its own.
- Not tested after a reboot: the boot run of `Persistent=true` and its retries were not seen. Check 35 ran once, on 2026-11-25, with no negative test.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-25 | A snapshot by hand, then eight runs of the service in a row | 32 MB (31617056 bytes) in 0.39 s by hand, under a second per run. The eighth run removed the oldest, so 7 stay. |
| 2026-11-25 | Restore of the namespace `etcd-test`, deleted 16 s after its snapshot, with the [failover client](cloudnativepg.md#failover-client) writing to `pg` ([runbook](../../runbooks/restore-etcd-from-a-snapshot.md)) | API down 45.9 s, of which 30.9 s to stop and 9.4 s to read the output. The pods of `etcd-test` ran again with their old IPs about 71 s after the stop. |

## History

- Old data directory (k8s1, lesson 35): `/var/lib/etcd` up to the restore of 2026-11-25. It stays as `/var/lib/etcd-before-restore`, the undo of the restore.
