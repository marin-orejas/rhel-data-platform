# Roadmap

I do every step by hand first, then automate it. Every setting must still work after a reboot, like on the Red Hat exams. From phase 3 on, each item is one lesson: about one working day, ending in a verified and committed result. The scripts in [`checks/`](../checks/) verify the results. I plan one phase ahead: a new phase goes in when the current one is nearly done.

## Phase 0: Lab
- [x] A free Red Hat developer subscription and the RHEL 10.2 installer on a USB stick.
- [x] The NUC was installed from a kickstart file, then registered and updated.
- [x] The NUC has a static IP, a sudo user, SSH with keys only, time sync, a firewall and Secure Boot.
- [x] The NUC runs KVM with a storage pool, a NAT network and Cockpit, and all of it comes back after a reboot.
- [x] A base VM image from a kickstart file, with a fixed IP and a thin disk.
- [x] db1 and db2 are clones of the base image, each with its own name, IP, machine ID, SSH keys and registration.

*RHCSA topics: software from the CDN, services, SSH, network, users and sudo, time, firewall.*

## Phase 1: PostgreSQL by hand
- [x] db1 has a data disk with LVM and XFS, mounted on `/pgdata` by UUID.
- [x] PostgreSQL 18 is installed and starts only after `/pgdata` is mounted.
- [x] PostgreSQL listens on port 5433, and db2 can connect through SELinux and the firewall.
- [x] The data directory on `/pgdata` has the right SELinux labels.
- [x] The system journal is kept across reboots on the NUC, db1 and db2.
- [x] PostgreSQL has its own tuned profile, and the `dba` group shares a directory with setgid, default ACLs and a umask.
- [x] A script run by a systemd timer dumps every database and the config files, and a test restore works.
- [x] db2 shares a backup disk over NFS, and db1 mounts it with autofs.
- [x] A full `/pgdata` stopped PostgreSQL, and the volume was grown while a `psql` session stayed open.
- [x] db2 was booted into emergency mode from GRUB, and its default target and kernel arguments were changed.

*RHCSA topics: storage, file systems, NFS and autofs, SELinux, packages, services, tuned, groups and permissions, scripts, scheduled jobs, boot, logs.*

## Phase 2: RHCSA practice
- [x] The other exam topics were practised: Flatpak, VFAT, IPv6, `at`, nice, `sudoers.d` and the root password reset.
- [x] A boot stopped by a bad fstab line was fixed from the emergency shell.
- [x] 20 three-hour practice exams and topic drills were taken, and every exam from 09 to 20 passed.
- [ ] The RHCSA exam (EX200).

## Phase 3: PostgreSQL operations
- [x] db1 was restored by hand to a set time from a base backup and WAL archived on db2, and the restore was timed.
- [x] pgBackRest makes full, differential and incremental backups to db2, deletes old ones and passed a timed restore.
- [x] db2 is a read-only standby that streams changes from db1 through a replication slot, and its lag is measured.
- [x] db2 takes over when db1 fails, the client follows, db1 comes back as a standby with `pg_rewind`, and the downtime is measured.

## Phase 4: Ansible
- [x] Ansible runs from the desktop with an inventory, a config file and SSH keys, first with ad hoc commands, then a playbook.
- [x] A base role sets up users, sudo, SSH, the firewall, SELinux, time sync and tuned on db1 and db2.
- [x] The `storage` role from `rhel-system-roles` sets up the data disks, and my own `postgresql` role sets up PostgreSQL.
- [x] Templates manage `postgresql.conf` and `pg_hba.conf`, a handler reloads PostgreSQL, and a dry run shows the changes first.
- [x] An app role and a read-only role get default privileges and their own `pg_hba.conf` rules, by hand first, then as code.
- [x] PostgreSQL uses TLS with a certificate from a small internal CA that clients check, by hand first, then as code with the keys in Vault.
- [x] Roles build the db2 standby and pgBackRest with its timers, and a playbook runs a timed restore test.
- [ ] One playbook builds db1 and db2 from fresh clones, a second run changes nothing, and GitHub Actions checks the code.

