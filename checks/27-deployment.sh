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
ns=web
app=web
manifests=kubernetes/apps/web
workers="k8s2 k8s3"

cd "$(dirname "$0")/.." || exit 1

image=$(awk '$1 == "image:" {print $2}' "$manifests/deployment.yaml")

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

ready() {
    kube get "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

container() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.containers[0].$1}"
}

cpu_and_memory() {
    [ -n "$(container "resources.$1.cpu")" ] && [ -n "$(container "resources.$1.memory")" ]
}

rolled_out() {
    kube rollout status deployment/"$app" -n "$ns" --timeout=10s >/dev/null
}

matches_repo() {
    kube diff -k "$manifests" >/dev/null
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

check "the namespace $ns is Active" [ "$(kube get namespace "$ns" -o jsonpath='{.status.phase}')" = Active ]
check "the rollout of deployment/$app is complete" rolled_out
check "the live objects match $manifests/" matches_repo

check "httpd has a readiness probe" [ -n "$(container readinessProbe)" ]
check "httpd has a liveness probe" [ -n "$(container livenessProbe)" ]
check "httpd has CPU and memory requests" cpu_and_memory requests
check "httpd has CPU and memory limits" cpu_and_memory limits

for pod in $(kube get pods -n "$ns" -l app="$app" -o name); do
    name=${pod#pod/}
    node=$(kube get "$pod" -n "$ns" -o jsonpath='{.spec.nodeName}')
    check "$name is Ready" [ "$(ready "$pod" -n "$ns")" = True ]
    check "$name runs on a worker ($node)" grep -qw "${node:-no node}" <<< "$workers"
    check "$name runs $image" [ "$(kube get "$pod" -n "$ns" -o jsonpath='{.spec.containers[0].image}')" = "$image" ]
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
