# Ansible

Ansible runs on the desktop and manages db1 and db2 over SSH as the user `ansible`, with sudo. The playbook `base.yml` runs the role `base`, which keeps the users, sudo, SSH, the firewall, SELinux, time sync, tuned and the journal the same on both hosts.

Verified by: [`checks/17-ansible.sh`](../../checks/17-ansible.sh) and [`checks/18-base-role.sh`](../../checks/18-base-role.sh) (desktop)

Repo files: [`ansible/ansible.cfg`](../../ansible/ansible.cfg), [`ansible/inventory/hosts.ini`](../../ansible/inventory/hosts.ini), [`ansible/playbooks/base.yml`](../../ansible/playbooks/base.yml), [`ansible/roles/base/`](../../ansible/roles/base/)

## Setup

| Part | Setup |
|---|---|
| Control node | desktop, `ansible-core` 2.20.7 from the Fedora repos |
| Collections | `ansible.posix` 2.2.1 and `community.general` 12.6.0, Fedora packages `ansible-collection-*` |
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
| Variables | role defaults in `roles/base/defaults/`, values for both hosts in `inventory/group_vars/db.yml`, `nfs` in `inventory/host_vars/db2.yml` |

## Why

- A separate user, not mine: its key and its sudo rule have one job, and its actions show up under its own name in the logs.
- `NOPASSWD` sudo, because Ansible runs on several hosts at once and cannot type a password. The key has a passphrase, because it gives root on both hosts.
- The addresses stay in `~/.ssh/config`, so `ssh` and Ansible read them from one place.
- The same UID 1500 on both hosts, as with `postgres` (26), so files keep the same owner on every host.
- The role keeps the public key in `files/ansible.pub` and writes the whole `authorized_keys`, so a key added by hand is removed on the next run.
- The sudo rule and the SSH drop-in are written with `validate` (`visudo -cf`, `sshd -t -f`), because a broken file would lock Ansible out of both hosts.
- The role reads its values from variables, and a host adds to a list through its own variable (`base_firewall_extra_services`), because `host_vars` replaces a list from `group_vars` instead of merging it.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-29 | `ansible all -m ping` and `ansible all -b -m command -a whoami` | `pong` and `root` on db1 and db2, no password asked |
| 2026-10-30 | `copy` of `/etc/motd.d/ansible`, run three times, the third after a hand edit on db2 | changed on both, then no change, then only db2 changed back |
| 2026-10-30 | `ansible-playbook playbooks/base.yml` with `--check --diff`, then run twice | check run: `changed=1` (the login message) and no file changed; first run `changed=1`, second `changed=0` on db1 and db2 |
| 2026-10-30 | Role `base` with the users and sudo, run with `--check --diff`, then twice | `changed=0` each time on db1 and db2: the role matches the setup by hand |
| 2026-10-30 | Role `base` with the firewall, SELinux and SSH: `--check --diff`, run, run again; then a login with only a password | firewall and SELinux `changed=0`; the SSH drop-in and reload `changed=2`, then `changed=0`; the password login is refused |
| 2026-10-31 | Role `base` with chrony, tuned and the journal: `--check --diff`, run, run again | db1 `changed=0` each time; db2 `changed=5` (package, profile, switch to `postgresql-guest`, restart), then `changed=0`; `tuned-adm verify` passes on db2 |
