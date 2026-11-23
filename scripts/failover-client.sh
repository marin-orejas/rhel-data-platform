#!/usr/bin/env bash
# Failover test client: writes one row to failover_test every 0.2 s and prints one line
# per try, so the log shows when the writes stopped and on which server they came back.
# FAILOVER_CONNINFO picks the servers. The default names db1 and db2, and libpq tries
# them in order and keeps the one that accepts writes.

conninfo="${FAILOVER_CONNINFO:-host=192.168.122.11,192.168.122.12 port=5433 dbname=lab user=remote_test target_session_attrs=read-write connect_timeout=2}"
interval=0.2

while true; do
    now=$(date +%T.%3N)
    if out=$(psql -qAtXw -d "$conninfo" -c 'INSERT INTO failover_test DEFAULT VALUES RETURNING id, server' 2>&1); then
        echo "$now ok $out"
    else
        echo "$now FAIL ${out//$'\n'/ }"
    fi
    sleep "$interval"
done
