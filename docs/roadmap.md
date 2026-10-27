# Roadmap

I do every step by hand first, then automate it. Every setting must still work after a reboot, like on the RHCSA exam. From phase 3 on, each item is one lesson: about one working day, ending in a verified and committed result. Check numbers refer to the scripts in [`checks/`](../checks/).

## Phase 0: Lab
- [x] Red Hat account: Developer Subscription for Individuals (free, up to 16 systems), RHEL 10.2 DVD on a USB stick
- [x] NUC install: `kickstart/nuc-host.ks` checked with `ksvalidator`, installed from the USB stick, registered and updated
- [x] NUC basics: static IP, hostname, sudo user, SSH key login only, time sync, firewall, Secure Boot
- [x] KVM host: libvirt checked with `virt-host-validate`, a storage pool, the NAT network and Cockpit, all back after a reboot
- [x] Base VM image: `kickstart/rhel-base-vm.ks`, a fixed IP from a DHCP reservation, a thin qcow2 disk, no autostart
- [x] Clones: db1 and db2 from the base image, each with its own hostname, IP, machine-id, SSH host keys and registration

*RHCSA topics: install, SSH, network, users and sudo, time, firewall.*

## Phase 1: PostgreSQL by hand
- [x] Data disk: new disk → GPT partition → PV/VG/LV → XFS → `/pgdata` mounted by UUID; check 05 passes
- [x] PostgreSQL install: `postgresql18-server`, `initdb`, a systemd drop-in that waits for `/pgdata`; check 06 passes
- [x] Remote access on port 5433: SELinux port label, firewall rule, `listen_addresses`, `pg_hba.conf`; check 07 passes from db2
- [x] Data directory on `/pgdata`: an SELinux rule with `semanage fcontext`, labels set with `restorecon`; check 06 passes
- [x] Persistent journal: a `journald.conf.d` drop-in on the NUC, db1 and db2, logs kept across reboots; check 05 passes
- [x] Tuning and permissions: a PostgreSQL tuned profile, the `dba` group, umask, a setgid directory with default ACLs; check 08 passes
- [x] Backup script: `pg_dump` per database, globals, config files, a systemd timer (cron to compare), a test restore; check 09 passes
- [x] NFS and autofs: an NFS share on a data disk on db2, mounted on db1 by autofs, backups written to it; check 10 passes
- [x] Disk full: fill `/pgdata` until PostgreSQL fails, grow the LV with `lvextend -r` while a `psql` session stays open
- [x] Break and fix: a one-time GRUB edit into emergency mode, the default boot target, kernel arguments with `grubby`

*RHCSA topics: storage, file systems, SELinux, scripts, scheduled jobs, boot, logs, permissions.*

## Phase 2: RHCSA practice
- [x] Other exam topics: Flatpak, VFAT, IPv6, `at`, nice and renice, `sudoers.d` rules, root password reset with `init=/bin/bash`
- [x] Emergency mode: a boot stopped by a bad fstab line, fixed from the emergency shell, then a normal boot
- [x] Practice exams and drills: 20 three-hour EX200-style exams and topic drills, checked after a reboot; exams 09–20 all PASS
- [ ] EX200 exam

## Phase 3: PostgreSQL operations
- [x] Point-in-time recovery by hand: WAL archiving to db2 (also with db2 down), a base backup, a timed restore to a set time
- [x] pgBackRest: full, differential and incremental backups to db2, retention, a timed restore test
- [x] Streaming replication db1 → db2: a replication slot, a read-only standby, lag queries
- [ ] Failover: promote db2, move the client, bring db1 back as a standby with `pg_rewind`, measure the downtime
- [ ] Roles and privileges: an application role, a read-only role, default privileges, `pg_hba.conf` rules per role
- [ ] TLS: a small internal CA, a server certificate, `hostssl` rules, a client that checks the certificate

## Phase 4: Ansible
- [ ] Control node on the desktop: inventory, `ansible.cfg`, ad hoc commands, a first playbook
- [ ] Base role: users and sudo, SSH, firewall, SELinux, time sync and tuned on db1 and db2
- [ ] Security baseline: an OpenSCAP scan, fixes from the generated Ansible remediation, a second scan
- [ ] System roles: the data disk with the `storage` role, PostgreSQL with the `postgresql` role from `rhel-system-roles`
- [ ] Database settings as code: templates for `postgresql.conf` and `pg_hba.conf`, roles, TLS files, secrets in Vault
- [ ] Replication and backups in roles: the db2 standby, pgBackRest with a backup timer, a restore test from a playbook
- [ ] Full build: `site.yml` on fresh db1 and db2 clones, no changes on a second run, `ansible-lint` and `shellcheck` in GitHub Actions

