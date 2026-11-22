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
images=/var/lib/libvirt/images
vg=data
cm=cert-manager
cm_chart=cert-manager-v1.21.3
topolvm=topolvm-system
topolvm_chart=topolvm-17.3.1
sc=topolvm
ns=writer
manifests=kubernetes/apps/writer
sizes=(2Gi 1Gi)
grown_df=2.0G
marker=2026-11-20T16:02:47Z
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

on_nuc() {
    ssh -n nuc "$*" 2>/dev/null
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

sc_field() {
    kube get storageclass "$sc" -o jsonpath="{.$1}"
}

webhook_answers() {
    kube create --dry-run=server -f - >/dev/null <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: check-31
  namespace: default
spec:
  selfSigned: {}
EOF
}

is_bytes() {
    local n
    case $1 in
        *Gi) n=$((${1%Gi} * 1073741824)) ;;
        *Mi) n=$((${1%Mi} * 1048576)) ;;
        *) n=$1 ;;
    esac
    [ -n "$2" ] && [ "$n" = "$2" ]
}

only_volumes() {
    local on_node in_cluster
    on_node=$(awk '{print $1}' <<< "${lvs[$1]}" | sort | xargs)
    in_cluster=$(awk -v w="$1" '$1 == w {print $2}' <<< "$volumes" | sort | xargs)
    [ -n "$on_node" ] && [ "$on_node" = "$in_cluster" ]
}

recent() {
    local last age
    last=$(kube exec "$1" -n "$ns" -- tail -n 1 /data/log.txt)
    [ -n "$last" ] || return 1
    age=$(($(date -u +%s) - $(date -u -d "$last" +%s 2>/dev/null || echo 0)))
    [ "$age" -ge -5 ] && [ "$age" -le 30 ]
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

for w in $workers; do
    check "$w has $w-data.qcow2 as vdb in its inactive definition" \
        [ "$(on_nuc virsh domblklist --inactive "$w" | awk '$1 == "vdb" {print $2}')" = "$images/$w-data.qcow2" ]
done

declare -A lvs free
for w in $workers; do
    check "$w: /dev/vdb1 is in the LVM devices file" grep -Eq 'IDNAME=/dev/vdb1( |$)' <<< "$(on "$w" lvmdevices)"
    check "$w: the VG $vg has /dev/vdb1 as its only PV" \
        [ "$(on "$w" 'pvs --noheadings -o pv_name,vg_name' | awk -v vg="$vg" '$2 == vg {print $1}' | xargs)" = /dev/vdb1 ]
    free[$w]=$(on "$w" "vgs --noheadings --units b --nosuffix -o vg_free $vg" | xargs)
    lvs[$w]=$(on "$w" "lvs --noheadings --units g -o lv_name,lv_size,lv_attr $vg")
done

check "deployment/cert-manager is from chart $cm_chart" [ "$(chart deployment/cert-manager "$cm")" = "$cm_chart" ]
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    check "the rollout of deployment/$d is complete" rolled_out "deployment/$d" "$cm"
done
check "the six CRDs of cert-manager are installed" [ "$(kube get crd -o name | grep -c '\.cert-manager\.io$')" = 6 ]
check "the webhook of cert-manager accepts a self-signed Issuer (server-side dry run)" webhook_answers

check "deployment/topolvm-controller is from chart $topolvm_chart" \
    [ "$(chart deployment/topolvm-controller "$topolvm")" = "$topolvm_chart" ]
check "topolvm-controller runs 1 replica" \
    [ "$(kube get deployment topolvm-controller -n "$topolvm" -o jsonpath='{.spec.replicas}')" = 1 ]
check "the rollout of deployment/topolvm-controller is complete" rolled_out deployment/topolvm-controller "$topolvm"
for d in topolvm-lvmd-0 topolvm-node; do
    check "daemonset/$d is ready on 2 nodes, the workers" \
        [ "$(kube get daemonset "$d" -n "$topolvm" -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}')" = 2/2 ]
done
check "helm uninstall keeps the CRD logicalvolumes.topolvm.io" \
    [ "$(kube get crd logicalvolumes.topolvm.io -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}')" = keep ]

check "$sc is the only StorageClass" [ "$(kube get storageclass -o name)" = "storageclass.storage.k8s.io/$sc" ]
check "$sc is the default StorageClass" \
    [ "$(sc_field 'metadata.annotations.storageclass\.kubernetes\.io/is-default-class')" = true ]
check "$sc: topolvm.io, Delete, WaitForFirstConsumer, xfs" \
    [ "$(sc_field provisioner) $(sc_field reclaimPolicy) $(sc_field volumeBindingMode) $(sc_field 'parameters.csi\.storage\.k8s\.io/fstype')" = "topolvm.io Delete WaitForFirstConsumer xfs" ]
check "$sc allows volume expansion" [ "$(sc_field allowVolumeExpansion)" = true ]

capacity=$(kube get csistoragecapacities -A -o jsonpath='{range .items[*]}{.storageClassName} {.nodeTopology.matchLabels} {.capacity}{"\n"}{end}')
for w in $workers; do
    seen=$(awk -v sc="$sc" -v w="$w" '$1 == sc && index($2, w) {print $3}' <<< "$capacity")
    check "$w: the capacity of $sc (${seen:-none}) is the free space of VG $vg" is_bytes "$seen" "${free[$w]}"
done

check "the app writer matches $manifests/" matches_repo
check "the rollout of statefulset/writer is complete" rolled_out statefulset/writer "$ns"
check "writer-0 and writer-1 run on different nodes" \
    [ "$(kube get pods -n "$ns" -l app=writer -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)" = 2 ]

volumes=$(kube get pv -o jsonpath='{range .items[?(@.spec.csi.driver=="topolvm.io")]}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]} {.spec.csi.volumeHandle}{"\n"}{end}')
for i in 0 1; do
    claim=data-writer-$i
    size=${sizes[$i]}
    pv=$(kube get pvc "$claim" -n "$ns" -o jsonpath='{.spec.volumeName}')
    node=$(kube get pv "${pv:-none}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
    handle=$(kube get pv "${pv:-none}" -o jsonpath='{.spec.csi.volumeHandle}')
    check "$claim is Bound, $size asked and $size in its status" \
        [ "$(kube get pvc "$claim" -n "$ns" -o jsonpath='{.status.phase} {.spec.resources.requests.storage} {.status.capacity.storage}')" = "Bound $size $size" ]
    check "writer-$i runs on ${node:-no node}, the node of its volume" \
        [ "$(kube get pod "writer-$i" -n "$ns" -o jsonpath='{.spec.nodeName}')" = "${node:-no node}" ]
    check "$claim: its LV on ${node:-no node} is ${size%Gi}.00g, active and open" \
        [ "$(awk -v lv="${handle:-none}" '$1 == lv {print $2, $3}' <<< "${lvs[${node:-none}]}")" = "${size%Gi}.00g -wi-ao----" ]
done
for w in $workers; do
    check "$w: VG $vg holds only the LVs of the TopoLVM volumes on $w" only_volumes "$w"
done

check "writer-0 has an xfs of $grown_df on /data" \
    [ "$(kube exec writer-0 -n "$ns" -- df -h --output=fstype,size /data | tail -n 1 | xargs)" = "xfs $grown_df" ]
check "the first line of /data/log.txt in writer-0 is $marker" \
    [ "$(kube exec writer-0 -n "$ns" -- head -n 1 /data/log.txt)" = "$marker" ]
for i in 0 1; do
    check "writer-$i wrote a line to /data/log.txt in the last 30 seconds" recent "writer-$i"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
