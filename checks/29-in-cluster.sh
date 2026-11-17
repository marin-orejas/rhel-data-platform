#!/usr/bin/env bash
# Lesson 29 checks: traffic inside the cluster, from the client to the Service web.
# Reads the cluster with kubectl through the tunnel: the Service web (ClusterIP, the selector
# app=web, port 80 to the named port http), its EndpointSlice with one ready endpoint per replica
# on the containerPort of httpd, the client of kubernetes/apps/client/ (kubectl diff -k and a
# complete rollout), the full DNS name of web resolved from the client to the ClusterIP, the page
# of the repo at http://web.web, and the NetworkPolicies default-deny-ingress and allow-client.
# Two Pods of a few seconds show the policy: one in client without app=client, one with app=client
# in default. Each runs curl against web and is deleted again, also when the check fails. A dropped
# connection ends in a timeout, curl exit 28; a refused one would be 7, a name that does not
# resolve 6, so only 28 passes.
# CoreDNS runs on k8s1, so after a reboot run the checks once coredns is ready again.
# Check 27 compares kubernetes/apps/web/ with kubectl diff -k, the policies included.
# Run on the desktop from the repo root, with the tunnel open in a second terminal
# (ssh -N -L 6443:192.168.122.21:6443 nuc):
#   bash checks/29-in-cluster.sh
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
svc=web
client=client
manifests=kubernetes/apps/client
# The name of the Service with its namespace, and the full name that CoreDNS serves.
# Not called name: check() has a local name, and timed_out runs inside check().
short=$svc.$ns
fqdn=$short.svc.cluster.local
# The temporary Pods of the policy test
tester=check-29

# The manifests are read from the repo root
cd "$(dirname "$0")/.." || exit 1

# The image of the client, already on the workers, and the page in index.html
image=$(awk '$1 == "image:" {print $2}' "$manifests/deployment.yaml")
page=$(cat kubernetes/apps/web/index.html)

# Run kubectl with the desktop kubeconfig and print only its output.
kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

# A field of the Service web
service() {
    kube get service "$svc" -n "$ns" -o jsonpath="{.spec.$1}"
}

# A field of every EndpointSlice of the Service web, one line per endpoint or port
slices() {
    kube get endpointslices -n "$ns" -l kubernetes.io/service-name="$svc" \
        -o jsonpath="{range .items[*].$1}{$2}{\"\n\"}{end}"
}

# kubectl rollout status: every replica updated and available, no old Pod left
rolled_out() {
    kube rollout status deployment/"$client" -n "$client" --timeout=10s >/dev/null
}

# kubectl diff -k exits 0 only when the live objects equal what Kustomize builds from the files
matches_repo() {
    kube diff -k "$manifests" >/dev/null
}

# A command in the client Pod
from_client() {
    kube exec deploy/"$client" -n "$client" -- "$@"
}

# A Pod in namespace $1 with label $2 tries web for 5 seconds. kubectl run --rm -i returns the
# exit code of curl and deletes the Pod; the deletes before and after remove a Pod that an earlier
# or a failed run left behind. stdin comes from /dev/null, so kubectl does not read the terminal.
timed_out() {
    kubectl delete pod "$tester" -n "$1" --ignore-not-found >/dev/null 2>&1
    kubectl run "$tester" -n "$1" --labels="$2" --image="$image" --restart=Never --rm -i \
        --command -- curl -s -o /dev/null --max-time 5 "http://$short" </dev/null >/dev/null 2>&1
    local rc=$?
    kubectl delete pod "$tester" -n "$1" --ignore-not-found >/dev/null 2>&1
    [ "$rc" -eq 28 ]
}

# The API server through the tunnel
check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

# The Service web: one fixed address for the Pods with app=web
ip=$(service clusterIP)
check "the Service $svc is of type ClusterIP (${ip:-none})" [ "$(service type)" = ClusterIP ]
check "$svc selects the Pods with app=$app" [ "$(service selector.app)" = "$app" ]
check "$svc takes port 80 to the named port http" \
    [ "$(service 'ports[?(@.name=="http")].port')/$(service 'ports[?(@.name=="http")].targetPort')" = 80/http ]

# The EndpointSlice: the Pods behind web, as kube-proxy sees them
replicas=$(kube get deployment "$app" -n "$ns" -o jsonpath='{.spec.replicas}')
port=$(kube get deployment "$app" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="http")].containerPort}')
check "$svc has one ready endpoint per replica (${replicas:-none})" \
    [ "$(slices 'endpoints[*]' .conditions.ready | grep -cx true)" = "${replicas:-none}" ]
check "the endpoints take port http on $port, the containerPort of httpd" \
    [ "$(slices 'ports[?(@.name=="http")]' .port)" = "${port:-none}" ]

# The client, as the files in the repo describe it
check "the live objects match $manifests/" matches_repo
check "the rollout of deployment/$client is complete" rolled_out

# The client finds web by its DNS name and gets the page
check "the client resolves $fqdn to the ClusterIP" \
    [ "$(from_client getent hosts "$fqdn" | awk '{print $1}')" = "${ip:-none}" ]
check "the client gets index.html of the repo from http://$short" \
    [ "$(from_client curl -sf --max-time 5 "http://$short")" = "$page" ]

# The policies: no Pod of web takes traffic, except from the client
check "$ns has the NetworkPolicies allow-client and default-deny-ingress" \
    [ "$(kube get networkpolicies.networking.k8s.io -n "$ns" -o jsonpath='{.items[*].metadata.name}')" = "allow-client default-deny-ingress" ]
check "a Pod in $client without app=$client gets no answer (curl exit 28)" timed_out "$client" app=tester
check "a Pod with app=$client in default gets no answer (curl exit 28)" timed_out default app="$client"

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
