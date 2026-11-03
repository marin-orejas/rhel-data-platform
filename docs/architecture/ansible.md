# Ansible

Ansible runs on the desktop and manages db1 and db2 over SSH as the user `ansible`, with sudo. The playbook `base.yml` runs the role `base`, which keeps the users, sudo, SSH, the firewall, SELinux, time sync, tuned and the journal the same on both hosts. The playbook `storage.yml` runs the system role `storage`, which keeps the data disks as `host_vars` describes them. The playbook `postgresql.yml` runs the role `postgresql`, which keeps the PostgreSQL packages, the service drop-in, the profile of `postgres`, `postgresql.conf` and `pg_hba.conf`.

Verified by: [`checks/17-ansible.sh`](../../checks/17-ansible.sh), [`checks/18-base-role.sh`](../../checks/18-base-role.sh), [`checks/19-storage-postgresql.sh`](../../checks/19-storage-postgresql.sh) and [`checks/20-postgresql-templates.sh`](../../checks/20-postgresql-templates.sh) (desktop)

Repo files: [`ansible/ansible.cfg`](../../ansible/ansible.cfg), [`ansible/inventory/hosts.ini`](../../ansible/inventory/hosts.ini), [`ansible/playbooks/base.yml`](../../ansible/playbooks/base.yml), [`ansible/playbooks/storage.yml`](../../ansible/playbooks/storage.yml), [`ansible/playbooks/postgresql.yml`](../../ansible/playbooks/postgresql.yml), [`ansible/roles/base/`](../../ansible/roles/base/), [`ansible/roles/postgresql/`](../../ansible/roles/postgresql/)

## Setup

