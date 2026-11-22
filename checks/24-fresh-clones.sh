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

hosts="db1 db2"
extras="vim-enhanced bash-completion bash-color-prompt"
retry=$'Restart=on-failure\nRestartUSec=1min\nStartLimitBurst=3\nStartLimitIntervalUSec=10min'
host_keys=
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

same_file() {
    [ "$(on "$1" "sha256sum $2" | cut -d' ' -f1)" = "$(sha256sum "$3" | cut -d' ' -f1)" ]
}

machine_id_is_uuid() {
    local uuid
    uuid=$(on "$1" 'cat /sys/class/dmi/id/product_uuid')
    [ -n "$uuid" ] && [ "$(on "$1" 'cat /etc/machine-id')" = "$(tr -d - <<< "${uuid,,}")" ]
}

own_host_keys() {
    [ "$(grep -c . <<< "$host_keys")" -eq 2 ] && [ "$(grep . <<< "$host_keys" | sort -u | wc -l)" -eq 2 ]
}

restart_settings() {
    on "$1" "systemctl show -p Restart -p RestartUSec -p StartLimitBurst -p StartLimitIntervalUSec $2" | LC_ALL=C sort
}

for h in $hosts; do
    if [ "$h" = db1 ]; then
        mounts="/pgdata"
    else
        mounts="/srv/backup /pgdata"
    fi

    check "$h: the hostname is $h" [ "$(on "$h" 'hostname -s')" = "$h" ]
    check "$h: the machine ID is the VM UUID" machine_id_is_uuid "$h"
    host_keys+=$(on "$h" 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | cut -d' ' -f2)$'\n'

    check "$h: /dev/vdb1 is in the LVM devices file" grep -Eq 'DEVNAME=/dev/vdb1( |$)' <<< "$(on "$h" 'lvmdevices')"
    check "$h: VG data was activated at this boot" grep -q 'volume group "data" now active' <<< "$(on "$h" 'journalctl -b -u lvm-activate-data.service -o cat --no-pager')"

    check "$h: /pgdata has the type postgresql_db_t" grep -q ':postgresql_db_t:' <<< "$(on "$h" 'stat -c %C /pgdata')"
    for dir in $mounts; do
        check "$h: every label under $dir matches the policy" [ -z "$(on "$h" "restorecon -Rnv $dir")" ]
    done

    check "$h: pgbackrest@full.service restarts after a failure" [ "$(restart_settings "$h" pgbackrest@full.service)" = "$retry" ]
    if [ "$h" = db1 ]; then
        check "db1: pg-backup.service restarts after a failure" [ "$(restart_settings db1 pg-backup.service)" = "$retry" ]

        check "db1: /usr/local/bin/pg-backup.sh matches the role pgdump" same_file db1 /usr/local/bin/pg-backup.sh roles/pgdump/files/pg-backup.sh
        check "db1: /etc/systemd/system/pg-backup.timer matches the role pgdump" same_file db1 /etc/systemd/system/pg-backup.timer roles/pgdump/files/pg-backup.timer
        check "db1: the role wrote pg-backup.service" [ "$(on db1 'head -n 1 /etc/systemd/system/pg-backup.service')" = "# Ansible managed" ]
    fi

    for p in $extras; do
        check "$h: package $p is installed" grep -q "^$p-[0-9]" <<< "$(on "$h" "rpm -q $p")"
    done
done

check "db1 and db2 have their own SSH host keys" own_host_keys

recap=$(ansible-playbook playbooks/site.yml --check "${opts[@]}" 2>/dev/null)
for h in $hosts; do
    check "$h matches playbooks/site.yml (changed=0)" grep -Eq "^$h +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " <<< "$recap"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
