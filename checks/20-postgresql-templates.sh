#!/usr/bin/env bash
# Lesson 20 checks: postgresql.conf and pg_hba.conf from the templates of the role postgresql on db1 and db2.
# Reads the files and the live server with read-only commands sent through Ansible as root:
# both files come from Ansible, the server runs with every line in them and none waits for a
# restart, postgresql.auto.conf holds only the primary_ lines, and replicator and rewind log in
# to the other host. Then a check run of playbooks/postgresql.yml must change nothing.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/20-postgresql-templates.sh
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
data_dir=/pgdata/pgsql/data
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# Run one query as postgres over the local socket.
query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -XAtc '$2'"
}

for h in $hosts; do
    if [ "$h" = db1 ]; then other=192.168.122.12; else other=192.168.122.11; fi

    # The files come from the templates
    for f in postgresql.conf pg_hba.conf; do
        check "$h: $f starts with the Ansible header" [ "$(on "$h" "head -n 1 $data_dir/$f")" = "# Ansible managed" ]
    done

    # The server runs with what the files say
    check "$h: every line in the config files is applied" [ "$(query "$h" 'SELECT count(*) FROM pg_file_settings WHERE NOT applied')" = 0 ]
    check "$h: no setting waits for a restart" [ "$(query "$h" 'SELECT count(*) FROM pg_settings WHERE pending_restart')" = 0 ]
    check "$h: postgresql.auto.conf has only primary_ lines" [ -z "$(on "$h" "awk '!/^#/ && !/^primary_(conninfo|slot_name) / && NF' $data_dir/postgresql.auto.conf")" ]
    check "$h: log lines show the user and database" [ "$(query "$h" 'SHOW log_line_prefix')" = "%m [%p] %q%u@%d " ]
    check "$h: pg_hba.conf has 12 rules and no error" [ "$(query "$h" 'SELECT count(*), count(error) FROM pg_hba_file_rules')" = "12|0" ]

    # pg_hba.conf on the other host lets replicator and rewind in, with the passwords from .pgpass
    check "$h: replicator gets a replication connection to $other" grep -Eq '^[0-9]+\|[0-9]+\|' <<< "$(on "$h" "runuser -u postgres -- psql -w 'host=$other port=5433 user=replicator dbname=replication replication=true' -XAtc IDENTIFY_SYSTEM")"
    check "$h: rewind logs in to $other" [ "$(on "$h" "runuser -u postgres -- psql -w 'host=$other port=5433 user=rewind dbname=postgres' -XAtc 'SELECT current_user'")" = rewind ]
done

# The hosts match the playbook: a check run changes nothing, and its settings checks pass
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