## Phase 5: Kubernetes
- [ ] Three clones of the base image get the base role, no swap, CRI-O and the Kubernetes 1.36 packages.
- [ ] kubeadm builds the cluster from a config file in the repo, with k8s1 as the control plane, two workers and Calico.
- [ ] An app runs as a Deployment with health checks and resource limits, and a rolling update and a rollback work.
- [ ] The app takes its settings from a ConfigMap and a Secret, and Kustomize builds it from files in the repo.
- [ ] Pods reach the app through a Service by its DNS name, and a network policy lets only one client in.
- [ ] MetalLB gives the app an address on the lab network, and a Gateway API route serves it outside the cluster.
- [ ] Each worker has its own data disk, a storage class creates volumes on it, and a volume grows while its pod runs.
- [ ] CloudNativePG runs PostgreSQL 18 as a primary and a standby on the two workers, and a failover is measured.
- [ ] cert-manager issues the PostgreSQL certificates from the lab CA, and clients check them with `verify-full`.
- [ ] db2 runs an S3 object store with TLS, set up by hand first, then as an Ansible role.
- [ ] CloudNativePG archives WAL and backs up to db2, and a dropped table comes back with a timed restore to a set time.
- [ ] Labels, affinity and taints decide where pods run, and a CronJob dumps the `app` database every night.
- [ ] metrics-server shows what each pod uses, a quota caps the app namespace, and an autoscaler adds pods under load.
- [ ] A read-only user signs in with a certificate from the cluster CA, and the CronJob runs with only the rights it needs.
- [ ] The app namespace enforces the `restricted` pod security level, and every pod in it runs as a non-root user.
- [ ] A timer on k8s1 takes an etcd snapshot every night, and a timed restore brings back a deleted namespace.
- [ ] kubeadm upgrades the cluster from 1.36 to 1.37 one node at a time while PostgreSQL stays up, with the outage measured.
- [ ] Argo CD applies the cluster's apps from this repo, so a change is a commit and a change by hand is undone.
- [ ] An Ansible role prepares the nodes, and a playbook brings a reset worker back into the cluster.
- [ ] Ansible builds the cluster from fresh clones in one timed run, Argo CD brings the apps back, and a second run changes nothing.

## Learning resources
- RHEL: [Sander van Vugt (YouTube)](https://www.youtube.com/channel/UComgXoI6pysmetOzuNH_TDQ), [EX200 exam topics](https://www.redhat.com/en/services/training/ex200-red-hat-certified-system-administrator-rhcsa-exam)
- Kubernetes: [Kubernetes documentation](https://kubernetes.io/docs/home/), [CloudNativePG documentation](https://cloudnative-pg.io/docs/), [Argo CD documentation](https://argo-cd.readthedocs.io/)
- Databases: [CMU 15-445 Intro to Database Systems](https://www.youtube.com/playlist?list=PLSE8ODhjZXjYMAgsGH-GtY5rJYZ6zjsd5), [Hussein Nasser, PostgreSQL](https://www.youtube.com/playlist?list=PLQnljOFTspQWGrOqslniFlRcwxyY94cjj), [PostgreSQL 18 documentation](https://www.postgresql.org/docs/18/), [PostgreSQL 14 Internals (Egor Rogov, free)](https://postgrespro.com/community/books/internals)
- Backups: [pgBackRest User Guide for RHEL](https://pgbackrest.org/user-guide-rhel.html)
- Reliability: *Database Reliability Engineering* (Laine Campbell, Charity Majors, O'Reilly), [Google SRE book (free)](https://sre.google/sre-book/table-of-contents/)
- Ansible: [Jeff Geerling, Ansible 101](https://www.youtube.com/playlist?list=PL2_OBreMn7FqZkvMYt6ATmgC0KAGGJNAN), [RHEL System Roles](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/automating_system_administration_by_using_rhel_system_roles/index)
