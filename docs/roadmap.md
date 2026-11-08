# Roadmap

I do every step by hand first, then automate it. Every setting must still work after a reboot, like on the Red Hat exams. Each numbered item is one lesson, ending in a verified and committed result. An item's number is also the number of its script in [`checks/`](../checks/) when the lesson has one. A new topic goes in when the current ones are nearly done.

Journal entries name the old phases: phase 0 is 01–04, phase 1 is 05–12, phase 2 is R1–R4, phase 3 is 13–16, phase 4 is 17–24 and phase 5 is 25–44.

## Lab (01–04)
- [x] **01 NUC install.** The NUC runs a registered RHEL 10.2 from a kickstart file, with a static IP, a sudo user, SSH with keys only, time sync, a firewall and Secure Boot.
- [x] **02 KVM.** The NUC runs KVM with a storage pool, a NAT network and Cockpit, and all of it comes back after a reboot.
- [x] **03 Base image.** A base VM image from a kickstart file, with a fixed IP and a thin disk.
- [x] **04 Clones.** db1 and db2 are clones of the base image, each with its own name, IP, machine ID, SSH keys and registration.

*RHCSA topics: software from the CDN, services, SSH, network, users and sudo, time, firewall.*

## One PostgreSQL host (05–08)
- [x] **[05 Storage](../checks/05-storage.sh).** db1 has a data disk with LVM and XFS, mounted on `/pgdata` by UUID, and the system journal is kept across reboots on the NUC, db1 and db2.
- [x] **[06 PostgreSQL](../checks/06-postgres.sh).** PostgreSQL 18 is installed and starts only after `/pgdata` is mounted, and its data directory has the right SELinux labels.
- [x] **[07 Remote access](../checks/07-postgres-remote.sh).** PostgreSQL listens on port 5433, and db2 can connect through SELinux and the firewall.
- [x] **[08 Tuned and dba group](../checks/08-tuned-dba.sh).** PostgreSQL has its own tuned profile, and the `dba` group shares a directory with setgid, default ACLs and a umask.

*RHCSA topics: storage, file systems, SELinux, packages, services, logs, tuned, groups and permissions.*

## Backups, NFS and failures by hand (09–12)
- [x] **[09 Backup](../checks/09-backup.sh).** A script run by a systemd timer dumps every database and the config files, and a test restore works.
- [x] **[10 NFS](../checks/10-nfs.sh).** db2 shares a backup disk over NFS, and db1 mounts it with autofs.
- [x] **11 Full disk.** A full `/pgdata` stopped PostgreSQL, and the volume was grown while a `psql` session stayed open.
- [x] **12 Emergency boot.** db2 was booted into emergency mode from GRUB, and its default target and kernel arguments were changed.

*RHCSA topics: scripts, scheduled jobs, NFS and autofs, storage, boot.*

## RHCSA practice (R1–R4)
- [x] **R1 Other exam topics.** The other exam topics were practised: Flatpak, VFAT, IPv6, `at`, nice, `sudoers.d` and the root password reset.
- [x] **R2 Bad fstab.** A boot stopped by a bad fstab line was fixed from the emergency shell.
- [x] **R3 Practice exams.** 20 three-hour practice exams and topic drills were taken, and every exam from 09 to 20 passed.
- [ ] **R4 EX200.** The RHCSA exam (EX200).

## PostgreSQL recovery and failover (13–16)
- [x] **[13 PITR](../checks/13-pitr.sh).** db1 was restored by hand to a set time from a base backup and WAL archived on db2, and the restore was timed.
- [x] **[14 pgBackRest](../checks/14-pgbackrest.sh).** pgBackRest makes full, differential and incremental backups to db2, deletes old ones and passed a timed restore.
- [x] **[15 Replication](../checks/15-replication.sh).** db2 is a read-only standby that streams changes from db1 through a replication slot, and its lag is measured.
- [x] **[16 Failover](../checks/16-failover.sh).** db2 takes over when db1 fails, the client follows, db1 comes back as a standby with `pg_rewind`, and the downtime is measured.

## Ansible: the hosts as code (17–20)
- [x] **[17 Ansible](../checks/17-ansible.sh).** Ansible runs from the desktop with an inventory, a config file and SSH keys, first with ad hoc commands, then a playbook.
- [x] **[18 Base role](../checks/18-base-role.sh).** A base role sets up users, sudo, SSH, the firewall, SELinux, time sync and tuned on db1 and db2.
- [x] **[19 Storage and PostgreSQL roles](../checks/19-storage-postgresql.sh).** The `storage` role from `rhel-system-roles` sets up the data disks, and my own `postgresql` role sets up PostgreSQL.
- [x] **[20 PostgreSQL templates](../checks/20-postgresql-templates.sh).** Templates manage `postgresql.conf` and `pg_hba.conf`, a handler reloads PostgreSQL, and a dry run shows the changes first.

