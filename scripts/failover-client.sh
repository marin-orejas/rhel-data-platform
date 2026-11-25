#!/usr/bin/env bash

conninfo="${FAILOVER_CONNINFO:-host=192.168.122.11,192.168.122.12 port=5433 dbname=lab user=remote_test target_session_attrs=read-write connect_timeout=2}"
table="${FAILOVER_TABLE:-failover_test}"
interval=0.2

while true; do
    now=$(date +%T.%3N)
    if out=$(psql -qAtXw -d "$conninfo" -c "INSERT INTO $table DEFAULT VALUES RETURNING id, server" 2>&1); then
        echo "$now ok $out"
    else
        echo "$now FAIL ${out//$'\n'/ }"
    fi
    sleep "$interval"
done