## Phase 5: Lab as code
- [ ] Cloud image: a VM from the RHEL KVM guest image, set up by cloud-init instead of a kickstart
- [ ] Terraform: the libvirt provider creates the network, volumes and VMs, cloud-init data from templates
- [ ] One-command lab: Terraform creates the VMs, Ansible configures them, a timed destroy and rebuild

## Phase 6: Containers and observability
- [ ] Podman without root: a Containerfile on a UBI base image, volumes, SELinux labels on volumes
- [ ] Quadlet: containers as systemd services, automatic image updates, a pod from `podman kube play`
- [ ] Metrics: Prometheus on a monitoring VM, `node_exporter` on every host, `postgres_exporter` on db1 and db2
- [ ] Grafana: behind an nginx reverse proxy with TLS, dashboards for the hosts and PostgreSQL
- [ ] Alerts: Alertmanager rules for a down host, replication lag, disk space and backup age, with a runbook for each
- [ ] Logs: Grafana Alloy sends the journal and the PostgreSQL logs to Loki, searched in Grafana

## Phase 7: PostgreSQL performance
- [ ] Dataset and load: the Airlines demo database, `pgbench` with custom scripts for its queries
- [ ] Query tuning: the slowest queries from `pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)`, indexes, times before and after
- [ ] Maintenance: autovacuum settings, table bloat, locks, finding and ending a blocked query
- [ ] OS tuning: huge pages, overcommit, swappiness, dirty page writeback and the I/O scheduler, measured with `pgbench`
- [ ] Connection pooling: PgBouncer in transaction mode, many client connections, measured with `pgbench`

## Phase 8: PostgreSQL high availability
- [ ] Patroni cluster: etcd and Patroni on three new VMs from Terraform and Ansible, `patronictl` to read the state
- [ ] One address for the primary: HAProxy with Patroni health checks, a virtual IP from keepalived
- [ ] Switchover and failover under `pgbench` load: downtime and lost transactions measured
- [ ] Major upgrade: PostgreSQL 16 → 18 with `pg_upgrade`, a rollback plan, the downtime measured
- [ ] Restore checks: a Python job restores the latest backup every night, checks the data and reports to Prometheus
- [ ] Service levels: availability and latency objectives, an error budget panel in Grafana
- [ ] Game day: three planned failures under load, a written postmortem for each

## Phase 9: Kubernetes and GitOps
- [ ] k3s: a single-node cluster in a VM, pods, deployments and services with `kubectl`
- [ ] Storage and settings: PVCs on local storage, ConfigMaps, Secrets, a first Helm chart
- [ ] GitOps: Argo CD syncs the cluster's apps from this repo, every change through a commit
- [ ] CloudNativePG: the operator and a cluster of three instances, a failover test with the downtime measured
- [ ] CloudNativePG backups: base backups and WAL to MinIO object storage, a point-in-time restore
- [ ] CloudNativePG operations: monitoring with the Prometheus stack, a minor version upgrade
- [ ] Comparison: PostgreSQL on VMs and on Kubernetes, failover time, backups and daily work, written up in the docs

## Later
- Managed PostgreSQL in a public cloud (AWS RDS or Aurora), built with Terraform

## Learning resources
- RHEL/RHCSA: [Sander van Vugt (YouTube)](https://www.youtube.com/channel/UComgXoI6pysmetOzuNH_TDQ), [EX200 exam topics](https://www.redhat.com/en/services/training/ex200-red-hat-certified-system-administrator-rhcsa-exam)
- Databases: [CMU 15-445 Intro to Database Systems](https://www.youtube.com/playlist?list=PLSE8ODhjZXjYMAgsGH-GtY5rJYZ6zjsd5), [Hussein Nasser, PostgreSQL](https://www.youtube.com/playlist?list=PLQnljOFTspQWGrOqslniFlRcwxyY94cjj), [PostgreSQL 18 documentation](https://www.postgresql.org/docs/18/), [PostgreSQL 14 Internals (Egor Rogov, free)](https://postgrespro.com/community/books/internals)
- Backups and high availability: [pgBackRest User Guide for RHEL](https://pgbackrest.org/user-guide-rhel.html), [Patroni documentation](https://patroni.readthedocs.io/en/latest/)
- Reliability: *Database Reliability Engineering* (Laine Campbell, Charity Majors, O'Reilly), [Google SRE book (free)](https://sre.google/sre-book/table-of-contents/)
- Ansible: [Jeff Geerling, Ansible 101](https://www.youtube.com/playlist?list=PL2_OBreMn7FqZkvMYt6ATmgC0KAGGJNAN)
- Terraform: [libvirt provider](https://registry.terraform.io/providers/dmacvicar/libvirt/latest/docs)
- Kubernetes: [TechWorld with Nana](https://www.youtube.com/c/TechWorldwithNana), [CloudNativePG documentation](https://cloudnative-pg.io/documentation/current/)
