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

primary=db1
primary_ip=192.168.122.11
standby_ip=192.168.122.12
port=5433
role=remote_test
conninfo="host=$primary_ip,$standby_ip port=$port dbname=lab user=$role target_session_attrs=read-write"

export PGCONNECT_TIMEOUT=5

query() {
    psql -w -h "$1" -p "$port" -U "$role" -d "$2" -Atc "$3" 2>/dev/null
}

rewind_grants="SELECT count(*) FROM unnest(ARRAY['pg_catalog.pg_ls_dir(text, boolean, boolean)', 'pg_catalog.pg_stat_file(text, boolean)', 'pg_catalog.pg_read_binary_file(text)', 'pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)']) AS f WHERE has_function_privilege('rewind', f, 'EXECUTE')"

check "data checksums are on on $primary" [ "$(query "$primary" postgres 'SHOW data_checksums')" = on ]
check "data checksums are on on db2" [ "$(query "$standby_ip" lab 'SHOW data_checksums')" = on ]

check "rewind can log in and is neither a superuser nor a replication role" [ "$(query "$primary" postgres "SELECT rolcanlogin AND NOT rolsuper AND NOT rolreplication FROM pg_roles WHERE rolname = 'rewind'")" = t ]
check "rewind may run the four functions pg_rewind needs" [ "$(query "$primary" postgres "$rewind_grants")" = 4 ]

check "the client's connection string reaches the primary $primary_ip" [ "$(psql -w -d "$conninfo" -Atc 'SELECT inet_server_addr()' 2>/dev/null)" = "$primary_ip" ]
check "$role may insert into lab.failover_test" [ "$(query "$primary_ip" lab "SELECT has_table_privilege('failover_test', 'INSERT')")" = t ]
check "db2 lets $role into lab and is a standby" [ "$(query "$standby_ip" lab 'SELECT pg_is_in_recovery()')" = t ]

check "db2 keeps no replication slot" [ "$(query "$standby_ip" lab 'SELECT count(*) FROM pg_replication_slots')" = 0 ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
