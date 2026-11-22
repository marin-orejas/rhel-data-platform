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

not() {
    ! "$@"
}

server=db1
port=5433
role=remote_test

export PGCONNECT_TIMEOUT=5

query() {
    psql -w -h "$server" -p "$port" -U "$role" -d postgres -Atc "$1" 2>/dev/null
}

empty_setting() {
    [ "$(query "SELECT current_setting('$1') || '|'")" = "|" ]
}

if [ "$(hostname -s)" = db1 ]; then
    archiver=$(ps -eo args= | grep '^postgres: archiver')
    check "package postgresql18-contrib is installed (pg_waldump)" rpm -q --quiet postgresql18-contrib
    check "the archiver process runs" [ -n "$archiver" ]
    check "the archiver is not failing" not grep -q 'failed on' <<<"$archiver"
fi

if [ "$(hostname -s)" = db2 ]; then
    check "$role logs in to $server:$port" [ "$(query 'SELECT current_user')" = "$role" ]
    check "the server is not in recovery" [ "$(query 'SELECT pg_is_in_recovery()')" = f ]
    check "archive_mode is on" [ "$(query 'SHOW archive_mode')" = on ]
    check "the last archive attempt succeeded" [ "$(query 'SELECT last_archived_time IS NOT NULL AND (last_failed_time IS NULL OR last_failed_time < last_archived_time) FROM pg_stat_archiver')" = t ]

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
