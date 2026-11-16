#!/usr/bin/env bash
# Lesson 27 checks: the Deployment web from kubernetes/apps/web/.
# Reads the cluster with kubectl through the tunnel: the namespace web, a complete rollout of the
# Deployment web, no difference between the live objects and the files (kubectl diff), a readiness
# and a liveness probe and CPU and memory requests and limits on its container httpd, and every
# Pod of web Ready on a worker with the image of deployment.yaml.
# The Pods are checked for Ready, not for 0 restarts: a reboot of a node restarts every container
# on it and raises its restart count.
# On a fresh cluster apply namespace.yaml first: kubectl apply -f on the folder reads
# deployment.yaml before namespace.yaml.
# Run on the desktop from the repo root, with the tunnel open in a second terminal
# (ssh -N -L 6443:192.168.122.21:6443 nuc):
#   bash checks/27-deployment.sh
# Run it after a reboot of the three nodes.

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
# k8s1 has the control-plane taint, so a Pod of web runs only here
workers="k8s2 k8s3"

# The manifests are read from the repo root
cd "$(dirname "$0")/.." || exit 1

# The image in deployment.yaml
image=$(awk '$1 == "image:" {print $2}' "$manifests/deployment.yaml")

# Run kubectl with the desktop kubeconfig and print only its output.
kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

# The Ready condition of a pod
ready() {
    kube get "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# A field of httpd, the one container in the Pod template of the Deployment
container() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.containers[0].$1}"
}

# A CPU and a memory value in the requests or the limits of httpd
cpu_and_memory() {
    [ -n "$(container "resources.$1.cpu")" ] && [ -n "$(container "resources.$1.memory")" ]
}

# kubectl rollout status: every replica updated and available, no old Pod left
rolled_out() {
    kube rollout status deployment/"$app" -n "$ns" --timeout=10s >/dev/null
}

# kubectl diff exits 0 only when the live objects equal the files
matches_repo() {
    kube diff -f "$manifests" >/dev/null
}

# The API server through the tunnel
check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

# The namespace and the Deployment, as the files in the repo describe them
check "the namespace $ns is Active" [ "$(kube get namespace "$ns" -o jsonpath='{.status.phase}')" = Active ]
check "the rollout of deployment/$app is complete" rolled_out
check "the live objects match $manifests/" matches_repo

# Health checks and resource limits of httpd
check "httpd has a readiness probe" [ -n "$(container readinessProbe)" ]
check "httpd has a liveness probe" [ -n "$(container livenessProbe)" ]
check "httpd has CPU and memory requests" cpu_and_memory requests
check "httpd has CPU and memory limits" cpu_and_memory limits

# Every Pod of web: Ready, on a worker, with the image of deployment.yaml
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
