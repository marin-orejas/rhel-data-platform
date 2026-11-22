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
svc=web
client=client
manifests=kubernetes/apps/client
short=$svc.$ns
fqdn=$short.svc.cluster.local
tester=check-29

cd "$(dirname "$0")/.." || exit 1

image=$(awk '$1 == "image:" {print $2}' "$manifests/deployment.yaml")
page=$(cat kubernetes/apps/web/index.html)

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

service() {
    kube get service "$svc" -n "$ns" -o jsonpath="{.spec.$1}"
}

slices() {
    kube get endpointslices -n "$ns" -l kubernetes.io/service-name="$svc" \
        -o jsonpath="{range .items[*].$1}{$2}{\"\n\"}{end}"
}

rolled_out() {
    kube rollout status deployment/"$client" -n "$client" --timeout=10s >/dev/null
}

matches_repo() {
    kube diff -k "$manifests" >/dev/null
}

from_client() {
    kube exec deploy/"$client" -n "$client" -- "$@"
}

timed_out() {
    kubectl delete pod "$tester" -n "$1" --ignore-not-found >/dev/null 2>&1
    kubectl run "$tester" -n "$1" --labels="$2" --image="$image" --restart=Never --rm -i \
        --command -- curl -s -o /dev/null --max-time 5 "http://$short" </dev/null >/dev/null 2>&1
    local rc=$?
    kubectl delete pod "$tester" -n "$1" --ignore-not-found >/dev/null 2>&1
    [ "$rc" -eq 28 ]
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

ip=$(service clusterIP)
check "the Service $svc is of type ClusterIP (${ip:-none})" [ "$(service type)" = ClusterIP ]
check "$svc selects the Pods with app=$app" [ "$(service selector.app)" = "$app" ]
check "$svc takes port 80 to the named port http" \
    [ "$(service 'ports[?(@.name=="http")].port')/$(service 'ports[?(@.name=="http")].targetPort')" = 80/http ]

replicas=$(kube get deployment "$app" -n "$ns" -o jsonpath='{.spec.replicas}')
port=$(kube get deployment "$app" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="http")].containerPort}')
check "$svc has one ready endpoint per replica (${replicas:-none})" \
    [ "$(slices 'endpoints[*]' .conditions.ready | grep -cx true)" = "${replicas:-none}" ]
check "the endpoints take port http on $port, the containerPort of httpd" \
    [ "$(slices 'ports[?(@.name=="http")]' .port)" = "${port:-none}" ]

check "the live objects match $manifests/" matches_repo
check "the rollout of deployment/$client is complete" rolled_out

check "the client resolves $fqdn to the ClusterIP" \
    [ "$(from_client getent hosts "$fqdn" | awk '{print $1}')" = "${ip:-none}" ]
check "the client gets index.html of the repo from http://$short" \
    [ "$(from_client curl -sf --max-time 5 "http://$short")" = "$page" ]

check "$ns has the NetworkPolicies allow-client, allow-gateway and default-deny-ingress" \
    [ "$(kube get networkpolicies.networking.k8s.io -n "$ns" -o jsonpath='{.items[*].metadata.name}')" = "allow-client allow-gateway default-deny-ingress" ]
check "a Pod in $client without app=$client gets no answer (curl exit 28)" timed_out "$client" app=tester
check "a Pod with app=$client in default gets no answer (curl exit 28)" timed_out default app="$client"

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
