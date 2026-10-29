#!/usr/bin/env bash
# Lesson 16 checks: what a failover from db1 to db2 needs, read from db2.
# Data checksums on both servers, the role rewind with only the four functions pg_rewind
# needs, the failover client's way to the primary and into lab on db2, and no slot left
# on db2. The failover itself: docs/runbooks/fail-over-to-db2.md.
# Run on db2 as the user who owns ~/.pgpass, no sudo needed:
#   ssh db2 bash -s < checks/16-failover.sh
# Run it after a reboot of both hosts. The pg_hba.conf lines for replicator and rewind and
# the .pgpass files of postgres are readable only by postgres, so this check cannot see them.
# The slot db2 on db1: checks/15-replication.sh.

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

primary=db1
primary_ip=192.168.122.11
standby_ip=192.168.122.12
port=5433
role=remote_test
# The connection string of scripts/failover-client.sh
conninfo="host=$primary_ip,$standby_ip port=$port dbname=lab user=$role target_session_attrs=read-write"

# Give up on a connection after 5 seconds.
export PGCONNECT_TIMEOUT=5

# Run one query as remote_test: query HOST DATABASE SQL. -w never asks for a password,
# so the login must work with ~/.pgpass alone. Its lines name db1 for the database postgres
# (checks/07) and the IP addresses for lab, so lab queries use the IP addresses.
query() {
    psql -w -h "$1" -p "$port" -U "$role" -d "$2" -Atc "$3" 2>/dev/null
}

# The functions pg_rewind runs on the source server
rewind_grants="SELECT count(*) FROM unnest(ARRAY['pg_catalog.pg_ls_dir(text, boolean, boolean)', 'pg_catalog.pg_stat_file(text, boolean)', 'pg_catalog.pg_read_binary_file(text)', 'pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)']) AS f WHERE has_function_privilege('rewind', f, 'EXECUTE')"

# pg_rewind needs data checksums (or wal_log_hints)
check "data checksums are on on $primary" [ "$(query "$primary" postgres 'SHOW data_checksums')" = on ]
check "data checksums are on on db2" [ "$(query "$standby_ip" lab 'SHOW data_checksums')" = on ]

# The role rewind, created on db1 and replicated to db2
check "rewind can log in and is neither a superuser nor a replication role" [ "$(query "$primary" postgres "SELECT rolcanlogin AND NOT rolsuper AND NOT rolreplication FROM pg_roles WHERE rolname = 'rewind'")" = t ]
check "rewind may run the four functions pg_rewind needs" [ "$(query "$primary" postgres "$rewind_grants")" = 4 ]

# The failover client
check "the client's connection string reaches the primary $primary_ip" [ "$(psql -w -d "$conninfo" -Atc 'SELECT inet_server_addr()' 2>/dev/null)" = "$primary_ip" ]
check "$role may insert into lab.failover_test" [ "$(query "$primary_ip" lab "SELECT has_table_privilege('failover_test', 'INSERT')")" = t ]
check "db2 lets $role into lab and is a standby" [ "$(query "$standby_ip" lab 'SELECT pg_is_in_recovery()')" = t ]

# A slot left on the standby after a failover would keep WAL on db2
check "db2 keeps no replication slot" [ "$(query "$standby_ip" lab 'SELECT count(*) FROM pg_replication_slots')" = 0 ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
