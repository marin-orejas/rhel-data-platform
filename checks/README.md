# Check scripts

One script per lesson, numbered like the roadmap items. Each prints one `PASS` or `FAIL` line per check and exits with the number of failed checks. The checks read saved state, so they also pass after a reboot.

## Run

Run from the repo root on the desktop, without sudo. The column "Runs on" in the table below gives the form:

| Runs on | Command |
|---|---|
| db1 | `ssh db1 bash -s < checks/05-storage.sh` |
| db2 | `ssh db2 bash -s < checks/07-postgres-remote.sh` |
| db1, db2 | `for h in db1 db2; do echo "== $h"; ssh "$h" bash -s < checks/06-postgres.sh; done` |
| desktop | `bash checks/17-ansible.sh` |

- 17–26 and 31–34 log in through Ansible, so the key must be in the agent: `ssh-add ~/.ssh/id_ed25519_ansible`.
- 26–32 and 34 use `kubectl` through a tunnel to the API server, open in a second terminal: `ssh -N -L 6443:192.168.122.21:6443 nuc`.
- 33 and 34 also run curl on k8s2 over `ssh k8s2`, with the lab CA in `~/lab-ca.crt` there.
- After a reboot, run 18 a minute after the hosts are up (time sync), and 29 and 30 once CoreDNS is ready again (`kubectl rollout status deployment/coredns -n kube-system`).
- To see only the failures, add `| grep -Ev '^(PASS|$)'`.

## Checks

| Check | What it checks | Runs on |
|---|---|---|
| [05](05-storage.sh) | The persistent journal, the data disk and `/pgdata` | db1 |
| [06](06-postgres.sh) | The PostgreSQL 18 service, its data directory and SELinux labels | db1, db2 |
| [07](07-postgres-remote.sh) | A remote login from db2 to PostgreSQL on db1, port 5433 | db2 |
| [08](08-tuned-dba.sh) | The group `dba`, the tuned profile and `/srv/dba` | db1, db2 |
| [09](09-backup.sh) | The dump script, its timer and the newest dumps | db1 |
| [10](10-nfs.sh) | The NFS share on db2 and autofs on db1 | db1, db2 |
| [13](13-pitr.sh) | WAL archiving on db1 and the server after the restore to a set time | db1, db2 |
| [14](14-pgbackrest.sh) | pgBackRest, its timers and the last backups | db1, db2 |
| [15](15-replication.sh) | Streaming replication from db1 to db2 and its slot | db1, db2 |
| [16](16-failover.sh) | Data checksums, the role `rewind` and the client's connection string for a failover to db2 | db2 |
| [17](17-ansible.sh) | Ansible on the desktop and a dry run of `ansible/playbooks/base.yml` | desktop |
| [18](18-base-role.sh) | The settings of the role `base`: SSH, firewall, SELinux, time, tuned and the journal | desktop |
| [19](19-storage-postgresql.sh) | The data disks and PostgreSQL from the roles `storage` and `postgresql` | desktop |
| [20](20-postgresql-templates.sh) | `postgresql.conf` and `pg_hba.conf` from the templates of the role `postgresql` | desktop |
| [21](21-app-roles.sh) | The roles `app` and `report` and the database `app` | desktop |
| [22](22-tls.sh) | TLS with the lab CA on db1 and db2 and between them | desktop |
| [23](23-standby-backup-roles.sh) | The roles `pgbackrest`, `nfs` and `postgresql`, the standby and the restore test | desktop |
| [24](24-fresh-clones.sh) | db1 and db2 from fresh clones, and a dry run of `ansible/playbooks/site.yml` | desktop |
| [25](25-nodes.sh) | k8s1–k8s3 before kubeadm: no swap, CRI-O, the Kubernetes packages and the firewall | desktop |
| [26](26-cluster.sh) | The kubeadm cluster, Calico and the files of `kubernetes/nodes/` | desktop |
| [27](27-deployment.sh) | The Deployment `web` against `kubernetes/apps/web/` | desktop |
| [28](28-app-settings.sh) | The ConfigMap and the Secret of the app `web` | desktop |
| [29](29-in-cluster.sh) | The Service `web`, its DNS name and the network policies | desktop |
| [30](30-outside.sh) | MetalLB, Traefik and the page at `http://192.168.122.200/` | desktop |
| [31](31-storage.sh) | The data disks of the workers, TopoLVM, cert-manager and the StatefulSet `writer` | desktop |
| [32](32-cloudnativepg.sh) | The CloudNativePG operator, the Cluster `pg` with its primary and standby, and the record of the failover | desktop |
| [33](33-object-store.sh) | Garage and nginx on db2: the disk, the service, TLS, the bucket and its key, and a signed PUT, GET and DELETE from k8s2 | desktop |
| [34](34-backups.sh) | plugin-barman-cloud, WAL archiving and the backups of the Cluster `pg` to db2, and the table brought back by the restore to a set time | desktop |