## Ansible: PostgreSQL services (21–24)
- [x] **[21 App roles](../checks/21-app-roles.sh).** An app role and a read-only role get default privileges and their own `pg_hba.conf` rules, by hand first, then as code.
- [x] **[22 TLS](../checks/22-tls.sh).** PostgreSQL uses TLS with a certificate from a small internal CA that clients check, by hand first, then as code with the keys in Vault.
- [x] **[23 Standby and backup roles](../checks/23-standby-backup-roles.sh).** Roles build the db2 standby and pgBackRest with its timers, and a playbook runs a timed restore test.
- [ ] **24 Fresh clones.** One playbook builds db1 and db2 from fresh clones, a second run changes nothing, and GitHub Actions checks the code.

## Kubernetes: cluster and apps (25–28)
- [ ] **25 Nodes.** Three clones of the base image get the base role, no swap, CRI-O and the Kubernetes 1.36 packages.
- [ ] **26 Cluster.** kubeadm builds the cluster from a config file in the repo, with k8s1 as the control plane, two workers and Calico.
- [ ] **27 Deployment.** An app runs as a Deployment with health checks and resource limits, and a rolling update and a rollback work.
- [ ] **28 App settings.** The app takes its settings from a ConfigMap and a Secret, and Kustomize builds it from files in the repo.

## Kubernetes: traffic and storage (29–31)
- [ ] **29 Inside the cluster.** Pods reach the app through a Service by its DNS name, and a network policy lets only one client in.
- [ ] **30 From outside.** MetalLB gives the app an address on the lab network, and a Gateway API route serves it outside the cluster.
- [ ] **31 Storage.** Each worker has its own data disk, a storage class creates volumes on it, and a volume grows while its pod runs.

## PostgreSQL on Kubernetes (32–35)
- [ ] **32 CloudNativePG.** CloudNativePG runs PostgreSQL 18 as a primary and a standby on the two workers, and a failover is measured.
- [ ] **33 TLS for PostgreSQL.** cert-manager issues the PostgreSQL certificates from the lab CA, and clients check them with `verify-full`.
- [ ] **34 Object store.** db2 runs an S3 object store with TLS, set up by hand first, then as an Ansible role.
- [ ] **35 Backups and restore.** CloudNativePG archives WAL and backs up to db2, and a dropped table comes back with a timed restore to a set time.

## Kubernetes: safe operations (36–40)
- [ ] **36 Placement.** Labels, affinity and taints decide where pods run, and a CronJob dumps the `app` database every night.
- [ ] **37 Metrics and autoscaling.** metrics-server shows what each pod uses, a quota caps the app namespace, and an autoscaler adds pods under load.
- [ ] **38 Users and rights.** A read-only user signs in with a certificate from the cluster CA, and the CronJob runs with only the rights it needs.
- [ ] **39 Pod security.** The app namespace enforces the `restricted` pod security level, and every pod in it runs as a non-root user.
- [ ] **40 etcd backup.** A timer on k8s1 takes an etcd snapshot every night, and a timed restore brings back a deleted namespace.

## Kubernetes: upgrade and automation (41–44)
- [ ] **41 Upgrade.** kubeadm upgrades the cluster from 1.36 to 1.37 one node at a time while PostgreSQL stays up, with the outage measured.
- [ ] **42 Argo CD.** Argo CD applies the cluster's apps from this repo, so a change is a commit and a change by hand is undone.
- [ ] **43 Node role.** An Ansible role prepares the nodes, and a playbook brings a reset worker back into the cluster.
- [ ] **44 Fresh cluster.** Ansible builds the cluster from fresh clones in one timed run, Argo CD brings the apps back, and a second run changes nothing.

## Learning resources
- RHEL: [Sander van Vugt (YouTube)](https://www.youtube.com/channel/UComgXoI6pysmetOzuNH_TDQ), [EX200 exam topics](https://www.redhat.com/en/services/training/ex200-red-hat-certified-system-administrator-rhcsa-exam)
- Kubernetes: [Kubernetes documentation](https://kubernetes.io/docs/home/), [CloudNativePG documentation](https://cloudnative-pg.io/docs/), [Argo CD documentation](https://argo-cd.readthedocs.io/)
- Databases: [CMU 15-445 Intro to Database Systems](https://www.youtube.com/playlist?list=PLSE8ODhjZXjYMAgsGH-GtY5rJYZ6zjsd5), [Hussein Nasser, PostgreSQL](https://www.youtube.com/playlist?list=PLQnljOFTspQWGrOqslniFlRcwxyY94cjj), [PostgreSQL 18 documentation](https://www.postgresql.org/docs/18/), [PostgreSQL 14 Internals (Egor Rogov, free)](https://postgrespro.com/community/books/internals)
- Backups: [pgBackRest User Guide for RHEL](https://pgbackrest.org/user-guide-rhel.html)
- Reliability: *Database Reliability Engineering* (Laine Campbell, Charity Majors, O'Reilly), [Google SRE book (free)](https://sre.google/sre-book/table-of-contents/)
- Ansible: [Jeff Geerling, Ansible 101](https://www.youtube.com/playlist?list=PL2_OBreMn7FqZkvMYt6ATmgC0KAGGJNAN), [RHEL System Roles](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/automating_system_administration_by_using_rhel_system_roles/index)
