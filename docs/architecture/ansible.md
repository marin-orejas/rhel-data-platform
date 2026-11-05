# Ansible

Ansible runs on the desktop and manages db1 and db2 over SSH as the user `ansible`, with sudo. The playbook `base.yml` runs the role `base`, which keeps the users, sudo, SSH, the firewall, SELinux, time sync, tuned and the journal the same on both hosts. The playbook `storage.yml` runs the system role `storage`, which keeps the data disks as `host_vars` describes them. The playbook `postgresql.yml` runs the role `postgresql`, which keeps the PostgreSQL packages, the service drop-in, the profile of `postgres`, the TLS files, `postgresql.conf` and `pg_hba.conf`, and on the primary the login roles and the app databases.

Verified by: [`checks/17-ansible.sh`](../../checks/17-ansible.sh), [`checks/18-base-role.sh`](../../checks/18-base-role.sh), [`checks/19-storage-postgresql.sh`](../../checks/19-storage-postgresql.sh), [`checks/20-postgresql-templates.sh`](../../checks/20-postgresql-templates.sh) and [`checks/21-app-roles.sh`](../../checks/21-app-roles.sh) (desktop)

Repo files: [`ansible/ansible.cfg`](../../ansible/ansible.cfg), [`ansible/inventory/hosts.ini`](../../ansible/inventory/hosts.ini), [`ansible/playbooks/base.yml`](../../ansible/playbooks/base.yml), [`ansible/playbooks/storage.yml`](../../ansible/playbooks/storage.yml), [`ansible/playbooks/postgresql.yml`](../../ansible/playbooks/postgresql.yml), [`ansible/roles/base/`](../../ansible/roles/base/), [`ansible/roles/postgresql/`](../../ansible/roles/postgresql/)

## Setup

