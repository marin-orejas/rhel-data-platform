# Roadmap

I do every step by hand first, then automate it. Every setting must still work after a reboot, like on the RHCSA exam.

## Phase 0: Lab
- [x] Red Hat Developer Subscription for Individuals (free, up to 16 systems)
- [x] Kickstart file for the NUC (`kickstart/nuc-host.ks`), install from USB
- [x] Static IP, hostname, SSH key login, sudo user, time sync, firewall
- [x] KVM/libvirt and Cockpit on the NUC
- [x] Base VM image from a kickstart file (`kickstart/rhel-base-vm.ks`)
- [x] Clone `db1` and `db2`, give each its own hostname, IP and machine-id

*RHCSA topics: install, SSH, network, users and sudo, time, firewall.*

## Phase 1: PostgreSQL by hand
- [x] New disk → GPT partition → PV/VG/LV → XFS → mount by UUID
- [x] Install `postgresql18-server`, run `initdb`, enable the service
- [x] Use a non-default port (5433) and connect from db2: SELinux port label, firewall rule, `listen_addresses`, `pg_hba.conf`
- [x] Data directory on `/pgdata`: `semanage fcontext` and `restorecon`
- [x] Persistent journal
- [x] Tuned profile, DBA group, umask, ACLs
- [ ] Backup script (`pg_dump`, tar/gzip) run by a systemd timer (and by cron, to compare)
- [ ] NFS share on db2, mounted on db1 with autofs
- [ ] Disk full: extend the LV while the system runs
- [ ] Break and fix: bad fstab, emergency mode, root password reset, GRUB

*RHCSA topics: storage, file systems, SELinux, scripts, scheduled jobs, boot, logs, permissions.*

## Phase 2: Replication and ETL
- [ ] Streaming replication db1 → db2 (`pg_basebackup`), test failover
- [ ] ETL: load a public dataset into staging tables, transform it with SQL into report tables, run it on a timer
- [ ] DBA basics: roles and privileges, `pg_hba.conf`, point-in-time recovery, `EXPLAIN`, `VACUUM`

## Phase 3: RHCSA practice
- [ ] Other exam topics: Flatpak, VFAT, IPv6, `at`, nice/renice
- [ ] 3-hour practice exam on a new VM, checked by the scripts in `checks/`

## Phase 4: Ansible
- [ ] Inventory, roles, `rhel-system-roles` (postgresql, firewall, selinux, storage), Vault for passwords
- [ ] `ansible-playbook site.yml` builds db1 and db2 from fresh clones

## Phase 5: Containers
- [ ] Podman without root, a Containerfile for the ETL job (UBI base image)
- [ ] Run containers as systemd services with Quadlet, try `podman kube play`

## Phase 6: Kubernetes
- [ ] k3s in a VM, the ETL job as a CronJob
- [ ] PostgreSQL with the CloudNativePG operator, PVCs, Services, Helm basics

## Learning resources
- RHEL/RHCSA: [Sander van Vugt (YouTube)](https://www.youtube.com/channel/UComgXoI6pysmetOzuNH_TDQ), [EX200 exam topics](https://www.redhat.com/en/services/training/ex200-red-hat-certified-system-administrator-rhcsa-exam)
- Databases: [CMU 15-445 Intro to Database Systems](https://www.youtube.com/playlist?list=PLSE8ODhjZXjYMAgsGH-GtY5rJYZ6zjsd5), [Hussein Nasser, PostgreSQL](https://www.youtube.com/playlist?list=PLQnljOFTspQWGrOqslniFlRcwxyY94cjj)
- Ansible: [Jeff Geerling, Ansible 101](https://www.youtube.com/playlist?list=PL2_OBreMn7FqZkvMYt6ATmgC0KAGGJNAN)
- Kubernetes: [TechWorld with Nana](https://www.youtube.com/c/TechWorldwithNana)
