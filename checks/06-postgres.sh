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

pgdata=/pgdata/pgsql/data

check "postgresql18-server is installed" rpm -q --quiet postgresql18-server
check "postgresql is enabled" [ "$(systemctl is-enabled postgresql 2>/dev/null)" = "enabled" ]
check "postgresql is running" [ "$(systemctl is-active postgresql 2>/dev/null)" = "active" ]

env=$(systemctl show -p Environment --value postgresql 2>/dev/null | tr ' ' '\n')
check "the service sets PGDATA=$pgdata" grep -qx "PGDATA=$pgdata" <<<"$env"
check "the service requires the /pgdata mount" [ "$(systemctl show -p RequiresMountsFor --value postgresql 2>/dev/null)" = "/pgdata" ]

check "SELinux is enforcing" [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
check "the SELinux rule gives $pgdata the type postgresql_db_t" [ "$(matchpathcon -n "$pgdata" 2>/dev/null | cut -d: -f3)" = "postgresql_db_t" ]
check "/pgdata/pgsql has the type postgresql_db_t" [ "$(stat -c %C /pgdata/pgsql 2>/dev/null | cut -d: -f3)" = "postgresql_db_t" ]
check "/pgdata/pgsql is owned by postgres, mode 700" [ "$(stat -c '%U:%G %a' /pgdata/pgsql 2>/dev/null)" = "postgres:postgres 700" ]

main=$(systemctl show -p MainPID --value postgresql 2>/dev/null)
check "the server runs with -D $pgdata" [ "$(ps -o args= -p "$main" 2>/dev/null)" = "/usr/bin/postgres -D $pgdata" ]
check "the server runs in the SELinux domain postgresql_t" [ "$(ps -o label= -p "$main" 2>/dev/null | cut -d: -f3)" = "postgresql_t" ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
