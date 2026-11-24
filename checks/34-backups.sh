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

server=https://127.0.0.1:6443
op=cnpg-system
plugin=plugin-barman-cloud
plugin_chart=plugin-barman-cloud-0.9.0
plugin_image=ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.16.0
plugin_name=barman-cloud.cloudnative-pg.io
ns=pg
cluster=pg
instances="pg-1 pg-2"
store=db2
nightly=pg-nightly
schedule="0 0 2 * * *"
restore=kubernetes/apps/pg-restore
record="5000|12502500"
host=db2
client=k8s2
bucket=pg-backups
ca=/var/lib/pgsql/.postgresql/root.crt
sigv4=aws:amz:garage:s3
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

rolled_out() {
    kube rollout status "$1" -n "$2" --timeout=10s >/dev/null
}

chart() {
    kube get "$1" -n "$2" -o jsonpath='{.metadata.labels.helm\.sh/chart}'
}

secret() {
    kube get secret "$1" -n "$ns" -o jsonpath="{.data.$2}" | base64 -d
}

condition() {
    kube get cluster "$cluster" -n "$ns" -o jsonpath="{.status.conditions[?(@.type==\"$1\")].status}"
}

sql() {
    kube exec "$1" -n "$ns" -c postgres -- psql -d "$2" -XAtc "$3"
}

next_run() {
    local next
    next=$(kube get scheduledbackup "$nightly" -n "$ns" -o jsonpath='{.status.nextScheduleTime}')
    [[ $next == *T02:00:00Z && $next > $(date -u +%Y-%m-%dT%H:%M:%SZ) ]]
}

