# PostgreSQL on db1

PostgreSQL 18 from AppStream runs only on db1 for now. It accepts local connections, and one role from db2 over the network on port 5433. db2 has only the client package, `postgresql18`.

Verified by: [`checks/06-postgres.sh`](../../checks/06-postgres.sh) (db1), [`checks/07-postgres-remote.sh`](../../checks/07-postgres-remote.sh) (db2)

## Setup

| Part | Setup |
|---|---|
| Package | `postgresql18-server`, and `postgresql18-contrib` for `pg_waldump`. RHEL 10 has no modules: each major version has its own package name, and only one version can be installed. |
| Service | `postgresql`, enabled. The vendor unit is not changed. A drop-in, `/etc/systemd/system/postgresql.service.d/override.conf`, sets `PGDATA=/pgdata/pgsql/data` and `RequiresMountsFor=/pgdata`, so the server does not start without the data disk. |
| Data directory | `/pgdata/pgsql/data`, created with `postgresql-setup --initdb` |
| Settings | `port = 5433` and `listen_addresses = '*'`, set with `ALTER SYSTEM`. They are in `postgresql.auto.conf`, and `postgresql.conf` stays as `initdb` made it. |
| SELinux | Local rules for `/pgdata` and port 5433, and the module `pg_archive_nfs`, see [SELinux](system.md#selinux). The server runs in the `postgresql_t` domain. |
| Firewall | `5433/tcp` in the `public` zone, see [Firewall](system.md#firewall) |
| Client authentication | `pg_hba.conf` keeps the default local rules and has one more line: `host postgres remote_test 192.168.122.12/32 scram-sha-256` |
| Roles | `remote_test`: login only, no other attributes. It tests remote access from db2. Its password is stored only in `~/.pgpass` on db2 (mode 600). |
| Logs | The logging collector, on by default in RHEL, writes the server log to `/pgdata/pgsql/data/log/postgresql-<day>.log`. The journal shows only the first lines of each start. |
| Admin access | `sudo -iu postgres psql`. The postgres user's `/var/lib/pgsql/.bash_profile` (a config file of the package) sets `PGDATA=/pgdata/pgsql/data` and `PGPORT=5433`. |
| Test data | Database `lab` with the table `items`, 10,000 rows |

## Layout

```
/pgdata                 root:root           mount point of LV data/pgdata
└─ pgsql                postgres:postgres   700
    └─ data             postgres:postgres   700   the cluster (PGDATA)
```

A connection from db2 must pass four checks on db1:

```
db2                                db1
psql + ~/.pgpass ── TCP 5433 ──►   firewalld     public zone allows 5433/tcp
                                   SELinux       port 5433 → postgresql_port_t
                                   postgres      listens on all addresses, port 5433
                                   pg_hba.conf   remote_test from 192.168.122.12, scram-sha-256
```

## Why

- The data directory is not the mount point itself, and its parent belongs to `postgres`, as the PostgreSQL docs recommend. If the disk is not mounted, `/pgdata/pgsql/data` does not exist, so nothing can create a cluster on the root disk by mistake. The `postgres`-owned parent leaves room for upgrades, which keep the old cluster next to the new one (`data-old`).
- The server listens on all addresses, not only on the IP of db1. The unit does not wait for the network, so at boot the IP may not exist yet, and the server would start on localhost only. See [ADR 0002](../decisions/0002-listen-on-all-addresses.md).
- Port 5433 instead of the default 5432, to practise moving a service to another port through every layer. The firewalld service `postgresql` is not used, because it opens 5432. See [ADR 0005](../decisions/0005-postgresql-on-port-5433.md).
