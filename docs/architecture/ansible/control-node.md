# Ansible control node

Ansible runs on the desktop and manages db1 and db2 over SSH as the user `ansible`, with sudo. The secrets in the repo are Ansible Vault strings.

Checks: [17](../../../checks/17-ansible.sh) · Files: [`ansible/ansible.cfg`](../../../ansible/ansible.cfg), [`ansible/inventory/hosts.ini`](../../../ansible/inventory/hosts.ini)

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
| `sudo` rule | `/etc/sudoers.d/ansible`: `ansible ALL=(ALL) NOPASSWD: ALL`, mode 440 |
| Become | Off by default. `-b` for an ad hoc command, `become: true` in the playbook. |
| Vault password | `~/.lab-secrets/ansible-vault-pass` (600) on the desktop, named by `vault_password_file` in `ansible.cfg` |
| Variables | Role defaults in each role's `defaults/`, values for both hosts in `inventory/group_vars/db.yml`, values per host in `inventory/host_vars/` |

## Why

- A separate user, not the admin user `makilele`: its key and its sudo rule have one job, and its actions show up under its own name in the logs.
- `NOPASSWD` sudo, because Ansible runs on several hosts at once and cannot type a password. The key has a passphrase, because it gives root on both hosts.
- The addresses stay in `~/.ssh/config`, so `ssh` and Ansible read them from one place.
- The same UID 1500 on both hosts, as with `postgres` (26), so files keep the same owner on every host.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-29 | `ansible all -m ping` and `ansible all -b -m command -a whoami` | `pong` and `root` on db1 and db2, no password asked |
| 2026-10-30 | `copy` of `/etc/motd.d/ansible`, run three times, the third after a hand edit on db2 | Changed on both, then no change, then only db2 changed back. |
