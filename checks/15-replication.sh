#!/usr/bin/env bash
# Lesson 15 checks: streaming replication from db1 to the standby on db2.
# db1 checks its walsender for db2 and that the standby's port is reachable; db2 checks
# its data disk, its startup and walreceiver processes, and, as remote_test like
# checks/07, the slot on db1. The server itself on both hosts: checks/06-postgres.sh.
# Run as the owner, no sudo needed:
#   for h in db1 db2; do echo "== $h"; ssh "$h" bash -s < checks/15-replication.sh; done
# Run it after a reboot of both hosts: db2 must come back as a standby and stream again.
# The owner cannot read the data directories (postgres, 700), so the processes and the
# slot on db1 show the replication state.

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
standby=db2
standby_ip=192.168.122.12
port=5433
role=remote_test
slot=db2

# Give up on a connection after 5 seconds.
export PGCONNECT_TIMEOUT=5

# Run one query on db1 as remote_test, with the password from ~/.pgpass.
query() {
    psql -w -h "$server" -p "$port" -U "$role" -d postgres -Atc "$1" 2>/dev/null
}

port_open() {
    timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# The timeline in a WAL file name (its first 8 hex digits) is the current timeline of db1.
same_timeline() {
    [ -n "$1" ] && [ "$1" = "$(query 'SELECT left(pg_walfile_name(pg_current_wal_lsn()), 8)')" ]
}

if [ "$(hostname -s)" = db1 ]; then
    # The walsender for db2, for example
    # "postgres: walsender replicator 192.168.122.12(41234) streaming 0/2A000060"
    walsender=$(ps -eo args= | grep '^postgres: walsender replicator 192\.168\.122\.12(')
    check "a walsender for $standby_ip runs" [ -n "$walsender" ]
    check "the walsender for $standby_ip is streaming" grep -q ' streaming ' <<<"$walsender"

    # Firewall on db2
    check "$standby answers on port $port" port_open "$standby" "$port"
fi

if [ "$(hostname -s)" = db2 ]; then
    # Data disk: LV pgdata next to LV backup, XFS, mounted on /pgdata by UUID
    uuid=$(lsblk -dno UUID /dev/data/pgdata 2>/dev/null)
    check "LV data/pgdata is on /dev/vdb1" grep -qx data-pgdata <<<"$(lsblk -nro NAME /dev/vdb1 2>/dev/null)"
    check "LV data/pgdata is 5 GiB" [ "$(lsblk -bdno SIZE /dev/data/pgdata 2>/dev/null)" = "5368709120" ]
    check "/etc/fstab mounts it on /pgdata by UUID" grep -Eq "^UUID=$uuid[[:space:]]+/pgdata[[:space:]]+xfs[[:space:]]" /etc/fstab
    check "/pgdata is mounted from data/pgdata" [ "$(findmnt -no SOURCE /pgdata 2>/dev/null)" = "/dev/mapper/data-pgdata" ]

    # Standby processes, for example "postgres: startup recovering 000000030000000000000027".
    # The walreceiver adds "streaming <LSN>" to its title only after it has written new WAL,
    # so on an idle primary the title is just "postgres: walreceiver". Whether it streams
    # shows on db1: the walsender and the active slot.
    startup=$(ps -eo args= | grep '^postgres: startup recovering ')
    check "the startup process replays WAL (the server is a standby)" [ -n "$startup" ]
    check "the walreceiver runs" grep -q '^postgres: walreceiver' <<<"$(ps -eo args=)"
    replayed_tl=$(awk '{print substr($NF, 1, 8)}' <<<"$startup")
    check "db2 replays the current timeline of $server" same_timeline "$replayed_tl"

    # The slot on db1
    check "$role logs in to $server:$port" [ "$(query 'SELECT current_user')" = "$role" ]
    check "slot $slot on $server is physical and active" [ "$(query "SELECT slot_type || ' ' || active FROM pg_replication_slots WHERE slot_name = '$slot'")" = "physical true" ]
    check "slot $slot has its WAL (not lost)" [ "$(query "SELECT wal_status IN ('reserved', 'extended') FROM pg_replication_slots WHERE slot_name = '$slot'")" = t ]
    check "max_slot_wal_keep_size on $server is 1GB" [ "$(query "SELECT current_setting('max_slot_wal_keep_size')")" = "1GB" ]
    check "db2 is less than 16 MB behind $server" [ "$(query "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) < 16 * 1024 * 1024 FROM pg_replication_slots WHERE slot_name = '$slot'")" = t ]
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
