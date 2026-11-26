# Upgrade the Kubernetes cluster

## When to use

When a new Kubernetes patch release is out for the minor version the cluster runs, such as 1.36.6 to 1.36.7, with a new CRI-O patch beside it. How the cluster is set up: [Kubernetes cluster](../architecture/kubernetes/cluster.md).

## Before you start

- The new versions are in the repos `kubernetes` and `cri-o` of the nodes, and CloudNativePG, cert-manager and TopoLVM support them. The commands below use kubeadm, kubelet and kubectl `1.36.7` and CRI-O `1.36.9`.
- The SSH tunnel to the API server runs in a second terminal for every `kubectl` on the desktop ([Kubernetes cluster, Access from the desktop](../architecture/kubernetes/cluster.md#access-from-the-desktop)).
- db2 runs, so the WAL archive of `pg` keeps working while the primary moves.
- To measure the outage, the [failover client](../architecture/kubernetes/cloudnativepg.md#failover-client) writes to its own table through `pg-rw` during the upgrade.

## Steps

1. **desktop**: read the state. Every node must be `Ready` on the old version and the Cluster `pg` healthy. Note the node of the primary.

   ```bash
   kubectl get nodes -o wide
   kubectl cnpg status pg -n pg
   kubectl get pdb -A
   ```

2. **k8s1**: install the new kubeadm and read the plan, which must offer `v1.36.7`. `--refresh` is there because a release from the same day is not in the cached metadata yet, and `&&` stops the lines after a failed install.

   ```bash
   sudo dnf versionlock delete kubeadm &&
   sudo dnf install -y --refresh kubeadm-1.36.7 --disableexcludes=kubernetes &&
   sudo dnf versionlock add kubeadm &&
   sudo kubeadm upgrade plan
   ```

3. **k8s1**: upgrade the control plane. The API server restarts, its certificates are renewed, and etcd stays on `3.6.8-0`.

   ```bash
   sudo kubeadm upgrade apply v1.36.7 --yes
   ```

4. **desktop**: drain k8s1. Its CoreDNS pods move to the workers.

   ```bash
   kubectl drain k8s1 --ignore-daemonsets --delete-emptydir-data --timeout=600s
   ```

5. **k8s1**: install the new kubelet, kubectl and CRI-O, lock them and reboot. The API server is down until k8s1 is back, 30 to 61 s in the test.

   ```bash
   sudo dnf versionlock delete kubelet kubectl cri-o &&
   sudo dnf install -y --refresh kubelet-1.36.7 kubectl-1.36.7 cri-o-1.36.9 --disableexcludes=kubernetes &&
   sudo dnf versionlock add kubelet kubectl cri-o &&
   sudo systemctl reboot
   ```

6. **desktop**: once the API answers again, wait until k8s1 runs the new kubelet, uncordon it and wait for CoreDNS.

   ```bash
   kubectl wait node/k8s1 --for=jsonpath='{.status.nodeInfo.kubeletVersion}'=v1.36.7 --timeout=300s
   kubectl wait node/k8s1 --for=condition=Ready --timeout=300s
   kubectl uncordon k8s1
   kubectl rollout status deployment/coredns -n kube-system --timeout=180s
   ```

7. **desktop**: drain a worker. Steps 7 to 10 run once per worker, first for the worker of the primary (k8s3 in the test), then for the other one, with its name in place of `<worker>`. The PodDisruptionBudget `pg-primary` makes CloudNativePG switch over to the standby before the primary leaves.

   ```bash
   kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data --timeout=600s
   ```

8. **desktop**: only when the drain stopped at its timeout with a `pg` pod still `Terminating`, wait for that pod and drain again. `<pod>` is its name (`pg-2` in the test). A pod evicted right after its switchover restart waits out the grace period of 1800 s.

   ```bash
   kubectl wait pod/<pod> -n pg --for=delete --timeout=900s
   kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data --timeout=600s
   ```

9. **k8s3**, then **k8s2**: on the drained worker, install the new packages, lock them, upgrade the kubelet config and reboot.

   ```bash
   sudo dnf versionlock delete kubeadm kubelet kubectl cri-o &&
   sudo dnf install -y --refresh kubeadm-1.36.7 kubelet-1.36.7 kubectl-1.36.7 cri-o-1.36.9 --disableexcludes=kubernetes &&
   sudo dnf versionlock add kubeadm kubelet kubectl cri-o &&
   sudo kubeadm upgrade node &&
   sudo systemctl reboot
   ```

10. **desktop**: wait until the worker runs the new kubelet, uncordon it and wait until the Cluster `pg` is ready again. After the second worker the primary is back on the first one.

    ```bash
    kubectl wait node/<worker> --for=jsonpath='{.status.nodeInfo.kubeletVersion}'=v1.36.7 --timeout=600s
    kubectl wait node/<worker> --for=condition=Ready --timeout=300s
    kubectl uncordon <worker>
    kubectl wait cluster/pg -n pg --for=condition=Ready --timeout=600s
    ```

## Check

- `kubectl get nodes -o wide` shows all three nodes `Ready`, `v1.36.7` and `cri-o://1.36.9`, and none `SchedulingDisabled`.
- On each node, `rpm -q kubeadm kubelet kubectl cri-o` shows the new versions, and `/etc/dnf/plugins/versionlock.list` locks them.
- `kubectl cnpg status pg -n pg` shows `Cluster in healthy state`, one primary and a streaming standby.
- Checks 25, 26 and 36 pass.

Last tested: 2026-11-25 on k8s1, k8s2 and k8s3, 1.36.6 to 1.36.7 with writes stopped at most 20.3 s and no rows lost
