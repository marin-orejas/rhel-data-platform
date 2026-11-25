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
host=k8s1
version=v1.36.7
config=kubernetes/kubeadm/config.yaml
registry=registry.k8s.io
control_plane="kube-apiserver kube-controller-manager kube-scheduler"
etcd_image=registry.k8s.io/etcd:3.6.8-0
nodes="k8s1= k8s2= k8s3="
pki=/etc/kubernetes/pki
renewed="apiserver apiserver-etcd-client apiserver-kubelet-client front-proxy-client"
declare -A ca_of=([apiserver]=ca [apiserver-etcd-client]=etcd/ca [apiserver-kubelet-client]=ca [front-proxy-client]=front-proxy-ca)
cas="ca front-proxy-ca etcd/ca"
renewed_on=2026-11-25
renewed_until=2027-11-25
built_on=2026-11-15
ns=pg
cluster=pg
primary=pg-2
primary_node=k8s3
standby=pg-1
standby_node=k8s2
timeline=4
table=upgrade_test
record="10174|1|10226"
gaps="1327-1350 7900-7927"
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

sql() {
    kube exec "$1" -n "$ns" -c postgres -- psql -d "$2" -XAtc "$3"
}

status() {
    kube get cluster "$cluster" -n "$ns" -o jsonpath="{.status.$1}"
}

node_of() {
    kube get pod "$1" -n "$ns" -o jsonpath='{.spec.nodeName}'
}

dated() {
    [ "$(awk -v crt="$pki/$1.crt" -v key="$pki/$1.key" '$1 == crt || $1 == key {print $2}' <<< "$stats" | xargs)" = "$2 $2" ]
}

expires() {
    local end
    end=$(on "$host" "openssl x509 -noout -enddate -in $pki/$1.crt")
    end=${end#notAfter=}
    [ -n "$end" ] && date -u -d "$end" +%F 2>/dev/null
}

signed_by() {
    grep -qx "$pki/$1.crt: OK" <<< "$(on "$host" "openssl verify -CAfile $pki/$2.crt $pki/$1.crt")"
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

check "kubeadm-config has kubernetesVersion $version" \
    grep -qx "kubernetesVersion: $version" <<< "$(kube get configmap -n kube-system kubeadm-config -o jsonpath='{.data.ClusterConfiguration}')"
check "$config has kubernetesVersion $version, the same as the cluster" grep -qx "kubernetesVersion: $version" "../$config"
images=$(on "$host" "grep -h image: /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/etcd.yaml")
for p in $control_plane; do
    check "$host: the manifest $p.yaml runs $registry/$p:$version" grep -Eqx " *image: $registry/$p:$version" <<< "$images"
done
check "$host: the upgrade left etcd at $etcd_image" grep -Eqx " *image: $etcd_image" <<< "$images"
check "the DaemonSet kube-proxy runs $registry/kube-proxy:$version" \
    [ "$(kube get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$registry/kube-proxy:$version" ]
check "kube-proxy runs the new image on 3 of 3 nodes" \
    [ "$(kube get daemonset kube-proxy -n kube-system -o jsonpath='{.status.updatedNumberScheduled}/{.status.numberReady}')" = 3/3 ]

check "k8s1, k8s2 and k8s3 are schedulable again (no node is left cordoned)" \
    [ "$(kube get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.spec.unschedulable}{" "}{end}' | xargs)" = "$nodes" ]

files=""
for c in $renewed $cas; do
    files="$files $pki/$c.crt $pki/$c.key"
done
stats=$(on "$host" "stat -c '%n %y' $files")
for c in $renewed; do
    check "$host: $c.crt and $c.key were renewed by the upgrade on $renewed_on" dated "$c" "$renewed_on"
    check "$host: $c.crt expires on $renewed_until, one year after the upgrade" [ "$(expires "$c")" = "$renewed_until" ]
    check "$host: $c.crt is still signed by the CA ${ca_of[$c]}.crt" signed_by "$c" "${ca_of[$c]}"
done
for c in $cas; do
    check "$host: the CA $c.crt and $c.key are the ones from $built_on, not renewed" dated "$c" "$built_on"
done

check "the Cluster $cluster is in a healthy state" [ "$(status phase)" = "Cluster in healthy state" ]
check "$primary on $primary_node is the primary of the Cluster $cluster" \
    [ "$(status currentPrimary) $(node_of "$primary")" = "$primary $primary_node" ]
check "the Cluster $cluster is on timeline $timeline after the two switchovers" [ "$(status timelineID)" = "$timeline" ]
check "$primary is not in recovery and its last checkpoint is on timeline $timeline" \
    [ "$(sql "$primary" postgres 'SELECT pg_is_in_recovery(), timeline_id FROM pg_control_checkpoint()')" = "f|$timeline" ]
check "$standby on $standby_node is in recovery and streams timeline $timeline" \
    [ "$(node_of "$standby") $(sql "$standby" postgres 'SELECT pg_is_in_recovery(), status, received_tli FROM pg_stat_wal_receiver')" = "$standby_node t|streaming|$timeline" ]

check "$table keeps every row the client wrote through the upgrade: 10174, ids 1 to 10226" \
    [ "$(sql "$primary" app "SELECT count(*), min(id), max(id) FROM $table")" = "$record" ]
check "$table misses only the ids ${gaps// / and }, the sequence jumps at the two promotions" \
    [ "$(sql "$primary" app "SELECT string_agg(lo || '-' || hi, ' ' ORDER BY lo) FROM (SELECT id + 1 AS lo, lead(id) OVER (ORDER BY id) - 1 AS hi FROM $table) s WHERE hi >= lo")" = "$gaps" ]
check "$table belongs to app" \
    [ "$(sql "$primary" app "SELECT tableowner FROM pg_tables WHERE tablename = '$table'")" = app ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
