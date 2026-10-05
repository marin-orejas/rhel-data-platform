#!/usr/bin/env bash
# Lesson 07 checks: remote access from db2 to PostgreSQL on db1, port 5433.
# Run on db2 as the user who owns ~/.pgpass, no sudo needed:
#   ssh db2 bash -s < checks/07-postgres-remote.sh
# Run it after a reboot of db1: the SELinux port label, the firewall rule,
# listen_addresses and pg_hba.conf must all come back on their own.

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

# Give up on a connection after 5 seconds.
export PGCONNECT_TIMEOUT=5

# Run one query on db1 as remote_test. -w never asks for a password,
# so the login must work with ~/.pgpass alone.
query() {
    psql -w -h "$server" -p "$port" -U "$role" -d postgres -Atc "$1" 2>/dev/null
}

port_open() {
    timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# Client on db2
check "postgresql18 (client) is installed" rpm -q --quiet postgresql18
check "postgresql18-server is not installed" not rpm -q --quiet postgresql18-server
check "~/.pgpass is owned by $(id -un), mode 600" [ "$(stat -c '%U %a' ~/.pgpass 2>/dev/null)" = "$(id -un) 600" ]

# Remote access as remote_test
check "$role logs in to $server:$port without a password prompt" [ "$(query 'SELECT current_user')" = "$role" ]
check "the server answers on port $port" [ "$(query 'SELECT inet_server_port()')" = "$port" ]
check "$role is not a superuser" [ "$(query 'SHOW is_superuser')" = "off" ]

# What must stay closed
hba=$(psql -w -h "$server" -p "$port" -U postgres -d postgres -c 'SELECT 1' 2>&1)
check "postgres cannot log in from db2 (no pg_hba.conf entry)" grep -q 'no pg_hba.conf entry' <<<"$hba"
check "port 5432 on $server is closed" not port_open "$server" 5432

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
