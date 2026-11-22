#!/usr/bin/env bash

failed=0

check() {
    local name=$1
    shift
    if "$@"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        failed=$((failed + 1))
    fi
}

profile=postgresql-guest
export_dir=/srv/backup
master=/mnt/db2
share=/mnt/db2/backup
unit=pg-backup.service

share_mounts() {
    ls "$share/pgsql" >/dev/null 2>&1 &&
        [ "$(findmnt -no FSTYPE "$share" 2>/dev/null)" = nfs4 ] &&
        [ "$(findmnt -no SOURCE "$share" 2>/dev/null)" = "db2:$export_dir" ]
}

check "postgres has UID 26" [ "$(id -u postgres 2>/dev/null)" = 26 ]
check "group dba has GID 2000" [ "$(getent group dba | cut -d: -f3)" = 2000 ]
check "package nfs-utils is installed" rpm -q --quiet nfs-utils

if [ "$(hostname -s)" = db2 ]; then
    check "active profile is $profile" [ "$(tuned-adm active)" = "Current active profile: $profile" ]
    check "$profile is based on postgresql" grep -qx 'include=postgresql' "/etc/tuned/profiles/$profile/tuned.conf"
    check "tuned-adm verify passes" grep -q '^Verification succeeded' <<<"$(tuned-adm verify 2>&1)"

    on_vdb1=$(lsblk -nro NAME /dev/vdb1 2>/dev/null)
    uuid=$(lsblk -dno UUID /dev/data/backup 2>/dev/null)
    check "/dev/vdb is 10 GiB" [ "$(lsblk -bdno SIZE /dev/vdb 2>/dev/null)" = "10737418240" ]
    check "/dev/vdb has a GPT partition table" [ "$(lsblk -dno PTTYPE /dev/vdb 2>/dev/null)" = "gpt" ]
    check "/dev/vdb1 is an LVM physical volume" [ "$(lsblk -dno FSTYPE /dev/vdb1 2>/dev/null)" = "LVM2_member" ]
    check "LV data/backup is on /dev/vdb1" grep -qx data-backup <<<"$on_vdb1"
    check "LV data/backup is 3 GiB" [ "$(lsblk -bdno SIZE /dev/data/backup 2>/dev/null)" = "3221225472" ]
    check "LV data/backup has an XFS file system" [ "$(lsblk -dno FSTYPE /dev/data/backup 2>/dev/null)" = "xfs" ]
    check "/etc/fstab mounts it on $export_dir by UUID" grep -Eq "^UUID=$uuid[[:space:]]+$export_dir[[:space:]]+xfs[[:space:]]" /etc/fstab
    check "$export_dir is mounted from data/backup" [ "$(findmnt -no SOURCE "$export_dir" 2>/dev/null)" = "/dev/mapper/data-backup" ]
    check "$export_dir has the SELinux type var_t" grep -q ':var_t:' <<<"$(stat -c %C "$export_dir" 2>/dev/null)"
    check "$export_dir/pgsql is postgres:dba, mode 2750" [ "$(stat -c '%U:%G %a' "$export_dir/pgsql" 2>/dev/null)" = "postgres:dba 2750" ]

    check "nfs-server is enabled" systemctl is-enabled --quiet nfs-server
    check "nfs-server is running" systemctl is-active --quiet nfs-server
    check "$export_dir is exported to db1 only, read-write" grep -Eqx "$export_dir[[:space:]]+192\.168\.122\.11\(rw\)" /etc/exports.d/backup.exports
    check "SELinux allows NFS to share files read-write" [ "$(getsebool nfs_export_all_rw)" = "nfs_export_all_rw --> on" ]
fi

if [ "$(hostname -s)" = db1 ]; then
    check "package autofs is installed" rpm -q --quiet autofs
    check "autofs is enabled" systemctl is-enabled --quiet autofs
    check "autofs is running" systemctl is-active --quiet autofs
    check "the master map points $master to /etc/auto.db2" grep -Eqx "$master[[:space:]]+/etc/auto\.db2" /etc/auto.master.d/db2.autofs
    check "the map mounts backup from db2:$export_dir with rw,sync" grep -Eqx "backup[[:space:]]+-rw,sync[[:space:]]+db2:$export_dir" /etc/auto.db2
    check "$master is an autofs mount point" [ "$(findmnt -no FSTYPE "$master" 2>/dev/null)" = autofs ]
    check "$share mounts db2:$export_dir over NFSv4 when opened" share_mounts

    check "$unit writes to $share/pgsql" grep -q "pg-backup.sh $share/pgsql " <<<"$(systemctl show -p ExecStart --value "$unit")"
    check "$unit wants autofs" grep -qw autofs.service <<<"$(systemctl show -p Wants --value "$unit")"
    check "$unit starts after autofs" grep -qw autofs.service <<<"$(systemctl show -p After --value "$unit")"
    check "no backups left on the root disk of db1" [ ! -e /srv/backup ]
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
