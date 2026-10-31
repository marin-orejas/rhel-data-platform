#!/usr/bin/env bash
# Lesson 18 checks: the settings of the Ansible role base work on db1 and db2.
# Check 17 shows that the hosts match the playbook files; this one reads what is live:
# the effective SSH settings, the runtime firewall, SELinux labels, time sync, tuned
# and the journal, with read-only commands sent through Ansible as root.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/18-base-role.sh
# Run it after a reboot of both hosts, a minute after they are up (time sync needs it).

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
profile=postgresql-guest
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# Services and ports as one sorted line, so the order firewalld prints them in does not matter.
sorted() {
    tr ' ' '\n' | sed '/^$/d' | sort | xargs
}

for h in $hosts; do
    services="cockpit dhcpv6-client ssh"
    [ "$h" = db2 ] && services="cockpit dhcpv6-client nfs ssh"

    # SSH: the effective settings, after all drop-ins
    sshd=$(on "$h" "sshd -T")
    check "$h: sshd refuses password logins" grep -qx "passwordauthentication no" <<< "$sshd"
    check "$h: sshd refuses keyboard-interactive logins" grep -qx "kbdinteractiveauthentication no" <<< "$sshd"
    check "$h: sshd refuses root logins" grep -qx "permitrootlogin no" <<< "$sshd"

    # Firewall: the runtime rules, which must have come back from the permanent ones
    check "$h: firewall allows $services" [ "$(on "$h" "firewall-cmd --list-services" | sorted)" = "$services" ]
    check "$h: firewall allows 5433/tcp" [ "$(on "$h" "firewall-cmd --list-ports" | sorted)" = "5433/tcp" ]

    # SELinux
    check "$h: SELinux is enforcing" [ "$(on "$h" getenforce)" = Enforcing ]
    check "$h: /pgdata has the type postgresql_db_t" grep -q ":postgresql_db_t:" <<< "$(on "$h" "stat -c %C /pgdata")"
    check "$h: TCP 5433 has the type postgresql_port_t" grep -Eq "^postgresql_port_t +tcp +.*\b5433\b" <<< "$(on "$h" "semanage port -l")"

    # Time sync
    check "$h: chronyd is enabled" [ "$(on "$h" "systemctl is-enabled chronyd")" = enabled ]
    check "$h: the clock is synchronized" [ "$(on "$h" "timedatectl show -p NTPSynchronized --value")" = yes ]

    # tuned
    check "$h: active tuned profile is $profile" [ "$(on "$h" "tuned-adm active")" = "Current active profile: $profile" ]
    check "$h: tuned-adm verify passes" grep -q "^Verification succeeded" <<< "$(on "$h" "tuned-adm verify")"

    # Journal: kept on disk, so earlier boots can be read
    storage=$(on "$h" "systemd-analyze cat-config systemd/journald.conf" | grep "^Storage=" | tail -n 1)
    check "$h: journald uses Storage=persistent" [ "$storage" = "Storage=persistent" ]
    check "$h: the journal holds more than one boot" [ "$(on "$h" "journalctl --list-boots --no-pager" | grep -Ec '^ *-?[0-9]+ ')" -gt 1 ]
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
