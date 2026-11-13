#!/usr/bin/env bash
# Lesson 24 checks: db1 and db2 built from fresh clones by playbooks/site.yml.
# Reads both hosts with read-only commands sent through Ansible as root: each clone has its
# own hostname, machine ID (the VM UUID) and SSH host key, the data VG is in the LVM devices
# file and was activated at this boot, the data file systems have the labels of the SELinux
# policy, the backup units restart after a failure, the shell extras are installed, and the
# nightly dumps on db1 run with the files of the role pgdump. Then a check run of
# playbooks/site.yml must change nothing.
# Check 17 covers the user ansible from the bootstrap, checks 08 and 09 /srv/dba and the
# dumps, and check 23 the stanza.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/24-fresh-clones.sh
# Run it after a reboot of both hosts.

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
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# A file on a host has the same SHA-256 as its source in the repo.
same_file() {
    [ "$(on "$1" "sha256sum $2" | cut -d' ' -f1)" = "$(sha256sum "$3" | cut -d' ' -f1)" ]
}

# The machine ID of a host is its VM UUID without dashes, in lower case.
machine_id_is_uuid() {
    local uuid
    uuid=$(on "$1" 'cat /sys/class/dmi/id/product_uuid')
    [ -n "$uuid" ] && [ "$(on "$1" 'cat /etc/machine-id')" = "$(tr -d - <<< "${uuid,,}")" ]
}

# Both hosts gave a fingerprint of their ED25519 host key, and the two differ.
own_host_keys() {
    [ "$(grep -c . <<< "$host_keys")" -eq 2 ] && [ "$(grep . <<< "$host_keys" | sort -u | wc -l)" -eq 2 ]
}

# The restart settings of a unit as systemd loaded them, one NAME=value per line, sorted.
restart_settings() {
    on "$1" "systemctl show -p Restart -p RestartUSec -p StartLimitBurst -p StartLimitIntervalUSec $2" | LC_ALL=C sort
}

for h in $hosts; do
    if [ "$h" = db1 ]; then
        mounts="/pgdata"
    else
        mounts="/srv/backup /pgdata"
    fi

    # The clone: its own name, machine ID and host key
    check "$h: the hostname is $h" [ "$(on "$h" 'hostname -s')" = "$h" ]
    check "$h: the machine ID is the VM UUID" machine_id_is_uuid "$h"
    host_keys+=$(on "$h" 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | cut -d' ' -f2)$'\n'

    # Role storage: the data VG in the LVM devices file, active from the boot
    check "$h: /dev/vdb1 is in the LVM devices file" grep -Eq 'DEVNAME=/dev/vdb1( |$)' <<< "$(on "$h" 'lvmdevices')"
    check "$h: VG data was activated at this boot" grep -q 'volume group "data" now active' <<< "$(on "$h" 'journalctl -b -u lvm-activate-data.service -o cat --no-pager')"

    # SELinux labels on the data file systems
    check "$h: /pgdata has the type postgresql_db_t" grep -q ':postgresql_db_t:' <<< "$(on "$h" 'stat -c %C /pgdata')"
    for dir in $mounts; do
        check "$h: every label under $dir matches the policy" [ -z "$(on "$h" "restorecon -Rnv $dir")" ]
    done

    # The retry in the backup units
    check "$h: pgbackrest@full.service restarts after a failure" [ "$(restart_settings "$h" pgbackrest@full.service)" = "$retry" ]
    if [ "$h" = db1 ]; then
        check "db1: pg-backup.service restarts after a failure" [ "$(restart_settings db1 pg-backup.service)" = "$retry" ]

        # Role pgdump: the nightly dumps from the files in the repo
        check "db1: /usr/local/bin/pg-backup.sh matches the role pgdump" same_file db1 /usr/local/bin/pg-backup.sh roles/pgdump/files/pg-backup.sh
        check "db1: /etc/systemd/system/pg-backup.timer matches the role pgdump" same_file db1 /etc/systemd/system/pg-backup.timer roles/pgdump/files/pg-backup.timer
        check "db1: the role wrote pg-backup.service" [ "$(on db1 'head -n 1 /etc/systemd/system/pg-backup.service')" = "# Ansible managed" ]
    fi

    # Role base: the shell extras
    for p in $extras; do
        check "$h: package $p is installed" grep -q "^$p-[0-9]" <<< "$(on "$h" "rpm -q $p")"
    done
done

check "db1 and db2 have their own SSH host keys" own_host_keys

# The hosts match the code: a check run of the whole build would change nothing
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
