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
tls_dir=/pgdata/pgsql/tls
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

query() {
    on "$1" "runuser -u postgres -- psql -p 5433 -XAtc \"$2\""
}

connect() {
    on "$1" "runuser -u postgres -- psql -w '$2 connect_timeout=5' -XAtc '$3'"
}

for h in $hosts; do
    if [ "$h" = db1 ]; then
        ip=192.168.122.11 other=192.168.122.12
    else
        ip=192.168.122.12 other=192.168.122.11
    fi

    check "$h: ssl is on" [ "$(query "$h" 'SHOW ssl')" = on ]
    check "$h: only postgres can read the key" [ "$(on "$h" "stat -c '%a %U' $tls_dir/server.key")" = "600 postgres" ]
    pubkey=$(on "$h" "openssl x509 -noout -pubkey -in $tls_dir/server.crt")
    check "$h: the key belongs to the certificate" [ "$(on "$h" "openssl pkey -pubout -in $tls_dir/server.key")" = "${pubkey:-no certificate}" ]
    check "$h: the certificate is valid for 30 more days" [ "$(on "$h" "openssl x509 -noout -checkend 2592000 -in $tls_dir/server.crt")" = "Certificate will not expire" ]
    for home in /var/lib/pgsql /home/makilele; do
        check "$h: the CA in $home/.postgresql/root.crt signed the certificate" [ "$(on "$h" "openssl verify -CAfile $home/.postgresql/root.crt $tls_dir/server.crt")" = "$tls_dir/server.crt: OK" ]
    done

    check "$h: pg_hba.conf has 8 hostssl rules and no other TCP rule outside loopback" [ "$(query "$h" "SELECT count(*) FILTER (WHERE type = 'hostssl'), count(*) FILTER (WHERE type IN ('host', 'hostnossl') AND address NOT IN ('127.0.0.1', '::1')) FROM pg_hba_file_rules")" = "8|0" ]
    check "$h: primary_conninfo checks the certificate of $other" grep -q "host=$other .*sslmode=verify-full" <<< "$(query "$h" 'SHOW primary_conninfo')"

    check "$h: replicator reaches $other with verify-full" grep -Eq '^[0-9]+\|[0-9]+\|' <<< "$(connect "$h" "host=$other port=5433 dbname=replication user=replicator sslmode=verify-full replication=true" IDENTIFY_SYSTEM)"
    check "$h: rewind reaches $other over TLS 1.3 with verify-full" [ "$(connect "$h" "host=$other port=5433 dbname=postgres user=rewind sslmode=verify-full" 'SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid()')" = "t|TLSv1.3" ]
    check "$h: a login to $other without TLS is refused" grep -q 'no encryption' <<< "$(connect "$h" "host=$other port=5433 dbname=postgres user=rewind sslmode=disable" 'SELECT 1')"
    check "$h: a server at the wrong address is refused" grep -q 'does not match host name' <<< "$(connect "$h" "host=$other hostaddr=$ip port=5433 dbname=postgres user=rewind sslmode=verify-full" 'SELECT 1')"

    if [ "$(query "$h" 'SELECT pg_is_in_recovery()')" = f ]; then
        check "$h: the standby streams over TLS 1.3" [ "$(query "$h" 'SELECT s.ssl, s.version FROM pg_stat_replication r JOIN pg_stat_ssl s USING (pid)')" = "t|TLSv1.3" ]
    fi
done

check "report reaches app on db1 over TLS with verify-full" [ "$(on db2 "runuser -u makilele -- psql -w 'host=192.168.122.11 port=5433 dbname=app user=report sslmode=verify-full connect_timeout=5' -XAtc 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()'")" = t ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
