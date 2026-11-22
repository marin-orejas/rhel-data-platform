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

storage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep '^Storage=' | tail -n 1)
boots=$(journalctl --list-boots --no-pager 2>/dev/null | grep -cE '^ *-?[0-9]+ [0-9a-f]{32} ')
check "journald uses Storage=persistent" [ "$storage" = "Storage=persistent" ]
check "/var/log/journal has the group systemd-journal" [ "$(stat -c %G /var/log/journal 2>/dev/null)" = "systemd-journal" ]
check "the journal keeps more than one boot" [ "$boots" -gt 1 ]

check "/dev/vdb is 10 GiB" [ "$(lsblk -bdno SIZE /dev/vdb 2>/dev/null)" = "10737418240" ]
check "/dev/vdb has a GPT partition table" [ "$(lsblk -dno PTTYPE /dev/vdb 2>/dev/null)" = "gpt" ]
check "/dev/vdb1 has the type Linux LVM" [ "$(lsblk -dno PARTTYPENAME /dev/vdb1 2>/dev/null)" = "Linux LVM" ]

on_vdb1=$(lsblk -nro NAME /dev/vdb1 2>/dev/null)
check "/dev/vdb1 is an LVM physical volume" [ "$(lsblk -dno FSTYPE /dev/vdb1 2>/dev/null)" = "LVM2_member" ]
check "LV data/pgdata is on /dev/vdb1" grep -qx data-pgdata <<<"$on_vdb1"
check "LV data/pgdata is 7 GiB" [ "$(lsblk -bdno SIZE /dev/data/pgdata 2>/dev/null)" = "7516192768" ]

uuid=$(lsblk -dno UUID /dev/data/pgdata 2>/dev/null)
check "LV data/pgdata has an XFS file system" [ "$(lsblk -dno FSTYPE /dev/data/pgdata 2>/dev/null)" = "xfs" ]
check "/etc/fstab mounts it on /pgdata by UUID" grep -Eq "^UUID=$uuid[[:space:]]+/pgdata[[:space:]]+xfs[[:space:]]" /etc/fstab
check "/pgdata is mounted from data/pgdata" [ "$(findmnt -no SOURCE /pgdata 2>/dev/null)" = "/dev/mapper/data-pgdata" ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
