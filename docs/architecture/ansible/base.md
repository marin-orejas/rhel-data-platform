# Role base

The role `base` keeps the users, sudo, the shared `dba` directories, SSH, the firewall, SELinux, time sync, tuned and the journal the same on db1, db2 and k8s1–k8s3.

Checks: [18](../../../checks/18-base-role.sh), [24](../../../checks/24-fresh-clones.sh), [25](../../../checks/25-nodes.sh) · Files: [`ansible/roles/base/`](../../../ansible/roles/base/)

## Setup

| Part | Setup |
|---|---|
| Keeps | The `dba` group, the user `ansible` with its key and sudo rule, the shared `dba` directories, the firewall, SELinux, SSH, tuned and the journal ([System settings](../hosts/system.md)) |
| Users tasks | `tasks/users.yml`, also run alone by `playbooks/bootstrap.yml` on a fresh clone ([Ansible playbooks](playbooks.md#playbooks)) |
| Shared directories | `base_dba_dirs` in `inventory/host_vars/`: `/srv/dba` on db1 ([System settings, DBA group and shared directory](../hosts/system.md#dba-group-and-shared-directory)) |
| Time and packages | `chronyd`, `vim-enhanced`, `bash-completion` and `bash-color-prompt` for the admin shell, and `openssl` to read certificates |
| Login message | `/etc/motd.d/ansible` |
| tuned | Another profile in `tuned-adm active` is reported as changed, also in a dry run. Only then `tuned-adm profile` runs. |
| tuned profile | `base_tuned_profile`, `postgresql-guest` by default and `k8s-guest` in `inventory/group_vars/k8s.yml`. The profiles are in `files/tuned/`. |
| Firewall services | `base_firewall_extra_services` in `inventory/host_vars/` adds the services of one host: `nfs` and `https` on db2 |
| Firewall ports | `base_firewall_ports` in `inventory/group_vars/k8s.yml` for every node, and `base_firewall_extra_ports` in `inventory/group_vars/k8s_control.yml` and `inventory/group_vars/k8s_workers.yml` ([System settings, Firewall on the Kubernetes nodes](../hosts/system.md#firewall-on-the-kubernetes-nodes)) |
| Trusted sources | `base_firewall_trusted_sources` in `inventory/group_vars/k8s.yml`, for the zone `trusted` ([System settings, Firewall on the Kubernetes nodes](../hosts/system.md#firewall-on-the-kubernetes-nodes)) |

## Why

- The role keeps the public key in `files/ansible.pub` and writes the whole `authorized_keys`, so a key added by hand is removed on the next run.
- The sudo rule and the SSH drop-in are written with `validate` (`visudo -cf`, `sshd -t -f`), because a broken file would lock Ansible out of every host.
- The role reads its values from variables, and a host or a child group adds to a list through a second variable (`base_firewall_extra_services`, `base_firewall_extra_ports`), because a more specific group or `host_vars` replaces a list instead of merging it.
- The nodes run the whole role, the `dba` group and `tuned-profiles-postgresql` too, because the package holds only profile files and the role stays the same for both groups.

## Limits

- The role restarts journald with `Storage=persistent`, but `/var/log/journal` gets its group `systemd-journal` and its ACLs only at the next boot, from `systemd-tmpfiles`. A fresh build passes checks 05 and 18 only after its first reboot.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-10-30 | `ansible-playbook playbooks/base.yml` with `--check --diff`, then two runs | Dry run: `changed=1` (the login message) and no file changed. First run `changed=1`, second `changed=0` on db1 and db2. |
| 2026-10-30 | Role `base` with the users and sudo: `--check --diff`, then two runs | `changed=0` each time on db1 and db2: the role matches the setup by hand. |
| 2026-10-30 | Role `base` with the firewall, SELinux and SSH: `--check --diff`, a run, a second run, then a login with only a password | Firewall and SELinux `changed=0`. The SSH drop-in and reload `changed=2`, then `changed=0`. The password login is refused. |
| 2026-10-31 | Role `base` with chrony, tuned and the journal: `--check --diff`, a run and a second run | db1 `changed=0` each time. db2 `changed=5` (package, profile, switch to `postgresql-guest`, restart), then `changed=0`. `tuned-adm verify` passes on db2. |
| 2026-11-14 | `bootstrap.yml`, then the role `base` on k8s1–k8s3: `--check --diff`, a run and a second run | Bootstrap `changed=7` on each node. The second run `changed=0` on all three, and `tuned-adm verify` passes. |