in_bucket() {
    printf 'user = "%s"\n' "$cred" |
        ssh "$client" "curl -sS -m 10 --cacert lab-ca.crt --aws-sigv4 $sigv4 -K - 'https://db2/$bucket/?list-type=2&prefix=${1//\//%2F}'" 2>/dev/null |
        grep -q "<Key>$1"
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

check "deployment/$plugin is from chart $plugin_chart" [ "$(chart "deployment/$plugin" "$op")" = "$plugin_chart" ]
check "the plugin runs $plugin_image" \
    [ "$(kube get deployment "$plugin" -n "$op" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$plugin_image" ]
check "the rollout of deployment/$plugin is complete" rolled_out "deployment/$plugin" "$op"
check "the Service barman-cloud names the plugin $plugin_name for the operator" \
    [ "$(kube get service barman-cloud -n "$op" -o jsonpath='{.metadata.labels.cnpg\.io/pluginName}')" = "$plugin_name" ]
check "the certificates barman-cloud-client and barman-cloud-server are ready" \
    [ "$(kube get certificate barman-cloud-client barman-cloud-server -n "$op" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')" = "True True" ]
check "the CRD objectstores.barmancloud.cnpg.io is installed" [ -n "$(kube get crd objectstores.barmancloud.cnpg.io -o name)" ]

cred=$(ansible "$host" -m ansible.builtin.debug -a "msg={{ garage_s3_key_id }}:{{ garage_s3_secret_key }}" 2>/dev/null |
    grep -o 'GK[0-9a-f]\{24\}:[0-9a-f]\{64\}')
ca_sum=$(on "$host" "sha256sum $ca" | cut -d' ' -f1)
check "the ObjectStore $store sends to s3://$bucket/ at https://db2 and keeps 7d" \
    [ "$(kube get objectstores.barmancloud.cnpg.io "$store" -n "$ns" -o jsonpath='{.spec.configuration.destinationPath} {.spec.configuration.endpointURL} {.spec.retentionPolicy}')" = "s3://$bucket/ https://db2 7d" ]
check "the Secret garage-cnpg holds the S3 key from the vault of $host and the region garage" \
    [ "$(secret garage-cnpg ACCESS_KEY_ID):$(secret garage-cnpg ACCESS_SECRET_KEY) $(secret garage-cnpg REGION)" = "${cred:-no key} garage" ]
check "the Secret lab-ca holds the lab CA of $host" \
    [ "$(secret lab-ca 'ca\.crt' | sha256sum | cut -d' ' -f1)" = "${ca_sum:-no CA}" ]

primary=$(kube get cluster "$cluster" -n "$ns" -o jsonpath='{.status.currentPrimary}')
[ -n "$primary" ] || primary=none
check "the Cluster $cluster archives WAL through $plugin_name to the ObjectStore $store" \
    [ "$(kube get cluster "$cluster" -n "$ns" -o jsonpath='{.spec.plugins[0].name} {.spec.plugins[0].isWALArchiver} {.spec.plugins[0].parameters.barmanObjectName}')" = "$plugin_name true $store" ]
check "the Cluster $cluster reports continuous archiving" [ "$(condition ContinuousArchiving)" = True ]
for i in $instances; do
    check "$i runs the native sidecar $plugin, ready" \
        [ "$(kube get pod "$i" -n "$ns" -o jsonpath="{.spec.initContainers[?(@.name==\"$plugin\")].restartPolicy} {.status.initContainerStatuses[?(@.name==\"$plugin\")].ready}")" = "Always true" ]
    check "$i has the QoS class Guaranteed" [ "$(kube get pod "$i" -n "$ns" -o jsonpath='{.status.qosClass}')" = Guaranteed ]
done

archiver=$(sql "$primary" postgres 'SELECT last_archived_wal, last_failed_time IS NULL OR last_archived_time > last_failed_time FROM pg_stat_archiver')
wal=${archiver%|*}
wal=${wal:-none}
dir=${wal:0:16}/
[[ $wal == *.history ]] && dir=
check "$primary: the last WAL archive attempt succeeded" [ "${archiver#*|}" = t ]
check "$primary: no WAL waits to be archived" \
    [ "$(sql "$primary" postgres "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'")" = 0 ]
check "$client: the last archived WAL $wal is in s3://$bucket/$cluster/wals/" in_bucket "$cluster/wals/$dir$wal"

backup=$(kube get backups -n "$ns" -o jsonpath="{range .items[?(@.spec.cluster.name==\"$cluster\")]}{.status.phase} {.spec.method} {.status.stoppedAt} {.status.backupId}{\"\\n\"}{end}" |
    awk '$1 == "completed" && $2 == "plugin"' | sort -k3 | tail -n 1 | cut -d' ' -f4)
check "the ScheduledBackup $nightly backs up $cluster with the plugin at 02:00 UTC" \
    [ "$(kube get scheduledbackup "$nightly" -n "$ns" -o jsonpath='{.spec.cluster.name}|{.spec.schedule}|{.spec.method}')" = "$cluster|$schedule|plugin" ]
check "$nightly runs next at 02:00 UTC, later than now" next_run
check "the Cluster $cluster reports that its last backup succeeded" [ "$(condition LastBackupSucceeded)" = True ]
check "a plugin backup of $cluster is completed (newest: ${backup:-none})" [ -n "$backup" ]
check "$client: the base backup ${backup:-none} is in s3://$bucket/$cluster/base/" in_bucket "$cluster/base/${backup:-none}/backup.info"

check "restore_test keeps the rows brought back by the restore to a set time: 5000, sum(id) 12502500" \
    [ "$(sql "$primary" app 'SELECT count(*), sum(id) FROM restore_test')" = "$record" ]
check "$restore/ makes the Cluster pg-restore in $ns (server-side dry run)" \
    [ "$(kube create --dry-run=server -k "../$restore" -o jsonpath='{.metadata.namespace}/{.metadata.name}')" = "$ns/pg-restore" ]
check "no Cluster pg-restore is left in $ns, and its only PVCs are $instances (it exists only during a restore)" \
    [ "$(kube get cluster pg-restore -n "$ns" -o name --ignore-not-found)$(kube get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}')" = "$instances" ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
