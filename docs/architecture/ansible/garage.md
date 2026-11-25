# Role garage

The role `garage` keeps the object store on db2. `playbooks/garage.yml` runs it right after the data disks.

Checks: [33](../../../checks/33-object-store.sh) · Files: [`ansible/roles/garage/`](../../../ansible/roles/garage/), [`ansible/playbooks/garage.yml`](../../../ansible/playbooks/garage.yml)

## Setup

| Part | Setup |
|---|---|
| Keeps | Garage with its layout, bucket and key, and nginx with TLS in front of it ([Object store](../backups/object-store.md#setup)) |
| User | `garage` with the UID and GID from `garage_uid` |
| Binary | `get_url` of `garage_version`, checked against `garage_sha256` in `roles/garage/defaults/main.yml` |
| Secrets | `garage_rpc_secret` and `garage_admin_token` from the vault in `inventory/host_vars/db2.yml`, written with `no_log` and `diff: false` |
| Config and unit | `garage.toml` and `garage.service` in `roles/garage/files/`, copies of the files on db2 |
| Restart | A change of the binary, a secret, the config or the unit restarts Garage. |
| Start | Garage enabled and started, then `wait_for` its RPC port before the cluster tasks |
| Cluster tasks | As `garage` (`become_user`). The reads of the node ID, the status, the bucket and the key also run in a dry run (`check_mode: false`). |
| Layout | `layout assign` and `layout apply --version 1`, only while `garage status` shows `NO ROLE ASSIGNED` |
| Bucket | `bucket create`, only when `bucket info` fails |
| Key | `key import` of `garage_s3_key_id` and `garage_s3_secret_key` from the vault, only when `key info` fails |
| Grant | `bucket allow --read --write`, only after a new bucket or a new key |
| TLS | `garage_tls_cert` and `garage_tls_key` from `inventory/host_vars/db2.yml`, the key from the vault with `no_log`. `garage.conf` from `roles/garage/files/`. |
| Reload | A change of the certificate, the key or the site reloads nginx. |
| SELinux | `httpd_can_network_connect` on and persistent, by `ansible.posix.seboolean` |

## Why

- The config, the unit and the nginx site are plain copies in `files/`, not templates, because the role runs only on db2. A dry run then compares the role with what runs.
- A lost key comes back by `key import` with the same ID and secret, because a new key would give every S3 client a new secret.
- The UID and GID are fixed at 1501, like `ansible` at 1500, so a rebuilt db2 with the kept `vdc` still owns the files on `/srv/garage`.

## Limits

- The tasks that build an empty Garage (`layout assign` and `apply`, `bucket create`, `key import`, `bucket allow`) have not run yet, because everything existed on db2. Their flags come from the v2.5.0 source, so a fresh db2 is their first test.
- Garage publishes no checksum, so `garage_sha256` is the hash of the binary downloaded on 2026-11-24. A new version needs its hash taken by hand.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-24 | `site.yml` over Garage and nginx set up by hand on db2: `--check --diff --limit db2`, then a run | Dry run and run `changed=1`, both the fstab line of `/srv/garage` from the system role `storage` (`LABEL=garage` to `UUID=`). The play `Object store on db2` changed nothing. |
