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

script=/usr/local/bin/pg-backup.sh
dir=/mnt/db2/backup/pgsql
unit=pg-backup

newest() {
    ls -t "$dir"/$1 2>/dev/null | head -n 1
}

recent() {
    local f
    f=$(newest "$1")
    [ -n "$f" ] && [ -n "$(find "$f" -mtime -2)" ]
}

check "$script is root:root, mode 755" [ "$(stat -c '%U:%G %a' "$script" 2>/dev/null)" = "root:root 755" ]
check "$script has the SELinux type bin_t" grep -q ':bin_t:' <<<"$(stat -c '%C' "$script" 2>/dev/null)"
check "package bzip2 is installed" rpm -q --quiet bzip2

check "$unit.service runs as postgres" [ "$(systemctl show -p User --value "$unit.service")" = postgres ]
check "$unit.timer is enabled" systemctl is-enabled --quiet "$unit.timer"
check "$unit.timer is active" systemctl is-active --quiet "$unit.timer"
check "$unit.timer runs every day at 02:00" grep -q 'OnCalendar=\*-\*-\* 02:00:00' <<<"$(systemctl show -p TimersCalendar --value "$unit.timer")"
check "$unit.timer is persistent" [ "$(systemctl show -p Persistent --value "$unit.timer")" = yes ]

check "$dir is postgres:dba, mode 2750" [ "$(stat -c '%U:%G %a' "$dir" 2>/dev/null)" = "postgres:dba 2750" ]
check "a dump of lab from the last 2 days" recent 'lab-*.sql.gz'
check "a dump of the roles from the last 2 days" recent 'globals-*.sql.gz'
check "a config archive from the last 2 days" recent 'config-*.tar.bz2'
check "the newest dump of lab is postgres:dba, mode 640" [ "$(stat -c '%U:%G %a' "$(newest 'lab-*.sql.gz')" 2>/dev/null)" = "postgres:dba 640" ]
check "the newest dump of lab is a valid gzip file" gzip -t "$(newest 'lab-*.sql.gz')" 2>/dev/null

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
