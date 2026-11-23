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

workers="k8s2 k8s3"
server=https://127.0.0.1:6443
plugin=1.30.2
op=cnpg-system
op_deploy=cnpg-cloudnative-pg
op_chart=cloudnative-pg-0.29.2
op_image=ghcr.io/cloudnative-pg/cloudnative-pg:1.30.2
ns=pg
cluster=pg
instances="pg-1 pg-2"
manifests=kubernetes/apps/pg
client=kubernetes/apps/failover-client
system_id=7711408803285843983
wal="256MB|128MB|256MB"
sc=topolvm
size=1Gi
vg=data
record="10.244.109.109|658|1|658 10.244.219.26|2738|684|3421"
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

matches_repo() {
    kube diff -k "../$manifests" >/dev/null
}

status() {
    kube get cluster "$cluster" -n "$ns" -o jsonpath="{.status.$1}"
}

sql() {
    kube exec "$1" -n "$ns" -c postgres -- psql -d "$2" -XAtc "$3"
}

login() {
    kube get secret "$cluster-$1" -n "$ns" -o jsonpath='{.data.password}' | base64 -d |
        kube exec -i "$primary" -n "$ns" -c postgres -- sh -c \
            "read -r PGPASSWORD; export PGPASSWORD; psql 'host=$2 user=$1 dbname=app connect_timeout=5' -XAtc 'SELECT current_user, pg_is_in_recovery()'"
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

check "the plugin kubectl cnpg $plugin is installed (RPM cnpg)" [ "$(rpm -q --qf '%{VERSION}' cnpg)" = "$plugin" ]
check "deployment/$op_deploy is from chart $op_chart" [ "$(chart "deployment/$op_deploy" "$op")" = "$op_chart" ]
check "the operator runs $op_image" \
    [ "$(kube get deployment "$op_deploy" -n "$op" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$op_image" ]
check "$op_deploy runs 2 replicas" [ "$(kube get deployment "$op_deploy" -n "$op" -o jsonpath='{.spec.replicas}')" = 2 ]
check "the rollout of deployment/$op_deploy is complete" rolled_out "deployment/$op_deploy" "$op"
check "the two operator pods run one on each worker" \
    [ "$(kube get pods -n "$op" -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | xargs)" = "$workers" ]
check "the 11 CRDs of CloudNativePG are installed" [ "$(kube get crd -o name | grep -c '\.postgresql\.cnpg\.io$')" = 11 ]
check "helm uninstall keeps the CRD clusters.postgresql.cnpg.io" \
    [ "$(kube get crd clusters.postgresql.cnpg.io -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}')" = keep ]

check "the Cluster $cluster matches $manifests/" matches_repo
check "the Cluster $cluster is in a healthy state" [ "$(status phase)" = "Cluster in healthy state" ]
check "the Cluster $cluster has 2 of 2 instances ready" [ "$(status readyInstances)/$(status instances)" = 2/2 ]
check "the Cluster $cluster keeps the system ID $system_id of its initdb" [ "$(status systemID)" = "$system_id" ]
check "the operator reconciles the managed role report" [ "$(status 'managedRolesStatus.byStatus.reconciled[*]')" = report ]

pods=$(kube get pods -n "$ns" -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.labels.cnpg\.io/instanceRole}{"\n"}{end}')
primary=$(awk '$3 == "primary" {print $1}' <<< "$pods")
standby=$(awk '$3 == "replica" {print $1}' <<< "$pods")
[ -n "$primary" ] || primary=none
[ -n "$standby" ] || standby=none
check "the instances are $instances" [ "$(awk '{print $1}' <<< "$pods" | sort | xargs)" = "$instances" ]
check "the instances run one on each worker" [ "$(awk '{print $2}' <<< "$pods" | sort | xargs)" = "$workers" ]
check "one instance is the primary ($primary) and one the standby ($standby)" \
    [ "$(awk '{print $3}' <<< "$pods" | sort | xargs)" = "primary replica" ]
check "$primary is the current primary of the Cluster $cluster" [ "$(status currentPrimary)" = "$primary" ]

check "$primary is not in recovery and runs PostgreSQL 18" \
    [ "$(sql "$primary" postgres "SELECT pg_is_in_recovery(), current_setting('server_version_num')::int / 10000")" = "f|18" ]
check "$standby is in recovery and its WAL receiver is streaming" \
    [ "$(sql "$standby" postgres 'SELECT pg_is_in_recovery(), status FROM pg_stat_wal_receiver')" = "t|streaming" ]
check "$primary streams to $standby" \
    [ "$(sql "$primary" postgres 'SELECT application_name, state FROM pg_stat_replication')" = "$standby|streaming" ]
check "$primary keeps an active replication slot for $standby" \
    [ "$(sql "$primary" postgres "SELECT active FROM pg_replication_slots WHERE slot_name = '_cnpg_${standby//-/_}'")" = t ]
check "$primary runs max_wal_size, wal_keep_size and max_slot_wal_keep_size ${wal//|/, }" \
    [ "$(sql "$primary" postgres "SELECT current_setting('max_wal_size'), current_setting('wal_keep_size'), current_setting('max_slot_wal_keep_size')")" = "$wal" ]

check "the database app is owned by app" \
    [ "$(sql "$primary" postgres "SELECT datdba::regrole FROM pg_database WHERE datname = 'app'")" = app ]
check "report can log in and is a member of pg_read_all_data" \
    [ "$(sql "$primary" postgres "SELECT rolcanlogin, pg_has_role('report', 'pg_read_all_data', 'member') FROM pg_roles WHERE rolname = 'report'")" = "t|t" ]
for s in app report; do
    check "the Secret $cluster-$s is basic-auth with the label cnpg.io/reload=true" \
        [ "$(kube get secret "$cluster-$s" -n "$ns" -o jsonpath='{.type} {.metadata.labels.cnpg\.io/reload}')" = "kubernetes.io/basic-auth true" ]
done
check "app logs in through pg-rw and lands on the primary" [ "$(login app pg-rw)" = "app|f" ]
check "report logs in through pg-ro and lands on the standby" [ "$(login report pg-ro)" = "report|t" ]

declare -A lvs
for w in $workers; do
    lvs[$w]=$(on "$w" "lvs --noheadings --units g -o lv_name,lv_size,lv_attr $vg")
done
for i in $instances; do
    pv=$(kube get pvc "$i" -n "$ns" -o jsonpath='{.spec.volumeName}')
    node=$(kube get pv "${pv:-none}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
    handle=$(kube get pv "${pv:-none}" -o jsonpath='{.spec.csi.volumeHandle}')
    check "the PVC $i is Bound, $size on $sc" \
        [ "$(kube get pvc "$i" -n "$ns" -o jsonpath='{.status.phase} {.status.capacity.storage} {.spec.storageClassName}')" = "Bound $size $sc" ]
    check "$i runs on ${node:-no node}, the node of its volume" \
        [ "$(kube get pod "$i" -n "$ns" -o jsonpath='{.spec.nodeName}')" = "${node:-no node}" ]
    check "$i: its LV on ${node:-no node} is ${size%Gi}.00g, active and open" \
        [ "$(awk -v lv="${handle:-none}" '$1 == lv {print $2, $3}' <<< "${lvs[${node:-none}]}")" = "${size%Gi}.00g -wi-ao----" ]
done

check "$client/ makes the Pod failover-client in $ns (server-side dry run)" \
    [ "$(kube create --dry-run=server -k "../$client" -o jsonpath='{.metadata.namespace}/{.metadata.name}')" = "$ns/failover-client" ]
check "no Pod or ConfigMap failover-client is left in $ns (they exist only during a test)" \
    [ -z "$(kube get pod,configmap failover-client -n "$ns" -o name --ignore-not-found)" ]
check "failover_test keeps the record: 658 rows from the old primary, 2738 from the new one" \
    [ "$(sql "$primary" app 'SELECT server, count(*), min(id), max(id) FROM failover_test GROUP BY server ORDER BY min(id)' | xargs)" = "$record" ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
