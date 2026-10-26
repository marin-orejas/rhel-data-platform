#!/usr/bin/env bash
# Lesson 14 checks: pgBackRest on db1, with its repository on the NFS share from db2.
# db1 checks the package, the config, the timers and the backup results in the journal;
# db2 checks the repository directory and, as remote_test like checks/07, the archive
# command of the server on db1. Run as the owner, no sudo needed:
#   for h in db1 db2; do echo "== $h"; ssh "$h" bash -s < checks/14-pgbackrest.sh; done
# Run it after a reboot of both hosts: the timers must come back on their own.
# The owner cannot read the repository itself (postgres, 750), so the backup results
# come from the journal of the backup units.

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

server=db1
port=5433
role=remote_test
conf=/etc/pgbackrest.conf
repofile=/etc/yum.repos.d/pgdg-common.repo
repo=/srv/backup/pgbackrest

# Give up on a connection after 5 seconds.
export PGCONNECT_TIMEOUT=5

# Run one query on db1 as remote_test, with the password from ~/.pgpass.
query() {
    psql -w -h "$server" -p "$port" -U "$role" -d postgres -Atc "$1" 2>/dev/null
}

# The result line of the newest backup run by a pgbackrest@ unit.
last_backup_ok() {
    journalctl -u 'pgbackrest@*' -o cat 2>/dev/null | grep 'backup command end' | tail -n 1 |
        grep -q 'completed successfully'
}

# A full backup by pgbackrest@full.service completed in the last 8 days.
recent_full() {
    journalctl -u pgbackrest@full.service --since -8d -o cat 2>/dev/null |
        grep -q 'backup command end: completed successfully'
}

if [ "$(hostname -s)" = db1 ]; then
    # Package and config
    check "package pgbackrest is installed" rpm -q --quiet pgbackrest
    check "$repofile lets dnf see only pgbackrest and pgdg-libssh2" grep -qx 'includepkgs=pgbackrest pgdg-libssh2' "$repofile"
    check "$conf puts the repository on the NFS share" grep -qx 'repo1-path=/mnt/db2/backup/pgbackrest' "$conf"
    check "$conf keeps two full backups" grep -qx 'repo1-retention-full=2' "$conf"

    # Timers
    for timer in pgbackrest-full.timer pgbackrest-diff.timer; do
        check "$timer is enabled" systemctl is-enabled --quiet "$timer"
        check "$timer is active" systemctl is-active --quiet "$timer"
    done

    # Backup results
    check "the last backup by a pgbackrest@ unit completed successfully" last_backup_ok
    check "a full backup by pgbackrest@full.service completed in the last 8 days" recent_full
fi

if [ "$(hostname -s)" = db2 ]; then
    # Repository directory
    check "$repo is postgres:postgres 750" [ "$(stat -c '%U:%G %a' "$repo" 2>/dev/null)" = "postgres:postgres 750" ]

    # Archiving on db1
    check "$role logs in to $server:$port" [ "$(query 'SELECT current_user')" = "$role" ]
    check "archive_command is pgbackrest archive-push" [ "$(query "SELECT current_setting('archive_command')")" = "pgbackrest --stanza=main archive-push %p" ]
    check "the last archived WAL is on the current timeline" [ "$(query 'SELECT left(last_archived_wal, 8) = left(pg_walfile_name(pg_current_wal_lsn()), 8) FROM pg_stat_archiver')" = t ]
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
