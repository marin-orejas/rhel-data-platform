# kubeadm with CRI-O

Date: 2026-11-07
Status: Accepted

## Context

The Kubernetes lessons need a cluster on the NUC with one control plane and two workers, beside db2. Later lessons back up etcd, upgrade the cluster one node at a time and build it with Ansible, so each part of the cluster must be visible on its own. k3s runs the whole control plane in one process, with its own network plugin, datastore and container runtime built in. OpenShift Local runs the cluster in one VM that needs about 4 CPUs and more than 10 GB of RAM, which leaves no room for db2 on the NUC's 14 GiB. kubeadm builds an upstream cluster from separate parts, on a container runtime of choice. containerd is the more common runtime, and CRI-O is the one that OpenShift, Red Hat's Kubernetes, runs on.

## Decision

kubeadm builds the cluster on three clones of the base image: k8s1 as the control plane, k8s2 and k8s3 as workers, each with 2 CPU and 2.5 GiB. The container runtime is CRI-O. kubeadm, the kubelet and CRI-O come from the upstream repos for Kubernetes 1.36.

## Consequences

- etcd, the API server, the controller manager and the scheduler run as static pods on k8s1, each with its own manifest in `/etc/kubernetes/manifests/`.
- CRI-O has one minor version for each Kubernetes minor version, so the upgrade to 1.37 moves the repos of the kubelet, kubeadm and CRI-O together.
- Red Hat does not support kubeadm or CRI-O on RHEL. Both come from repos outside RHEL, held at their versions with `dnf versionlock` on every node.
- kubeadm installs no network plugin and no way in from outside the lab network, so Calico and an SSH tunnel for `kubectl` are separate work.
- The three nodes take 7.5 GiB, so db1 stays off during the Kubernetes lessons.

Details: [Kubernetes cluster](../architecture/kubernetes/cluster.md)
