#!/usr/bin/env bash
# Lesson 08 checks: the dba group on db1 and db2, the tuned profile and the
# shared directory /srv/dba on db1. Run as the owner, no sudo needed:
#   for h in db1 db2; do echo "== $h"; ssh "$h" bash -s < checks/08-tuned-dba.sh; done
# Run it after a reboot of db1: the tuned profile must come back on its own.

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

group=dba
gid=2000
member=makilele
profile=postgresql-guest
dir=/srv/dba

# Create a file with the current umask and check what it gets.
# setgid gives it the group, the default ACL gives the group rw.
new_file_ok() {
    local f="$dir/.check-$$" got
    touch "$f" 2>/dev/null || return 1
    got=$(stat -c '%G %a' "$f")
    rm -f "$f"
    [ "$got" = "$group 660" ]
}

# Both hosts: the group
check "group $group has GID $gid" [ "$(getent group "$group" | cut -d: -f3)" = "$gid" ]
check "$member is a member of $group" grep -qw "$group" <<<"$(id -nG "$member")"

if [ "$(hostname -s)" = db1 ]; then
    # tuned
    check "tuned is enabled" systemctl is-enabled --quiet tuned
    check "tuned is running" systemctl is-active --quiet tuned
    check "active profile is $profile" [ "$(tuned-adm active)" = "Current active profile: $profile" ]
    check "$profile is based on postgresql" grep -qx 'include=postgresql' "/etc/tuned/profiles/$profile/tuned.conf"
    check "tuned-adm verify passes" grep -q '^Verification succeeded' <<<"$(tuned-adm verify 2>&1)"
    check "vm.swappiness is 3" [ "$(sysctl -n vm.swappiness)" = 3 ]
    check "transparent huge pages are off" grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled

    # Shared directory
    check "$dir is root:$group, mode 2770" [ "$(stat -c '%U:%G %a' "$dir" 2>/dev/null)" = "root:$group 2770" ]
    check "$dir has the default ACL for $group" grep -qx "default:group:$group:rwx" <<<"$(getfacl -p "$dir" 2>/dev/null)"
    check "a new file in $dir gets group $group, mode 660 (umask $(umask))" new_file_ok
    check "no files without an owner in $dir" [ -z "$(find "$dir" -nouser 2>/dev/null)" ]
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
