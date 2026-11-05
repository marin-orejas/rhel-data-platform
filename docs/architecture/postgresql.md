# PostgreSQL on db1 and db2

PostgreSQL 18 runs on db1 as the primary and on db2 as a read-only standby that streams WAL from db1. Clients connect to db1 on port 5433, and every login from another host uses TLS with a certificate from the lab CA.

Verified by: [`checks/06-postgres.sh`](../../checks/06-postgres.sh) (db1 and db2), [`checks/07-postgres-remote.sh`](../../checks/07-postgres-remote.sh) (db2), [`checks/15-replication.sh`](../../checks/15-replication.sh) (db1 and db2), [`checks/16-failover.sh`](../../checks/16-failover.sh) (db2)

Repo files: [`scripts/failover-client.sh`](../../scripts/failover-client.sh), [`ansible/roles/postgresql/`](../../ansible/roles/postgresql/)

## Setup

### Both hosts

| Part | Setup |
|---|---|
| Package | `postgresql18-server` and `postgresql18-contrib` (for `pg_waldump`) from AppStream, `openssl` for the role's TLS check |
| Managed by | the Ansible role `postgresql` ([Ansible](ansible.md)): packages, drop-in, `.bash_profile`, the TLS files, `postgresql.conf`, `pg_hba.conf`, the service |
| Service | `postgresql`, enabled. Drop-in `postgresql.service.d/override.conf` with `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`. |
| Settings | `postgresql.conf` from the role's template, with `port = 5433`, `listen_addresses = '*'`, `log_line_prefix`, the archive settings and the TLS settings from `ansible/inventory/group_vars/db.yml` |
| `pg_hba.conf` | from the role's template, the same on both hosts: the `initdb` lines, then `hostssl` lines with `scram-sha-256` for `remote_test` from db2 to `postgres` and `lab`, for `replicator` and `rewind` from db1 and db2, and for `app` and `report` from db2 to `app` |
| SELinux, firewall | Rules for `/pgdata` and port 5433, `5433/tcp` open, see [System settings](system.md) |
| Logs | `/pgdata/pgsql/data/log/postgresql-<day>.log`, each line with the time, the PID and `user@database` |
| Admin access | `sudo -iu postgres psql`, with `PGDATA` and `PGPORT=5433` from `/var/lib/pgsql/.bash_profile` |

### TLS

| Part | Setup |
|---|---|
| CA | `CN=rhel-lab CA`, EC P-256, valid to 2036-11-01. Its key has a passphrase and stays on the desktop, outside the repo. |
| Server certificates | Signed by the CA, EC P-256, for server use only (`serverAuth`). db1: `CN=db1` with `DNS:db1` and `IP:192.168.122.11`, valid to 2029-02-06. db2: `CN=db2` with `DNS:db2` and `IP:192.168.122.12`, valid to 2029-02-07. |
| Files | `/pgdata/pgsql/tls/server.crt` (644) and `server.key` (600), owner `postgres`. The keys have no passphrase, so the server starts on its own. |
| Settings | `ssl = on`, with `ssl_cert_file` and `ssl_key_file` pointing to those files |
| Clients | `~/.postgresql/root.crt` with the CA certificate, for `postgres` and `makilele` on both hosts. libpq reads it by default. |
| Managed by | The Ansible role `postgresql` ([Ansible](ansible.md)), with the keys from Ansible Vault |

### db1

| Part | Setup |
|---|---|
| Roles | `remote_test` (login, `SELECT` and `INSERT` on `lab.failover_test`), `replicator` (`LOGIN REPLICATION`), `rewind` (login, `EXECUTE` on the four file functions `pg_rewind` needs). Passwords only in `.pgpass` files, mode 600. |
| Test data | Database `lab` with the tables `items` (10,000 rows) and `failover_test`, written by the failover client |

### Database `app`

| Part | Setup |
|---|---|
| Database | `app`, owner `postgres`, on db1 and through replication on db2. `CONNECT` only for `app` and `report`, none for `PUBLIC`. |
| `app` | Login role, owner of the schema `app`, where it creates its tables |
| `report` | Login role with `USAGE` on the schema `app`. Default privileges give it `SELECT` on every table `app` creates there. |
| Logins | From db2 only, to `app` only. Passwords in `.pgpass`, mode 600. |
| Managed by | The Ansible role `postgresql` ([Ansible](ansible.md)), on the primary only: the roles, the database, the schema and the privileges. The passwords are set by hand. |

### Replication