| Part | Setup |
|---|---|
| Control node | desktop, `ansible-core` 2.20.7 from the Fedora repos |
| Collections | `ansible.posix` 2.2.1, `community.general` 12.6.0 and `community.postgresql` 3.0.0, Fedora packages `ansible-collection-*` |
| System roles | `fedora.linux_system_roles` 2.5.0, Fedora package `linux-system-roles`. On RHEL the same roles are `redhat.rhel_system_roles`. |
| Config | `ansible/ansible.cfg`, read when Ansible runs from `ansible/`, with the roles from `ansible/roles/` |
| Inventory | Group `db` with db1 and db2. Python `/usr/bin/python3` (3.12 on RHEL 10). |
| Connection | SSH, with the addresses and `ProxyJump nuc` from the desktop's `~/.ssh/config` |
| User on db1 and db2 | `ansible`, UID and GID 1500, no password, key login only |
| Key | `~/.ssh/id_ed25519_ansible` on the desktop, with a passphrase, loaded with `ssh-add` |
| sudo | `/etc/sudoers.d/ansible`: `ansible ALL=(ALL) NOPASSWD: ALL`, mode 440 |
| Become | Off by default. `-b` for an ad hoc command, `become: true` in the playbook. |
| Playbook | `playbooks/base.yml` on group `db`, runs the role `base` |
| Role `base` | The `dba` group, the user `ansible` with its key and sudo rule, the firewall, SELinux, SSH, tuned and the journal ([system](system.md)). Also `chronyd`, `vim-enhanced` and `/etc/motd.d/ansible`. |
| tuned | Another profile in `tuned-adm active` is reported as changed, also in a check run. Only then `tuned-adm profile` runs. |
| Playbook `storage.yml` | `fedora.linux_system_roles.storage` on group `db`, with `storage_safe_mode: true`. The [data disks](vms.md#data-disks) are `storage_pools` in `inventory/host_vars/`. |
| blivet | `python3-blivet` and the `libblockdev` plugins on db1 and db2. The role needs them also in a check run. |
| Role `postgresql` | `playbooks/postgresql.yml` on group `db`: packages, the drop-in and `.bash_profile` ([PostgreSQL](postgresql.md)), `postgresql-setup --initdb` only without `PG_VERSION`, the service started but never restarted |
| TLS files | `roles/postgresql/tasks/tls.yml`, before the `postgresql.conf` template: the server certificate and key in `postgresql_tls_dir`, and `root.crt` for the users in `postgresql_tls_client_users` ([PostgreSQL, TLS](postgresql.md#tls)). A change reloads PostgreSQL. |
| Certificates | Not secret, so plain text in the inventory: the CA as `postgresql_tls_ca_cert` in `inventory/group_vars/db.yml`, each server certificate as `postgresql_tls_cert` in its file in `inventory/host_vars/` |
| Vault | Each server key is a Vault string from `ansible-vault encrypt_string`, as `postgresql_tls_key` in `inventory/host_vars/`. The Vault password is in `~/.lab-secrets/ansible-vault-pass` (600) on the desktop, named by `vault_password_file` in `ansible.cfg`. |
| Key task | `no_log: true` and `diff: false`, so neither `--diff` nor an error prints the key |
| `postgresql.conf`, `pg_hba.conf` | Templates `postgresql.conf.j2` and `pg_hba.conf.j2`, with values from the role defaults (`initdb`) and `inventory/group_vars/db.yml`. A change reloads PostgreSQL. |
| Settings check | after the reload, the play stops on a line in `pg_file_settings` that is not applied, or a line in `pg_hba_file_rules` with an error |
| TLS check | After the settings check, `openssl s_client -starttls postgres` to `127.0.0.1:5433` must verify the server's certificate against the CA, for the host's own name. Skipped in a check run. |
| psycopg2 | `python3-psycopg2` on db1 and db2, for the `community.postgresql` modules. They need it also in a check run. |
| Roles and app databases | `roles/postgresql/tasks/databases.yml`, as `postgres`, only on the host where `pg_is_in_recovery()` is `f`. The standby gets them through replication. |
| Login roles | The names in `postgresql_login_roles`, with `LOGIN`. The role sets no password and leaves an existing one. |
| App databases | Each item of `postgresql_app_databases` names the database, its schema, the owner and the readers, set up as in [Database app](postgresql.md#database-app). |
| Privileges | The role adds what the variables list and never removes other grants. Only `PUBLIC` loses its database privileges, and only when `pg_database` still shows some, so a second run stays `changed=0`. |
| Variables | role defaults in each role's `defaults/`, values for both hosts in `inventory/group_vars/db.yml`. Per host in `inventory/host_vars/`: the data disks, the server certificate and key, and `nfs` on db2. |

## Why

- A separate user, not mine: its key and its sudo rule have one job, and its actions show up under its own name in the logs.
- `NOPASSWD` sudo, because Ansible runs on several hosts at once and cannot type a password. The key has a passphrase, because it gives root on both hosts.
- The addresses stay in `~/.ssh/config`, so `ssh` and Ansible read them from one place.
- The same UID 1500 on both hosts, as with `postgres` (26), so files keep the same owner on every host.
- The role keeps the public key in `files/ansible.pub` and writes the whole `authorized_keys`, so a key added by hand is removed on the next run.
- The sudo rule and the SSH drop-in are written with `validate` (`visudo -cf`, `sshd -t -f`), because a broken file would lock Ansible out of both hosts.
- The role reads its values from variables, and a host adds to a list through its own variable (`base_firewall_extra_services`), because `host_vars` replaces a list from `group_vars` instead of merging it.
- The data disks use the system role `storage` with safe mode on, so a wrong description fails instead of formatting a volume with data. The layout is in `host_vars`, because db1 and db2 have different volumes.
- An own role `postgresql`, because the system role keeps its data directory at `/var/lib/pgsql/data` in an internal variable. The role stops when `/pgdata` is not mounted, so `initdb` never creates a cluster on the root disk.
- The settings live only in the template, because a line in `postgresql.auto.conf` wins over it. The role leaves that file to `pg_basebackup -R` and `pg_rewind`. The settings check stops the play on a line there that overrides the template, and check 20 finds any other line.
- The role reloads PostgreSQL but never restarts it, because a restart cuts every connection and, with a standby, the order of the two hosts matters. A setting that needs a restart stops the play at the settings check.
- The `pg_hba.conf` lines are a list, not a map like the settings, because the first line that matches a connection decides.
- The server keys are in the repo only as Vault strings, and the Vault password is outside the repo, so the repo alone gives no key. Only the key is encrypted, not the whole file, so the rest of `host_vars` stays readable in `git diff`.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-29 | `ansible all -m ping` and `ansible all -b -m command -a whoami` | `pong` and `root` on db1 and db2, no password asked |
| 2026-10-30 | `copy` of `/etc/motd.d/ansible`, run three times, the third after a hand edit on db2 | changed on both, then no change, then only db2 changed back |
| 2026-10-30 | `ansible-playbook playbooks/base.yml` with `--check --diff`, then run twice | Check run: `changed=1` (the login message) and no file changed. First run `changed=1`, second `changed=0` on db1 and db2. |
| 2026-10-30 | Role `base` with the users and sudo, run with `--check --diff`, then twice | `changed=0` each time on db1 and db2: the role matches the setup by hand |
| 2026-10-30 | Role `base` with the firewall, SELinux and SSH: `--check --diff`, run, run again, then a login with only a password | Firewall and SELinux `changed=0`. The SSH drop-in and reload `changed=2`, then `changed=0`. The password login is refused. |
| 2026-10-31 | Role `base` with chrony, tuned and the journal: `--check --diff`, run, run again | db1 `changed=0` each time. db2 `changed=5` (package, profile, switch to `postgresql-guest`, restart), then `changed=0`. `tuned-adm verify` passes on db2. |
| 2026-10-31 | Role `storage` on the data disks built by hand: `--check --diff`, then a run | The check run changed no disk and no line in `/etc/fstab`. The run reported `changed=0` on db1 and db2. |
| 2026-10-31 | System role `postgresql` with `--check --diff` on db1 | `changed=2 failed=1`: it would run `postgresql-setup --initdb`, then failed on the missing `/var/lib/pgsql/data/postgresql.conf`. Nothing changed on db1. |
| 2026-11-01 | Role `postgresql`: `--check --diff`, run, run again | db1 `changed=0` each time. db2 `changed=1` (contrib), then `changed=0`. `NRestarts=0` on both. |
| 2026-11-02 | Template `postgresql.conf`: `--check --diff`, run, `ALTER SYSTEM RESET` of the five duplicates in `postgresql.auto.conf`, run again | Dry run: 889 lines to 24. The same values after the reset, now from `postgresql.conf`. `pgbackrest check` passes. Second run `changed=0` on db1 and db2, no restart. |
| 2026-11-02 | Template `pg_hba.conf`: `--check --diff`, run, run again | First run, with the list misnamed in `group_vars`: only the six `initdb` lines, new logins from db2 refused (the dry run showed it), the walreceiver kept streaming. After the fix: 12 lines on db1 and db2, checks 07, 15 and 16 pass, second run `changed=0` |
| 2026-11-03 | `log_line_prefix` and `max_connections = 150` through `group_vars`, and `ALTER SYSTEM SET max_connections = 150` by hand on db1 | The prefix applied after a reload, no restart. The hand change failed the dry run on db1. With 150 in `group_vars` the run stopped at the settings check on db1 and db2 (`pending_restart`). The next run put 100 back. |
| 2026-11-04 | Role `postgresql` with the roles and the database `app` built by hand on db1: `--check --diff` | db1 `ok=22 changed=0`, db2 `ok=15 changed=0 skipped=8`: the role matches the setup by hand, and db2 skips the block as a standby. |
| 2026-11-04 | `REVOKE USAGE ON SCHEMA app FROM report` by hand on db1, then `--check --diff`, run, run again | `report` on db2 got `permission denied for schema app`. The dry run and the run showed `changed=1` on the schema task, then `report` read the table again. Second run `changed=0`. |
| 2026-11-05 | Role `postgresql` with TLS, over the TLS files made by hand on db1: `--check --diff`, a run, a run again | Dry run: db1 `changed=5` (`root.crt`, the order of the `ssl` lines, `hostssl`), db2 `changed=7`, the key with no content shown. The run did the same, the TLS check passed on both, and the walreceiver kept streaming. Second run `changed=0`, checks 20 and 21 pass. |
