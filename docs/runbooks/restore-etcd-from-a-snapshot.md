# Restore etcd from a snapshot

## When to use

When objects in the Kubernetes cluster were deleted or broken, such as a namespace with its Deployment and ConfigMap, and a snapshot in `/srv/etcd-backup` on k8s1 still holds them. The restore brings back the whole state of the cluster at the time of the snapshot, not one object, and the API server is down while it runs. How the snapshots are set up: [etcd backup](../architecture/kubernetes/etcd-backup.md).

## Before you start

- Every change to the cluster after the snapshot is lost, the objects of CloudNativePG too. Choose the newest snapshot that still holds the lost objects.
- An SSH session to k8s1, with the admin kubeconfig `~/.kube/config` there for `kubectl`. Steps 1 to 5 run in this one session, because step 2 keeps the name of the snapshot in `snap`.
- Ansible on the desktop, with the key in the agent, for step 6.
- The SSH tunnel to the API server, open in a second terminal, for the check from the desktop ([Kubernetes cluster, Access from the desktop](../architecture/kubernetes/cluster.md#access-from-the-desktop)).

## Steps

1. **k8s1**: read the member flags of etcd, the four manifests and the SELinux labels of the data directory. Stop here if a flag differs from the restore command in step 4, or the type in `ls -ldZ` differs from `matchpathcon`.

   ```bash
   sudo grep -E -- '--(name|initial-cluster|initial-advertise-peer-urls|data-dir)=' /etc/kubernetes/manifests/etcd.yaml
   sudo ls -l /etc/kubernetes/manifests/
   sudo ls -ldZ /var/lib/etcd /var/lib/etcd/member
   matchpathcon /var/lib/etcd /var/lib/etcd/member
   ```

2. **k8s1**: keep the name of the newest snapshot in `snap` and read it. `/srv/etcd-backup` is 700 root, so the glob runs in a root shell. To restore an older snapshot, set `snap` to its path.

   ```bash
   snap=$(sudo bash -c 'ls -1 /srv/etcd-backup/etcd-*.db | tail -n 1')
   echo "$snap"
   sudo /usr/local/bin/etcdutl snapshot status "$snap" -w table
   ```

3. **k8s1**: stop the control plane. Move the four manifests out of `/etc/kubernetes/manifests/` and wait until no etcd or kube-apiserver container runs. The API is down from here to step 5. The file names are written in full, because only root reads the directory.

   ```bash
   sudo install -d -m 700 /etc/kubernetes/manifests-off
   sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests-off/
   until [ -z "$(sudo crictl ps -q --name 'etcd|kube-apiserver')" ]; do sleep 1; done
   sudo crictl ps --name 'etcd|kube-apiserver|kube-controller-manager|kube-scheduler'
   ```

4. **k8s1**: move the old data directory aside and restore the snapshot into a new `/var/lib/etcd`, with the member flags of step 1. Then compare the labels of the new and the old directory. If `etcdutl` prints an error, or the new directory has another type than the old one, do not go on to step 5. The old directory stays as `/var/lib/etcd-before-restore` until it is deleted by hand.

   ```bash
   sudo mv /var/lib/etcd /var/lib/etcd-before-restore
   sudo /usr/local/bin/etcdutl snapshot restore "$snap" --data-dir /var/lib/etcd --name k8s1 --initial-cluster k8s1=https://192.168.122.21:2380 --initial-advertise-peer-urls https://192.168.122.21:2380 --bump-revision 1000000000 --mark-compacted
   sudo restorecon -Rv /var/lib/etcd
   sudo ls -ldZ /var/lib/etcd /var/lib/etcd/member /var/lib/etcd-before-restore /var/lib/etcd-before-restore/member
   ```

5. **k8s1**: start the control plane. Move the manifests back and wait until `/readyz` answers. kube-controller-manager and kube-scheduler start again with them.

   ```bash
   sudo mv /etc/kubernetes/manifests-off/etcd.yaml /etc/kubernetes/manifests-off/kube-apiserver.yaml /etc/kubernetes/manifests-off/kube-controller-manager.yaml /etc/kubernetes/manifests-off/kube-scheduler.yaml /etc/kubernetes/manifests/
   until kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1; do sleep 1; done
   sudo rmdir /etc/kubernetes/manifests-off
   ```

6. **desktop**: restart the kubelet on k8s1, k8s2 and k8s3 from the folder `ansible/`, as the Kubernetes docs recommend after a restore.

   ```bash
   ansible k8s -b -m ansible.builtin.systemd_service -a 'name=kubelet state=restarted' | grep ' => '
   ```

## Check

- The lost objects are back: `kubectl get namespace etcd-test` shows `Active`, and its Deployment has 2 ready replicas in the test.
- The pods really run again. For about 20 s after step 5 the API still shows them as the snapshot saw them, so read `.status.containerStatuses[0].state.running.startedAt` of the pods, or run `sudo crictl pods --namespace etcd-test` on the workers. In the test the kubelet had rebuilt them 19 to 25 s after `/readyz`, before step 6.
- `kubectl cnpg status pg -n pg` shows the Cluster `pg` healthy with the same primary, and `kubectl get pods -A` shows every pod `Running`.

Last tested: 2026-11-25 on k8s1, `etcd-test` back from a snapshot, the API down 45.9 s, no failed writes to `pg`
