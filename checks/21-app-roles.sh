#!/usr/bin/env bash
# Lesson 21 checks: the roles app and report and the database app on db1 and db2.
# Reads the catalog on both hosts with read-only queries sent through Ansible as root:
# both roles log in, only app and report may connect to the database app, app owns the
# schema app, and report may use it and read every new table of app there, but not write.
# Then app and report log in from db2 to db1 with the passwords from ~/.pgpass of makilele,
# and report is refused on the database lab.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/21-app-roles.sh
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
primary=192.168.122.11
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# Run one query as postgres in the database app over the local socket.
query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -d app -XAtc \"$2\""
}

# Log in from db2 to db1 as makilele, with the password from its ~/.pgpass.
login() {
    on db2 "runuser -u makilele -- psql -w 'host=$primary port=5433 dbname=$1 user=$2 connect_timeout=5' -XAtc '$3'"
}

for h in $hosts; do
    # The roles and the database
    check "$h: app and report can log in" [ "$(query "$h" "SELECT count(*) FROM pg_roles WHERE rolname IN ('app', 'report') AND rolcanlogin")" = 2 ]
    check "$h: postgres owns the database app" [ "$(query "$h" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'")" = postgres ]
    check "$h: PUBLIC cannot connect to app" [ "$(query "$h" "SELECT has_database_privilege('public', 'app', 'CONNECT')")" = f ]
    check "$h: app and report can connect to app" [ "$(query "$h" "SELECT has_database_privilege('app', 'app', 'CONNECT') AND has_database_privilege('report', 'app', 'CONNECT')")" = t ]

    # The schema app and what report may do there
    check "$h: app owns the schema app" [ "$(query "$h" "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'app'")" = app ]
    check "$h: report may use the schema app" [ "$(query "$h" "SELECT has_schema_privilege('report', 'app', 'USAGE')")" = t ]
    check "$h: report may read new tables of app in the schema app" [ "$(query "$h" "SELECT defaclacl FROM pg_default_acl WHERE defaclrole = 'app'::regrole AND defaclnamespace = 'app'::regnamespace AND defaclobjtype = 'r'")" = "{report=r/app}" ]
    check "$h: report cannot write to app.orders" [ "$(query "$h" "SELECT has_table_privilege('report', 'app.orders', 'INSERT, UPDATE, DELETE')")" = f ]
done

# Logins from db2 to db1, as the clients use them
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
