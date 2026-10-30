# Ansible

Ansible runs on the desktop and manages db1 and db2 over SSH as the user `ansible`, with sudo. The first playbook keeps vim, chronyd and the login message the same on both hosts.

Verified by: [`checks/17-ansible.sh`](../../checks/17-ansible.sh) (desktop)

Repo files: [`ansible/ansible.cfg`](../../ansible/ansible.cfg), [`ansible/inventory/hosts.ini`](../../ansible/inventory/hosts.ini), [`ansible/playbooks/base.yml`](../../ansible/playbooks/base.yml)

## Setup

| Part | Setup |
|---|---|
| Control node | desktop, `ansible-core` 2.20.7 from the Fedora repos, no extra collections |
| Config | `ansible/ansible.cfg`, read when Ansible runs from `ansible/` |
| Inventory | group `db` with db1 and db2; Python `/usr/bin/python3` (3.12 on RHEL 10) |
| Connection | SSH, with the addresses and `ProxyJump nuc` from the desktop's `~/.ssh/config` |
| User on db1 and db2 | `ansible`, UID and GID 1500, no password, key login only |
| Key | `~/.ssh/id_ed25519_ansible` on the desktop, with a passphrase, loaded with `ssh-add` |
| sudo | `/etc/sudoers.d/ansible`: `ansible ALL=(ALL) NOPASSWD: ALL`, mode 440 |
| Become | off by default; `-b` for an ad hoc command, `become: true` in the playbook |
| Playbook | `playbooks/base.yml` on group `db`: `vim-enhanced` installed, `chronyd` enabled and started, `/etc/motd.d/ansible` |

## Why

- A separate user, not mine: its key and its sudo rule have one job, and its actions show up under its own name in the logs.
- `NOPASSWD` sudo, because Ansible runs on several hosts at once and cannot type a password. The key has a passphrase, because it gives root on both hosts.
- The addresses stay in `~/.ssh/config`, so `ssh` and Ansible read them from one place.
- The same UID 1500 on both hosts, as with `postgres` (26), so files keep the same owner on every host.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-29 | `ansible all -m ping` and `ansible all -b -m command -a whoami` | `pong` and `root` on db1 and db2, no password asked |
| 2026-10-30 | `copy` of `/etc/motd.d/ansible`, run three times, the third after a hand edit on db2 | changed on both, then no change, then only db2 changed back |
| 2026-10-30 | `ansible-playbook playbooks/base.yml` with `--check --diff`, then run twice | check run: `changed=1` (the login message) and no file changed; first run `changed=1`, second `changed=0` on db1 and db2 |