| Part | Setup |
|---|---|
| Control node | desktop, `ansible-core` 2.20.7 from the Fedora repos |
| Collections | `ansible.posix` 2.2.1 and `community.general` 12.6.0, Fedora packages `ansible-collection-*` |
| System roles | `fedora.linux_system_roles` 2.5.0, Fedora package `linux-system-roles`; on RHEL the same roles are `redhat.rhel_system_roles` |
| Config | `ansible/ansible.cfg`, read when Ansible runs from `ansible/`; roles from `ansible/roles/` |
| Inventory | group `db` with db1 and db2; Python `/usr/bin/python3` (3.12 on RHEL 10) |
| Connection | SSH, with the addresses and `ProxyJump nuc` from the desktop's `~/.ssh/config` |
| User on db1 and db2 | `ansible`, UID and GID 1500, no password, key login only |
| Key | `~/.ssh/id_ed25519_ansible` on the desktop, with a passphrase, loaded with `ssh-add` |
| sudo | `/etc/sudoers.d/ansible`: `ansible ALL=(ALL) NOPASSWD: ALL`, mode 440 |
| Become | off by default; `-b` for an ad hoc command, `become: true` in the playbook |
| Playbook | `playbooks/base.yml` on group `db`, runs the role `base` |
| Role `base` | the `dba` group, the user `ansible` with its key and sudo rule, the firewall, SELinux, SSH, tuned and the journal ([system](system.md)); `chronyd`, `vim-enhanced`, `/etc/motd.d/ansible` |
| tuned | another profile in `tuned-adm active` is reported as changed, also in a check run; only then `tuned-adm profile` runs |
| Playbook `storage.yml` | `fedora.linux_system_roles.storage` on group `db`, `storage_safe_mode: true`; the [data disks](vms.md#data-disks) as `storage_pools` in `inventory/host_vars/` |
| blivet | `python3-blivet` and the `libblockdev` plugins on db1 and db2; the role needs them also in a check run |
| Role `postgresql` | `playbooks/postgresql.yml` on group `db`: packages, the drop-in and `.bash_profile` ([PostgreSQL](postgresql.md)), `postgresql-setup --initdb` only without `PG_VERSION`, the service started but never restarted |
| `postgresql.conf`, `pg_hba.conf` | templates `postgresql.conf.j2` and `pg_hba.conf.j2`, values from the role defaults (`initdb`) and `group_vars/db.yml`; a change reloads PostgreSQL |
| Settings check | after the reload, the play stops on a line in `pg_file_settings` that is not applied, or a line in `pg_hba_file_rules` with an error |
| Variables | role defaults in each role's `defaults/`, values for both hosts in `inventory/group_vars/db.yml`, `nfs` in `inventory/host_vars/db2.yml` |

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
- The settings live only in the template, because a line in `postgresql.auto.conf` wins over it. The role leaves that file to `pg_basebackup -R` and `pg_rewind`; the settings check stops the play on a line there that overrides the template, and check 20 finds any other line.
- The role reloads PostgreSQL but never restarts it, because a restart cuts every connection and, with a standby, the order of the two hosts matters. A setting that needs a restart stops the play at the settings check.
- The `pg_hba.conf` lines are a list, not a map like the settings, because the first line that matches a connection decides.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-29 | `ansible all -m ping` and `ansible all -b -m command -a whoami` | `pong` and `root` on db1 and db2, no password asked |
| 2026-10-30 | `copy` of `/etc/motd.d/ansible`, run three times, the third after a hand edit on db2 | changed on both, then no change, then only db2 changed back |
| 2026-10-30 | `ansible-playbook playbooks/base.yml` with `--check --diff`, then run twice | check run: `changed=1` (the login message) and no file changed; first run `changed=1`, second `changed=0` on db1 and db2 |
| 2026-10-30 | Role `base` with the users and sudo, run with `--check --diff`, then twice | `changed=0` each time on db1 and db2: the role matches the setup by hand |
| 2026-10-30 | Role `base` with the firewall, SELinux and SSH: `--check --diff`, run, run again; then a login with only a password | firewall and SELinux `changed=0`; the SSH drop-in and reload `changed=2`, then `changed=0`; the password login is refused |
| 2026-10-31 | Role `base` with chrony, tuned and the journal: `--check --diff`, run, run again | db1 `changed=0` each time; db2 `changed=5` (package, profile, switch to `postgresql-guest`, restart), then `changed=0`; `tuned-adm verify` passes on db2 |
| 2026-10-31 | Role `storage` on the data disks built by hand: `--check --diff`, then a run | the check run changed no disk and no line in `/etc/fstab`; the run `changed=0` on db1 and db2 |
| 2026-10-31 | System role `postgresql` with `--check --diff` on db1 | `changed=2 failed=1`: it would run `postgresql-setup --initdb`, then failed on the missing `/var/lib/pgsql/data/postgresql.conf`; nothing changed on db1 |
| 2026-11-01 | Role `postgresql`: `--check --diff`, run, run again | db1 `changed=0` each time; db2 `changed=1` (contrib), then `changed=0`; `NRestarts=0` on both |
| 2026-11-02 | Template `postgresql.conf`: `--check --diff`, run, `ALTER SYSTEM RESET` of the five duplicates in `postgresql.auto.conf`, run again | dry run 889 lines to 24; the same values after the reset, now from `postgresql.conf`; `pgbackrest check` passes; second run `changed=0` on db1 and db2, no restart |
| 2026-11-02 | Template `pg_hba.conf`: `--check --diff`, run, run again | First run, with the list misnamed in `group_vars`: only the six `initdb` lines, new logins from db2 refused (the dry run showed it), the walreceiver kept streaming. After the fix: 12 lines on db1 and db2, checks 07, 15 and 16 pass, second run `changed=0` |
| 2026-11-03 | `log_line_prefix` and `max_connections = 150` through `group_vars`, and `ALTER SYSTEM SET max_connections = 150` by hand on db1 | The prefix applied after a reload, no restart. The hand change failed the dry run on db1. With 150 in `group_vars` the run stopped at the settings check on db1 and db2 (`pending_restart`); the next run put 100 back |
