# Build an SELinux module from denials

## When to use

When SELinux blocks a confined service and no boolean allows what it needs. Example: the archiver of PostgreSQL (`postgresql_t`) may not write files labeled `nfs_t`. The module is `selinux/pg_archive_nfs.te`, described in [System settings, SELinux](../architecture/system.md#selinux).

## Before you start

- The source of the module is in the repo, so a new version starts from that file. Its `module` line has the version, raised for every change (`module pg_archive_nfs 1.1;`).
- `audit2allow` sees only the actions that really ran. Run the whole job in permissive mode, on the same state as in production. On an empty repository the directories do not exist yet, so the first run missed `getattr` on them.

## Steps

1. **db1**: put only the domain of the service in permissive mode. The rest of the system stays enforcing.

   ```bash
   sudo semanage permissive -a postgresql_t
   ```

2. **db1**: run the job that was blocked, such as an archive run with `pgbackrest --stanza=main check`, then let `audit2allow` write the rules from the denials.

   ```bash
   sudo ausearch -m AVC -ts recent | audit2allow -m pg_archive_nfs
   ```

3. **db1**: compare the rules with the `.te` file in the repo, add only what the service needs, and raise the version. Then take the domain out of permissive mode.

   ```bash
   sudo semanage permissive -d postgresql_t
   ```

4. **db1**: build the module from its source and load it.

   ```bash
   checkmodule -M -m -o pg_archive_nfs.mod pg_archive_nfs.te
   semodule_package -o pg_archive_nfs.pp -m pg_archive_nfs.mod
   sudo semodule -i pg_archive_nfs.pp
   ```

## Check

- `sudo semodule -l | grep pg_archive_nfs` lists the module.
- The job works in enforcing mode: `pgbackrest --stanza=main check` passes, and `ausearch -m AVC -ts recent` shows no new denials.

## Undo

`sudo semodule -d pg_archive_nfs` disables the module, and `sudo semodule -e pg_archive_nfs` enables it again. With the module disabled, archiving fails, and the segments wait in `pg_wal`.

Last tested: 2026-10-26 on db1, version 1.1 for pgBackRest, archiving works in enforcing mode
