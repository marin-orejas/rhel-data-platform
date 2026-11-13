# Role postgresql

The role `postgresql` keeps PostgreSQL on db1 and db2: the packages, the service, the TLS files, the config files, and on the primary the roles and the app databases. On an empty data disk of db2 it copies db1 instead of running `initdb`.

Checks: [19](../../../checks/19-storage-postgresql.sh), [20](../../../checks/20-postgresql-templates.sh), [21](../../../checks/21-app-roles.sh), [22](../../../checks/22-tls.sh), [23](../../../checks/23-standby-backup-roles.sh) · Files: [`ansible/roles/postgresql/`](../../../ansible/roles/postgresql/)

## Setup

### Packages and service

| Part | Setup |
|---|---|
| Server | The packages, the drop-in, `.bash_profile` and the service of the [PostgreSQL server](../postgresql/server.md#setup) |
| `python3-psycopg2` | On db1 and db2, for the `community.postgresql` modules, also in a dry run |
| `acl` | In the role's package list. Ansible needs `setfacl` to become `postgres` from the user `ansible`. |
| Mount guard | The role stops when `/pgdata` is not mounted, so `initdb` never runs on the root disk. |
| `initdb` | `postgresql-setup --initdb`, only without `PG_VERSION` and only where `postgresql_build_standby` is false |
| Reload | A change of the TLS files or a config file reloads PostgreSQL. The role never restarts it. |

### Standby copy

| Part | Setup |
|---|---|
| Where | Where `postgresql_build_standby` is true (db2) and `PG_VERSION` is missing |
| Peer | `postgresql_peer_address` in each host's file in `inventory/host_vars/` |
| Passwords | `replicator` and `rewind` as Vault strings in `inventory/group_vars/db.yml` |
| `.pgpass` of `postgres` | `replicator` and `rewind` for `postgresql_peer_address`, written before the copy with `no_log: true` and `diff: false` |
| Copy | `pg_basebackup` as `replicator` from `postgresql_peer_address`, with `sslmode=verify-full` and the slot named after the host |
| After the copy | `postgresql.auto.conf` with `primary_slot_name` and `primary_conninfo`, and an empty `standby.signal`. Only right after the copy, never on a running standby. |

### TLS files

| Part | Setup |
|---|---|
| Tasks | `roles/postgresql/tasks/tls.yml`, before `initdb` and the copy (the copy checks the certificate of db1) |
| Files | The server certificate and key in `postgresql_tls_dir`, and `root.crt` for the users in `postgresql_tls_client_users` ([PostgreSQL TLS](../postgresql/tls.md)) |
| Certificates | Not secret, so plain text in the inventory: the CA as `postgresql_tls_ca_cert` in `inventory/group_vars/db.yml`, each server certificate as `postgresql_tls_cert` in `inventory/host_vars/` |
| Keys | Vault strings from `ansible-vault encrypt_string`, as `postgresql_tls_key` in `inventory/host_vars/` |
| Key task | `no_log: true` and `diff: false`, so neither `--diff` nor an error prints the key. |

### Config files

| Part | Setup |
|---|---|
| Templates | `postgresql.conf.j2` and `pg_hba.conf.j2`, with values from the role defaults (`initdb`) and `inventory/group_vars/db.yml` |
| Settings check | After the reload, the play stops on a line in `pg_file_settings` that is not applied, or a line in `pg_hba_file_rules` with an error. |
| TLS check | After the settings check, `openssl s_client -starttls postgres` to `127.0.0.1:5433` must verify the certificate against the CA, for the host's own name. Skipped in a dry run. |

### Roles and databases

| Part | Setup |
|---|---|
| Tasks | `roles/postgresql/tasks/databases.yml`, as `postgres`, only where `pg_is_in_recovery()` is `f`. The standby gets them through replication. |
| Login roles | The names in `postgresql_login_roles`, with `LOGIN`. The role sets no password and leaves an existing one. |
| Replication | `replicator` with `REPLICATION LOGIN` and no password from the role, and a physical slot for each other host of group `db`, named after it |
| App databases | Each item of `postgresql_app_databases` names the database, its schema, the owner and the readers, set up as in [PostgreSQL roles and databases](../postgresql/databases.md). |
| Privileges | The role adds what the variables list and never removes other grants. Only `PUBLIC` loses its database privileges, and only when `pg_database` still shows some, so a second run stays `changed=0`. |

## Why

- A role of its own, because the system role `postgresql` keeps its data directory at `/var/lib/pgsql/data` in an internal variable.
- The settings live only in the template, because a line in `postgresql.auto.conf` wins over it. The role writes that file only right after a new standby copy, and without `pg_basebackup -R`, which would append to the `primary_` lines of db1 in the copy.
- The role reloads PostgreSQL but never restarts it, because a restart cuts every connection and, with a standby, the order of the two hosts matters. A setting that needs a restart stops the play at the settings check.
- The `pg_hba.conf` lines are a list, not a map like the settings, because the first line that matches a connection decides.
- The server keys are in the repo only as Vault strings, and the Vault password is outside the repo, so the repo alone gives no key. Only the key is encrypted, not the whole file, so the rest of `host_vars` stays readable in `git diff`.

## Limits

- In a build of both fresh clones, an empty `/pgdata` on db2 fails at the copy with `Connection refused`, because the role starts PostgreSQL on db1 later in the same play. A second run with `--limit db2` makes the copy ([Rebuild the db hosts from fresh clones](../../runbooks/rebuild-the-db-hosts-from-fresh-clones.md)).
- The copy needs `replicator` and the slot on db1, which `databases.yml` makes later in the run, and the role sets no passwords. A build on two empty data disks fails, so the data disk of db1 must keep its cluster.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-31 | System role `postgresql` with `--check --diff` on db1 | `changed=2 failed=1`: it would run `postgresql-setup --initdb`, then failed on the missing `/var/lib/pgsql/data/postgresql.conf`. Nothing changed on db1. |
| 2026-11-01 | Role `postgresql`: `--check --diff`, a run and a second run | db1 `changed=0` each time. db2 `changed=1` (contrib), then `changed=0`. `NRestarts=0` on both. |
| 2026-11-02 | Template `postgresql.conf`: `--check --diff`, a run, `ALTER SYSTEM RESET` of the five duplicates in `postgresql.auto.conf`, a second run | Dry run: 889 lines to 24. The same values after the reset, now from `postgresql.conf`. `pgbackrest check` passes. Second run `changed=0` on db1 and db2, no restart. |
| 2026-11-02 | Template `pg_hba.conf`: `--check --diff`, a run and a second run | First run, with the list misnamed in `group_vars`: only the six `initdb` lines, new logins from db2 refused (the dry run showed it), the walreceiver kept streaming. After the fix: 12 lines on db1 and db2, checks 07, 15 and 16 pass, second run `changed=0`. |
| 2026-11-03 | `log_line_prefix` and `max_connections = 150` through `group_vars`, and `ALTER SYSTEM SET max_connections = 150` by hand on db1 | The prefix applied after a reload, no restart. The hand change failed the dry run on db1. With 150 in `group_vars` the run stopped at the settings check on db1 and db2 (`pending_restart`). The next run put 100 back. |
| 2026-11-04 | Role `postgresql` with the roles and the database `app` built by hand on db1: `--check --diff` | db1 `ok=22 changed=0`, db2 `ok=15 changed=0 skipped=8`: the role matches the setup by hand, and db2 skips the block as a standby. |
| 2026-11-04 | `REVOKE USAGE ON SCHEMA app FROM report` by hand on db1, then `--check --diff`, a run and a second run | `report` on db2 got `permission denied for schema app`. The dry run and the run showed `changed=1` on the schema task, then `report` read the table again. Second run `changed=0`. |
| 2026-11-05 | Role `postgresql` with TLS, over the TLS files made by hand on db1: `--check --diff`, a run and a second run | Dry run: db1 `changed=5` (`root.crt`, the order of the `ssl` lines, `hostssl`), db2 `changed=7`, the key with no content shown. The run did the same, the TLS check passed on both, and the walreceiver kept streaming. Second run `changed=0`, checks 20 and 21 pass. |
