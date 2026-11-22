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
lb=192.168.122.200
metallb=metallb-system
metallb_chart=metallb-0.16.2
manifests=kubernetes/metallb
gw=gateway.networking.k8s.io
gateway_api=v1.6.3
traefik=traefik
traefik_chart=traefik-42.4.1
gateway=traefik-gateway
ns=web
tester=check-30

cd "$(dirname "$0")/.." || exit 1

image=$(awk '$1 == "image:" {print $2}' kubernetes/apps/client/deployment.yaml)
page=$(cat kubernetes/apps/web/index.html)

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
    kube diff -k "$manifests" >/dev/null
}

service() {
    kube get service "$traefik" -n "$traefik" -o jsonpath="{.$1}"
}

gateway() {
    kube get "gateways.$gw" "$gateway" -n "$traefik" -o jsonpath="{.$1}"
}

route() {
    kube get "httproutes.$gw" web -n "$ns" \
        -o jsonpath="{.status.parents[?(@.parentRef.name==\"$gateway\")].conditions[?(@.type==\"$1\")].status}"
}

on_nuc() {
    ssh -n nuc "$*" 2>/dev/null
}

timed_out() {
    kubectl delete pod "$tester" -n "$traefik" --ignore-not-found >/dev/null 2>&1
    kubectl run "$tester" -n "$traefik" --labels=app=tester --image="$image" --restart=Never --rm -i \
        --command -- curl -s -o /dev/null --max-time 5 "http://web.$ns" </dev/null >/dev/null 2>&1
    local rc=$?
    kubectl delete pod "$tester" -n "$traefik" --ignore-not-found >/dev/null 2>&1
    [ "$rc" -eq 28 ]
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

nodes=$(kube get nodes -o name | wc -l)
check "deployment/metallb-controller is from chart $metallb_chart" \
    [ "$(chart deployment/metallb-controller "$metallb")" = "$metallb_chart" ]
check "the rollout of deployment/metallb-controller is complete" rolled_out deployment/metallb-controller "$metallb"
check "a speaker is ready on each of the $nodes nodes" \
    [ "$(kube get daemonset metallb-speaker -n "$metallb" -o jsonpath='{.status.numberReady}')" = "$nodes" ]
check "$metallb has no DaemonSet but metallb-speaker (no FRR-K8s)" \
    [ "$(kube get daemonsets -n "$metallb" -o jsonpath='{.items[*].metadata.name}')" = metallb-speaker ]
check "the pool and the L2Advertisement match $manifests/" matches_repo

check "the Gateway API CRDs are the standard channel $gateway_api" \
    [ "$(kube get crd "httproutes.$gw" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}/{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')" = "$gateway_api/standard" ]

check "deployment/traefik is from chart $traefik_chart" [ "$(chart deployment/traefik "$traefik")" = "$traefik_chart" ]
check "the rollout of deployment/traefik is complete" rolled_out deployment/traefik "$traefik"
check "the Service traefik is of type LoadBalancer on $lb" \
    [ "$(service spec.type)/$(service 'status.loadBalancer.ingress[0].ip')" = "LoadBalancer/$lb" ]
check "traefik asks MetalLB for $lb by annotation" \
    [ "$(service 'metadata.annotations.metallb\.io/loadBalancerIPs')" = "$lb" ]
check "traefik takes port 80 only (websecure not exposed)" [ "$(service 'spec.ports[*].port')" = 80 ]

from=$(gateway 'spec.listeners[?(@.name=="web")].allowedRoutes.namespaces.from')
selected=$(gateway 'spec.listeners[?(@.name=="web")].allowedRoutes.namespaces.selector.matchLabels.kubernetes\.io/metadata\.name')
check "the GatewayClass traefik is Accepted" \
    [ "$(kube get "gatewayclasses.$gw" traefik -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" = True ]
check "the Gateway $gateway is Programmed on $lb" \
    [ "$(gateway 'status.conditions[?(@.type=="Programmed")].status')/$(gateway 'status.addresses[0].value')" = "True/$lb" ]
check "the listener web takes routes only from the namespace $ns" [ "$from/$selected" = "Selector/$ns" ]
check "one route is attached to the listener web" \
    [ "$(gateway 'status.listeners[?(@.name=="web")].attachedRoutes')" = 1 ]

check "the HTTPRoute web is Accepted by $gateway and its backend resolved" \
    [ "$(route Accepted)/$(route ResolvedRefs)" = True/True ]

check "nuc gets index.html of the repo from http://$lb/" \
    [ "$(on_nuc curl -sf --max-time 5 "http://$lb/")" = "$page" ]

mac=$(on_nuc ip neigh show "$lb" | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1)}')
case $mac in
    52:54:00:00:00:22) announcer=k8s2 ;;
    52:54:00:00:00:23) announcer=k8s3 ;;
    *) announcer= ;;
esac
check "a worker announces $lb to nuc (${announcer:-no worker} at ${mac:-no MAC})" [ -n "$announcer" ]

check "a Pod in $traefik without the Traefik label gets no answer (curl exit 28)" timed_out

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
