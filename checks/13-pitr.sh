#!/usr/bin/env bash
# Lesson 13 checks: the WAL archive by hand on db2 and the state after the point-in-time restore.
# Since lesson 14, pgBackRest archives the WAL (checks/14-pgbackrest.sh). The archive by hand
# keeps what it had before the switch, so its checks stay.
# db1 checks the archiver and the archive on the NFS share; db2 checks the server
# on db1 over the network as remote_test, like checks/07. Run as the owner, no sudo needed:
#   for h in db1 db2; do echo "== $h"; ssh "$h" bash -s < checks/13-pitr.sh; done
# Run it after a reboot of both hosts: archiving must come back on its own.
# The history file check expects timeline 2, from the restore by hand on 2026-10-26.

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

not() {
    ! "$@"
}

server=db1
port=5433
role=remote_test
wal=/mnt/db2/backup/pgsql/wal
base=/mnt/db2/backup/pgsql/base
timeline=00000002

# Give up on a connection after 5 seconds.
export PGCONNECT_TIMEOUT=5

# Run one query on db1 as remote_test, with the password from ~/.pgpass.
query() {
    psql -w -h "$server" -p "$port" -U "$role" -d postgres -Atc "$1" 2>/dev/null
}

# A setting is empty. current_setting() fails when the role may not read it;
# then the query prints nothing and the check fails instead of passing.
empty_setting() {
    [ "$(query "SELECT current_setting('$1') || '|'")" = "|" ]
}

# Position of a segment in the WAL stream: the last 16 hex digits of its name
# (256 segments of 16 MiB per log file).
segno() {
    echo $((16#${1:8:8} * 256 + 16#${1:16:8}))
}

# Every timeline in the archive has all its segments, from its first to its last.
# A restore stops at the first missing segment.
no_gaps() {
    local segments tl names first last
    segments=$(ls "$wal" 2>/dev/null | grep -Ex '[0-9A-F]{24}')
    [ -n "$segments" ] || return 1
    for tl in $(cut -c1-8 <<<"$segments" | sort -u); do
        names=$(grep "^$tl" <<<"$segments")
        first=$(segno "$(head -n 1 <<<"$names")")
        last=$(segno "$(tail -n 1 <<<"$names")")
        [ $((last - first + 1)) -eq "$(wc -l <<<"$names")" ] || return 1
    done
}

# The newest base backup's start segment is in the archive. The name of its
# .backup file begins with that segment.
backup_start_archived() {
    local record
    record=$(ls "$wal" 2>/dev/null | grep -E '\.backup$' | tail -n 1)
    [ -n "$record" ] && [ -f "$wal/${record:0:24}" ]
}

if [ "$(hostname -s)" = db1 ]; then
    # Archiver
    archiver=$(ps -eo args= | grep '^postgres: archiver')
    check "package postgresql18-contrib is installed (pg_waldump)" rpm -q --quiet postgresql18-contrib
    check "the archiver process runs" [ -n "$archiver" ]
    check "the archiver is not failing" not grep -q 'failed on' <<<"$archiver"

    # Archive and base backup on the NFS share
    check "$wal has no missing segments" no_gaps
    check "$wal has the history file of timeline 2" [ -f "$wal/$timeline.history" ]
    check "the newest base backup's start segment is archived" backup_start_archived
    check "$base has at least one base backup" [ -n "$(ls -d "$base"/*/ 2>/dev/null)" ]
fi

if [ "$(hostname -s)" = db2 ]; then
    # The server on db1 after the restore
    check "$role logs in to $server:$port" [ "$(query 'SELECT current_user')" = "$role" ]
    check "the server is not in recovery" [ "$(query 'SELECT pg_is_in_recovery()')" = f ]
    check "archive_mode is on" [ "$(query 'SHOW archive_mode')" = on ]
    check "the last archive attempt succeeded" [ "$(query 'SELECT last_archived_time IS NOT NULL AND (last_failed_time IS NULL OR last_failed_time < last_archived_time) FROM pg_stat_archiver')" = t ]

    # No recovery settings left behind
    check "restore_command is not set" empty_setting restore_command
    check "recovery_target_time is not set" empty_setting recovery_target_time
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
