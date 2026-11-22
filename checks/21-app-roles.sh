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

hosts="db1 db2"
primary=192.168.122.11
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -d app -XAtc \"$2\""
}

login() {
    on db2 "runuser -u makilele -- psql -w 'host=$primary port=5433 dbname=$1 user=$2 connect_timeout=5' -XAtc '$3'"
}

for h in $hosts; do
    check "$h: app and report can log in" [ "$(query "$h" "SELECT count(*) FROM pg_roles WHERE rolname IN ('app', 'report') AND rolcanlogin")" = 2 ]
    check "$h: postgres owns the database app" [ "$(query "$h" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'")" = postgres ]
    check "$h: PUBLIC cannot connect to app" [ "$(query "$h" "SELECT has_database_privilege('public', 'app', 'CONNECT')")" = f ]
    check "$h: app and report can connect to app" [ "$(query "$h" "SELECT has_database_privilege('app', 'app', 'CONNECT') AND has_database_privilege('report', 'app', 'CONNECT')")" = t ]

    check "$h: app owns the schema app" [ "$(query "$h" "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'app'")" = app ]
    check "$h: report may use the schema app" [ "$(query "$h" "SELECT has_schema_privilege('report', 'app', 'USAGE')")" = t ]
    check "$h: report may read new tables of app in the schema app" [ "$(query "$h" "SELECT defaclacl FROM pg_default_acl WHERE defaclrole = 'app'::regrole AND defaclnamespace = 'app'::regnamespace AND defaclobjtype = 'r'")" = "{report=r/app}" ]
    check "$h: report cannot write to app.orders" [ "$(query "$h" "SELECT has_table_privilege('report', 'app.orders', 'INSERT, UPDATE, DELETE')")" = f ]
done

check "app logs in from db2 to app on db1" [ "$(login app app 'SELECT current_user')" = app ]
check "report reads app.orders from db2" grep -Eq '^[0-9]+$' <<< "$(login app report 'SELECT count(*) FROM app.orders')"
check "report is refused on the database lab" grep -q 'no pg_hba.conf entry' <<< "$(login lab report 'SELECT 1')"

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