| Part | Setup |
|---|---|
| Type | Physical streaming, asynchronous |
| Standby | db2, built with `pg_basebackup -R`, see [Build a standby](../runbooks/build-a-standby.md). It answers read-only queries. |
| Connection | `primary_conninfo` on db2: `host=192.168.122.11 port=5433 user=replicator sslmode=verify-full`, the password from `passfile`. db1 has the same with `host=192.168.122.12`, used after a failover. |
| Slot | Physical slot `db2` on db1, capped with `max_slot_wal_keep_size = 1GB` |
| Archiving | db2 has the same `archive_mode = on` and archive command from the role. A standby does not archive, and as a primary db2 fails with exit code 127, because pgBackRest is only on db1. |
| `.pgpass` of `postgres` | On both hosts, with the `replicator` and `rewind` passwords for the other host |
| `pg_rewind` | Possible because data checksums are on, the PostgreSQL 18 default |
| Client | `scripts/failover-client.sh`, run by hand on db2. It names both servers with `target_session_attrs=read-write`, so libpq picks the one that accepts writes. |

## Layout

```
/pgdata                 root:root           mount point of LV data/pgdata
└─ pgsql                postgres:postgres   700
    ├─ data             postgres:postgres   700   the cluster (PGDATA)
    └─ tls              postgres:postgres   700   server.crt 644, server.key 600
```

A connection from db2 must pass four checks on db1:

```
db2                                db1
psql + ~/.pgpass ── TCP 5433 ──►   firewalld     public zone allows 5433/tcp
                                   SELinux       port 5433 → postgresql_port_t
                                   postgres      listens on all addresses, port 5433, TLS
                                   pg_hba.conf   hostssl, remote_test from 192.168.122.12, scram-sha-256
```

## Why

- The cluster is one level below the mount point. If the disk is not mounted, `/pgdata/pgsql/data` does not exist, so no cluster gets created on the root disk by mistake.
- The server [listens on all addresses](../decisions/listen-on-all-addresses.md), because the unit does not wait for the network.
- [Port 5433](../decisions/postgresql-on-port-5433.md), to practise moving a service through SELinux, the firewall and the clients.
- db2 has the same data directory, drop-in, SELinux rules, port and `pg_hba.conf` as db1, so the two can swap roles in a failover.
- [Asynchronous, with a slot capped at 1 GB](../decisions/asynchronous-replication-with-a-capped-slot.md): a long db2 outage costs a rebuild of db2, not a full `/pgdata` on db1.
- `sslmode=verify-full` for replication, because `prefer` encrypts but does not check who answers. A host that poses as db1 could ask for the `replicator` password in clear text.

## Tested

Lag is read in bytes on db1, from `pg_stat_replication`.

| Date | Test | Result |
|---|---|---|
| 2026-10-27 | `pg_basebackup` from db1 to db2 | 52,552 kB in 0.8 s |
| 2026-10-27 | Lag with nothing written | 0 bytes, but `now() - pg_last_xact_replay_timestamp()` on db2 showed 26 min: the time since the last commit, not lag |
| 2026-10-27 | Lag during one `INSERT` of 1,000,000 rows on db1 (2.8 s) | Up to 17.9 MB not replayed, `replay_lag` up to 0.33 s, 0 again within 0.5 s |
| 2026-10-27 | db2 stopped while db1 wrote 300,000 rows | The slot kept 47 MB of WAL, and db2 caught up after its start |
| 2026-10-27 | A read on db2 right after its start | Showed the old data for a moment: a hot standby answers before it has caught up |
| 2026-10-27 | A write on db2 | `cannot execute CREATE TABLE in a read-only transaction` |
| 2026-10-29 | Failover: PostgreSQL on db1 killed with `kill -9`, db2 promoted by hand ([runbook](../runbooks/fail-over-to-db2.md)) | Writes stopped for 5 min 51 s, the promotion itself about 1 s. None of the 631 rows db1 confirmed was lost. |
| 2026-10-29 | `pg_rewind` of db1 after the failover | Diverged at `0/340628B8` on timeline 3. Copied 181 MB of 340 MB, then db1 streamed from db2 on timeline 4. |
| 2026-10-29 | Planned switchover back: db2 stopped cleanly, db1 promoted | No `pg_rewind`, db2 followed on timeline 5. Writes stopped for about 6 min, by hand with a pause. The promotion took about 1 s. |
| 2026-11-04 | From db2, `report` reads the table `orders`, which `app` created after the default privileges | `SELECT` works with no `GRANT` on the table. `INSERT` fails with `permission denied for table orders`, a login to `lab` with `no pg_hba.conf entry`. |
| 2026-11-05 | From db2, `report` logs in to `app` on db1 with `sslmode=disable`, with `verify-full`, and with `verify-full` to the name db2 at db1's address | `no pg_hba.conf entry … no encryption`. With `verify-full`, `ssl` is `t` with TLSv1.3. To the wrong name, `server certificate for "db1" (and 1 other name) does not match host name "db2"`. |
| 2026-11-05 | From db1, `replicator` and `rewind` log in to db2 with `verify-full`. Then with the `host` of db2 and the `hostaddr` of db1, with `verify-full` and with `prefer`. | `IDENTIFY_SYSTEM` answers on timeline 5, and `rewind` gets TLSv1.3. With the `hostaddr` of db1, `verify-full` stops before the password with `does not match host name "192.168.122.12"`. `prefer` logs in to db1 with no error, and after a refused login it tries again with no encryption. |
