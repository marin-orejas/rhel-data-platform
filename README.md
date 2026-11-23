# RHEL Data Platform

![Status: in progress](https://img.shields.io/badge/status-in%20progress-bf8700?style=flat-square)
[![License](https://img.shields.io/github/license/marin-orejas/rhel-data-platform?style=flat-square)](LICENSE)

PostgreSQL platform on RHEL 10 in a KVM home lab, with replication, backups, Ansible and Kubernetes.
I build each part by hand first, then automate it.

It is a learning project that builds a foundation for RHCSA, RHCE with Ansible and CKA, with a separate [RHCSA practice lab](https://github.com/marin-orejas/rhcsa-practice-lab).

```mermaid
flowchart LR
    desk["Desktop (Fedora 44)<br/>git, Ansible, kubectl, helm"]
    subgraph nuc["NUC (RHEL 10.2)"]
        base["rhel-base<br/>base VM image"]
        db1["db1<br/>PostgreSQL primary"]
        db2["db2<br/>backup storage<br/>PostgreSQL standby"]
        k8s["k8s1, k8s2, k8s3<br/>Kubernetes cluster"]
        base -. clone .-> db1
        base -. clone .-> db2
        base -. clone .-> k8s
        db1 -- "streaming replication" --> db2
        db1 -- "backups (NFS)" --> db2
    end
    desk -- SSH --> nuc
```

## Highlights

- db2 stayed at most 0.33 s behind db1 during a 1,000,000-row insert.
- db2 took over from a failed db1 by hand in 5 min 51 s, with no rows lost.
- A restore to a set time with pgBackRest brought back a dropped table with 1.1 s of outage.
- One Ansible playbook builds db1 and db2 from fresh clones, db1 in 3 min 46 s.
- A 3-node kubeadm cluster serves an app through MetalLB and a Gateway API route.

## Lab

Every VM is a clone of rhel-base, a base image from a kickstart file, on the NAT network of the nuc.
The [host pages](docs/architecture/hosts/) describe the nuc, the VMs and their system settings.

| Host | Role | CPU / RAM | Disk |
|---|---|---|---|
| desktop | Fedora 44 workstation, Ansible control node | i3-12100F / 16 GB | 240 GB SSD |
| nuc | RHEL 10.2 KVM host with Cockpit, no monitor | i3-1315U / 16 GB | 120 GB SSD |
| rhel-base | Base VM image, only for cloning | 2 CPU / 2 GB | 20 GB |
| db1 | PostgreSQL primary | 2 CPU / 3 GB | 20 GB + 10 GB data |
| db2 | Backup storage (NFS), PostgreSQL standby | 2 CPU / 3 GB | 20 GB + 10 GB data |
| k8s1 | Kubernetes control plane with CRI-O | 2 CPU / 3 GB | 20 GB |
| k8s2 | Kubernetes worker with CRI-O | 2 CPU / 2.5 GB | 20 GB + 5 GB data |
| k8s3 | Kubernetes worker with CRI-O | 2 CPU / 2.5 GB | 20 GB + 5 GB data |

## RHEL administration

db1 and db2 run SELinux in enforcing mode.
[Check scripts](checks/) verify that every setting still works after a reboot.

| Topic | Result |
|---|---|
| Storage | Data disk with LVM and XFS, mounted on `/pgdata` by UUID |
| Remote access | PostgreSQL on port 5433, reached from db2 through SELinux and firewalld |
| Tuning | Own tuned profile for PostgreSQL |
| Shared directory | `dba` group with setgid, default ACLs and a umask |
| Backups | Dumps from a systemd timer, an NFS share mounted with autofs |
| Full disk | Volume grown while a `psql` session stayed open |
| Emergency boot | db2 booted into emergency mode from GRUB |

## PostgreSQL

db1 runs PostgreSQL 18 as the primary, and db2 keeps its standby and its backups.
The [PostgreSQL pages](docs/architecture/postgresql/) and the [backup pages](docs/architecture/backups/) describe each part.

| Topic | Result |
|---|---|
| Replication | db2 as a streaming standby, at most 0.33 s behind |
| Failover | db2 took over in 5 min 51 s by the [failover runbook](docs/runbooks/fail-over-to-db2.md), db1 came back with `pg_rewind` |
| Backups | pgBackRest every night to db2, over NFS |
| Restore test | Newest backup restored on db2 and compared with the standby in 18 s |
| Restore to a set time | Dropped table back in 9 min 31 s by hand, 1.1 s of outage with pgBackRest |
| Access | App login, read-only login, TLS from my own lab CA |

## Ansible

One playbook builds db1 and db2 from fresh clones, and a second run changes nothing.
The [Ansible pages](docs/architecture/ansible/) describe each role, and GitHub Actions lints every change to the code.

| Role | What it keeps |
|---|---|
| `base` | System settings on db1, db2 and the Kubernetes nodes |
| `storage` | Data disks, through the RHEL system role |
| `postgresql` | PostgreSQL and its logins, the standby on db2, TLS keys in Ansible Vault |
| `nfs` | Backup share on db2 |
| `pgbackrest` | pgBackRest backups to the NFS share |
| `pgdump` | Nightly dumps |

## Kubernetes

kubeadm built the [cluster](docs/architecture/kubernetes/) from a config file on 3 clones of the base image.
I use `kubectl` and Helm from my desktop through an SSH tunnel over the nuc.

| Part | Result |
|---|---|
| Cluster | kubeadm, CRI-O, Calico for the pod network |
| App | httpd Deployment with health checks and resource limits |
| Updates | Rolling update and rollback |
| Settings | Kustomize, a ConfigMap, a Secret kept out of the repo |
| In-cluster access | Service with a DNS name, network policies for a single client pod |
| Outside access | MetalLB address on the lab network, Traefik with a Gateway API route |
| Storage | TopoLVM volume on the data disk of each worker, grown while its pod ran |

## Tech stack

| Layer | Tools |
|---|---|
| Host | RHEL 10, KVM, libvirt, Cockpit, Kickstart |
| System | LVM, XFS, SELinux, firewalld, systemd, tuned, autofs, NFS |
| Database | PostgreSQL 18, pgBackRest |
| Automation | Ansible, Ansible Vault, Bash, GitHub Actions |
| Kubernetes | kubeadm, CRI-O, Calico, Kustomize, Helm, MetalLB, Traefik, TopoLVM |
| Workstation | Fedora 44, OpenSSH, kubectl |

## Project structure

| Folder | Contents |
|---|---|
| [`ansible/`](ansible/) | Roles, playbooks, inventory |
| [`checks/`](checks/) | 25 check scripts, named by lesson number |
| [`kickstart/`](kickstart/) | Kickstart files for the nuc and the base image |
| [`kubernetes/`](kubernetes/) | kubeadm config, app manifests, Helm values |
| [`docs/architecture/`](docs/architecture/) | What is built, a folder per area |
| [`docs/runbooks/`](docs/runbooks/) | Tested procedures, step by step |
| [`docs/decisions/`](docs/decisions/) | Why the lab is built this way |
| [`docs/journal/`](docs/journal/) | My notes, a file per lesson day |

## Roadmap

Each topic has 3 to 5 lessons, listed in the [full roadmap](docs/roadmap.md).

| Topic | Status |
|---|---|
| Lab (01–04) | done |
| One PostgreSQL host (05–08) | done |
| Backups, NFS and failures by hand (09–12) | done |
| PostgreSQL recovery and failover (13–16) | done |
| Ansible: the hosts as code and PostgreSQL services (17–24) | done |
| Kubernetes: cluster and apps (25–28) | done |
| Kubernetes: traffic and storage (29–31) | done |
| Kubernetes: CloudNativePG, backups and upgrade (32–36) | planned |

## License

MIT, see [LICENSE](LICENSE).
