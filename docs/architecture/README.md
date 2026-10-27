# Architecture

The lab runs on one NUC with RHEL 10.2 as a KVM host. db1 runs PostgreSQL 18 with its data on a separate disk. db2 holds the backups of db1 on an NFS share: pgBackRest backups with the archived WAL, and nightly dumps. A restore to a set time has been tested.

What runs where is below. How to do a task on the lab: [Runbooks](../runbooks/).

## Machines

| Host | Role | OS | CPU / RAM | Disk | Status |
|---|---|---|---|---|---|
| desktop | Workstation, git, SSH, Ansible (phase 4) | Fedora 44 | i3-12100F / 16 GB | — | in use |
| nuc | VM host with KVM and Cockpit, no monitor | RHEL 10.2 | i3-1315U / 16 GB | 120 GB SSD | in use |
| rhel-base | Base VM image. Only used for cloning | RHEL 10.2 | 2 CPU / 2 GB | 20 GB | built |
| db1 | PostgreSQL primary | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| db2 | Backup storage (NFS), PostgreSQL replica in phase 3 | clone of rhel-base | 2 CPU / 3 GB | 20 GB + 10 GB data | in use |
| k3s | Kubernetes (phase 9) | clone of rhel-base | 2 CPU / 4 GB | 30 GB | planned |

RAM on the nuc: host about 2 GB, db1 and db2 3 GB each, later k3s 4 GB. That is about 12 of 16 GB.

## Pages

| Page | What it covers |
|---|---|
| [NUC host](host.md) | virtualization, network and access, the NUC disk |
| [VMs](vms.md) | base VM image, clones, data disks |
| [PostgreSQL on db1](postgresql.md) | package, service, data directory, settings, remote access |
| [Backups](backups.md) | pgBackRest, nightly dumps, restore tests, the archive by hand |
| [NFS share](nfs.md) | the export on db2, autofs on db1 |
| [System settings on every host](system.md) | SELinux, firewall, tuning, journal, the DBA group |
