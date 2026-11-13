#!/usr/bin/env bash
# Lesson 23 checks: the roles pgbackrest, nfs and postgresql on db1 and db2, and the restore test.
# Reads both hosts with read-only commands sent through Ansible as root: every file the
# roles copy from their files/ is the same as in the repo, the role wrote /etc/pgbackrest.conf
# with the repository of each host, postgres reads the stanza main on both hosts, the backup
# timers run on db1 only, and the SELinux module for the WAL archive is loaded on db1. The
# .pgpass of postgres holds the logins to the other host, only the standby has standby.signal,
# and the primary has replicator and one slot, named for the standby. The restore test left
# no copy and no server on db2, and no new timeline in the archive.
# Since lesson 24 the archive starts on timeline 5 with no history file, so the newest
# timeline also comes from the WAL directories.
# Checks 10, 14 and 15 cover the share, the backups of db1 and the replication.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/23-standby-backup-roles.sh
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
pgbackrest_files="/etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL /etc/yum.repos.d/pgdg-common.repo
    /etc/systemd/system/pgbackrest@.service /etc/systemd/system/pgbackrest-full.timer
    /etc/systemd/system/pgbackrest-diff.timer"
primary_tl=
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# Run one query as postgres over the local socket.
query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -XAtc \"$2\""
}

# A file on a host has the same SHA-256 as its source in the repo.
same_file() {
    [ "$(on "$1" "sha256sum $2" | cut -d' ' -f1)" = "$(sha256sum "$3" | cut -d' ' -f1)" ]
}

# A directory on a host lists the first name and not the second, so a lost connection never passes.
lists() {
    local names
    names=$(on "$1" "ls -A $2")
    grep -qxF "$3" <<< "$names" && ! grep -qxF "$4" <<< "$names"
}

# enabled or disabled, then active or inactive
unit_state() {
    echo "$(on "$1" "systemctl show -p UnitFileState --value $2") $(on "$1" "systemctl show -p ActiveState --value $2")"
}

# The newest timeline in the archive on db2, as a number: the first 8 hex digits of the history
# files and the WAL directories (one per timeline and log file). The WAL directory of the
# primary's timeline is always there, so a lost connection never passes.
newest_archive_tl() {
    local tl
    tl=$(on db2 'find /srv/backup/pgbackrest/archive/main -mindepth 2 -maxdepth 2' |
        sed 's|.*/||' | grep -oE '^[0-9A-F]{8}' | sort | tail -n 1)
    [ -n "$tl" ] && echo $((16#$tl))
}

for h in $hosts; do
    if [ "$h" = db1 ]; then
        other=db2 other_ip=192.168.122.12 repo=/mnt/db2/backup/pgbackrest timers="enabled active"
    else
        other=db1 other_ip=192.168.122.11 repo=/srv/backup/pgbackrest timers="disabled inactive"
    fi

    # Role pgbackrest: the package, the files from the repo, the config and the timers
    check "$h: package pgbackrest is installed" grep -q '^pgbackrest-[0-9]' <<< "$(on "$h" 'rpm -q pgbackrest')"
    for dest in $pgbackrest_files; do
        check "$h: $dest matches the role pgbackrest" same_file "$h" "$dest" "roles/pgbackrest/files/$(basename "$dest")"
    done
    conf=$(on "$h" 'cat /etc/pgbackrest.conf')
    check "$h: the role wrote /etc/pgbackrest.conf" [ "$(head -n 1 <<< "$conf")" = "# Ansible managed" ]
    check "$h: /etc/pgbackrest.conf puts the repository in $repo" grep -qx "repo1-path=$repo" <<< "$conf"
    check "$h: postgres reads the stanza main in $repo" grep -q 'status: ok' <<< "$(on "$h" 'runuser -u postgres -- pgbackrest --stanza=main info')"
    for timer in pgbackrest-full.timer pgbackrest-diff.timer; do
        check "$h: $timer is $timers" [ "$(unit_state "$h" "$timer")" = "$timers" ]
    done

    # Role nfs: the module that lets db1 archive WAL to the share
    if [ "$h" = db1 ]; then
        check "db1: /usr/local/share/selinux/pg_archive_nfs.te matches the role nfs" same_file db1 /usr/local/share/selinux/pg_archive_nfs.te roles/nfs/files/pg_archive_nfs.te
        check "db1: SELinux module pg_archive_nfs is loaded" grep -qx pg_archive_nfs <<< "$(on db1 'semodule -l')"
    fi

    # Role postgresql: the logins to the other host, and the primary or the standby
    check "$h: .pgpass of postgres is 600 postgres:postgres" [ "$(on "$h" "stat -c '%a %U:%G' /var/lib/pgsql/.pgpass")" = "600 postgres:postgres" ]
    check "$h: .pgpass of postgres has replicator and rewind for $other_ip" [ "$(on "$h" 'cut -d: -f1-4 /var/lib/pgsql/.pgpass')" = "$other_ip:5433:replication:replicator"$'\n'"$other_ip:5433:postgres:rewind" ]
    if [ "$(query "$h" 'SELECT pg_is_in_recovery()')" = f ]; then
        primary_tl=$(query "$h" 'SELECT timeline_id FROM pg_control_checkpoint()')
        check "$h: the primary has no standby.signal" lists "$h" /pgdata/pgsql/data PG_VERSION standby.signal
        check "$h: replicator may log in and replicate, and is no superuser" [ "$(query "$h" "SELECT rolcanlogin, rolreplication, rolsuper FROM pg_roles WHERE rolname = 'replicator'")" = "t|t|f" ]
        check "$h: the only slot is $other" [ "$(query "$h" "SELECT string_agg(slot_name, ' ') FROM pg_replication_slots")" = "$other" ]
    else
        check "$h: the standby has standby.signal" lists "$h" /pgdata/pgsql/data standby.signal recovery.signal
    fi
done

# The restore test on db2 left no copy, no server and no new timeline in the archive
check "db2: no restore test copy is left in /pgdata/pgsql" lists db2 /pgdata/pgsql data restore-test
check "db2: no server listens on port 5434" lists db2 /run/postgresql .s.PGSQL.5433 .s.PGSQL.5434
check "the newest timeline in the archive is the timeline of the primary" [ "$(newest_archive_tl)" = "$primary_tl" ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
