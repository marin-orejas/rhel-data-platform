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
data_dir=/pgdata/pgsql/data
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -XAtc '$2'"
}

for h in $hosts; do
    if [ "$h" = db1 ]; then other=192.168.122.12; else other=192.168.122.11; fi

    for f in postgresql.conf pg_hba.conf; do
        check "$h: $f starts with the Ansible header" [ "$(on "$h" "head -n 1 $data_dir/$f")" = "# Ansible managed" ]
    done

    check "$h: every line in the config files is applied" [ "$(query "$h" 'SELECT count(*) FROM pg_file_settings WHERE NOT applied')" = 0 ]
    check "$h: no setting waits for a restart" [ "$(query "$h" 'SELECT count(*) FROM pg_settings WHERE pending_restart')" = 0 ]
    check "$h: postgresql.auto.conf has only primary_ lines" [ -z "$(on "$h" "awk '!/^#/ && !/^primary_(conninfo|slot_name) / && NF' $data_dir/postgresql.auto.conf")" ]
    check "$h: log lines show the user and database" [ "$(query "$h" 'SHOW log_line_prefix')" = "%m [%p] %q%u@%d " ]
    check "$h: pg_hba.conf has 14 rules and no error" [ "$(query "$h" 'SELECT count(*), count(error) FROM pg_hba_file_rules')" = "14|0" ]

    check "$h: replicator gets a replication connection to $other" grep -Eq '^[0-9]+\|[0-9]+\|' <<< "$(on "$h" "runuser -u postgres -- psql -w 'host=$other port=5433 user=replicator dbname=replication replication=true' -XAtc IDENTIFY_SYSTEM")"
    check "$h: rewind logs in to $other" [ "$(on "$h" "runuser -u postgres -- psql -w 'host=$other port=5433 user=rewind dbname=postgres' -XAtc 'SELECT current_user'")" = rewind ]
done

recap=$(ansible-playbook playbooks/postgresql.yml --check "${opts[@]}" 2>/dev/null)
for h in $hosts; do
    check "$h matches playbooks/postgresql.yml (changed=0)" grep -Eq "^$h +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " <<< "$recap"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
