#!/usr/bin/env bash
# Lesson 30 checks: traffic from outside the cluster, from nuc through MetalLB and Traefik to web.
# Reads the cluster with kubectl through the tunnel: MetalLB from chart metallb-0.16.2 (the
# controller, a ready speaker on every node, no FRR-K8s, the pool and the L2Advertisement of
# kubernetes/metallb/ by kubectl diff -k), the Gateway API CRDs of the standard channel v1.6.3,
# Traefik from chart traefik-42.4.1 (the Service traefik of type LoadBalancer on 192.168.122.200,
# asked for by annotation, port 80 only), the GatewayClass traefik, the Gateway traefik-gateway
# (Programmed on .200, routes only from the namespace web, one attached) and the HTTPRoute web.
# Over ssh on nuc, which is on the lab network: the page of the repo at http://192.168.122.200/,
# and the MAC that answers for the address, which must be a worker's, because kubeadm keeps k8s1
# out of external load balancers.
# A Pod of a few seconds in the namespace traefik without the Traefik label shows that
# allow-gateway needs both: it runs curl against web, must end in a timeout (curl exit 28) and is
# deleted again, also when the check fails.
# CoreDNS runs on k8s1, so after a reboot run the checks once coredns is ready again.
# Check 27 compares kubernetes/apps/web/ with kubectl diff -k, the HTTPRoute and allow-gateway included.
# Run on the desktop from the repo root, with the tunnel open in a second terminal
# (ssh -N -L 6443:192.168.122.21:6443 nuc):
#   bash checks/30-outside.sh
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
# The address of the Gateway, from the MetalLB pool .200-.209
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
# The temporary Pod of the policy test
tester=check-30

# The manifests are read from the repo root
cd "$(dirname "$0")/.." || exit 1

# The image of the client, already on the workers, and the page in index.html
image=$(awk '$1 == "image:" {print $2}' kubernetes/apps/client/deployment.yaml)
page=$(cat kubernetes/apps/web/index.html)

# Run kubectl with the desktop kubeconfig and print only its output.
kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

# kubectl rollout status of $1 in namespace $2: every replica updated and available
rolled_out() {
    kube rollout status "$1" -n "$2" --timeout=10s >/dev/null
}

# The label helm.sh/chart of $1 in namespace $2: the chart and version Helm installed it from
chart() {
    kube get "$1" -n "$2" -o jsonpath='{.metadata.labels.helm\.sh/chart}'
}

# kubectl diff -k exits 0 only when the live objects equal what Kustomize builds from the files
matches_repo() {
    kube diff -k "$manifests" >/dev/null
}

# A field of the Service traefik
service() {
    kube get service "$traefik" -n "$traefik" -o jsonpath="{.$1}"
}

# A field of the Gateway
gateway() {
    kube get "gateways.$gw" "$gateway" -n "$traefik" -o jsonpath="{.$1}"
}

# The status of condition $1 of the HTTPRoute web, as Traefik sets it for the Gateway
route() {
    kube get "httproutes.$gw" web -n "$ns" \
        -o jsonpath="{.status.parents[?(@.parentRef.name==\"$gateway\")].conditions[?(@.type==\"$1\")].status}"
}

# A command on nuc, which is on the lab network: the desktop has no route to 192.168.122.0/24.
# -n gives ssh /dev/null as stdin, so it does not read the terminal.
on_nuc() {
    ssh -n nuc "$*" 2>/dev/null
}

# A Pod in traefik without the label app.kubernetes.io/name=traefik tries web for 5 seconds.
# kubectl run --rm -i returns the exit code of curl and deletes the Pod; the deletes before and
# after remove a Pod that an earlier or a failed run left behind. stdin comes from /dev/null, so
# kubectl does not read the terminal.
timed_out() {
    kubectl delete pod "$tester" -n "$traefik" --ignore-not-found >/dev/null 2>&1
    kubectl run "$tester" -n "$traefik" --labels=app=tester --image="$image" --restart=Never --rm -i \
        --command -- curl -s -o /dev/null --max-time 5 "http://web.$ns" </dev/null >/dev/null 2>&1
    local rc=$?
    kubectl delete pod "$tester" -n "$traefik" --ignore-not-found >/dev/null 2>&1
    [ "$rc" -eq 28 ]
}

# The API server through the tunnel
check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

# MetalLB: the controller hands out the addresses, a speaker on each node announces them
nodes=$(kube get nodes -o name | wc -l)
check "deployment/metallb-controller is from chart $metallb_chart" \
    [ "$(chart deployment/metallb-controller "$metallb")" = "$metallb_chart" ]
check "the rollout of deployment/metallb-controller is complete" rolled_out deployment/metallb-controller "$metallb"
check "a speaker is ready on each of the $nodes nodes" \
    [ "$(kube get daemonset metallb-speaker -n "$metallb" -o jsonpath='{.status.numberReady}')" = "$nodes" ]
check "$metallb has no DaemonSet but metallb-speaker (no FRR-K8s)" \
    [ "$(kube get daemonsets -n "$metallb" -o jsonpath='{.items[*].metadata.name}')" = metallb-speaker ]
check "the pool and the L2Advertisement match $manifests/" matches_repo

# Gateway API: the CRDs of the standard channel that Traefik 3.7 supports
check "the Gateway API CRDs are the standard channel $gateway_api" \
    [ "$(kube get crd "httproutes.$gw" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}/{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')" = "$gateway_api/standard" ]

# Traefik: the Gateway controller, behind the Service that MetalLB gives the address
check "deployment/traefik is from chart $traefik_chart" [ "$(chart deployment/traefik "$traefik")" = "$traefik_chart" ]
check "the rollout of deployment/traefik is complete" rolled_out deployment/traefik "$traefik"
check "the Service traefik is of type LoadBalancer on $lb" \
    [ "$(service spec.type)/$(service 'status.loadBalancer.ingress[0].ip')" = "LoadBalancer/$lb" ]
check "traefik asks MetalLB for $lb by annotation" \
    [ "$(service 'metadata.annotations.metallb\.io/loadBalancerIPs')" = "$lb" ]
check "traefik takes port 80 only (websecure not exposed)" [ "$(service 'spec.ports[*].port')" = 80 ]

# The GatewayClass and the Gateway: Traefik accepts the class and serves the listener web on .200
from=$(gateway 'spec.listeners[?(@.name=="web")].allowedRoutes.namespaces.from')
selected=$(gateway 'spec.listeners[?(@.name=="web")].allowedRoutes.namespaces.selector.matchLabels.kubernetes\.io/metadata\.name')
check "the GatewayClass traefik is Accepted" \
    [ "$(kube get "gatewayclasses.$gw" traefik -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" = True ]
check "the Gateway $gateway is Programmed on $lb" \
    [ "$(gateway 'status.conditions[?(@.type=="Programmed")].status')/$(gateway 'status.addresses[0].value')" = "True/$lb" ]
check "the listener web takes routes only from the namespace $ns" [ "$from/$selected" = "Selector/$ns" ]
check "one route is attached to the listener web" \
    [ "$(gateway 'status.listeners[?(@.name=="web")].attachedRoutes')" = 1 ]

# The HTTPRoute web: accepted on the Gateway, and the Service web found behind it
check "the HTTPRoute web is Accepted by $gateway and its backend resolved" \
    [ "$(route Accepted)/$(route ResolvedRefs)" = True/True ]

# From nuc: the page through MetalLB, Traefik, the route and allow-gateway
check "nuc gets index.html of the repo from http://$lb/" \
    [ "$(on_nuc curl -sf --max-time 5 "http://$lb/")" = "$page" ]

# The MAC that answers ARP for the address on nuc: the speaker of the announcing worker
mac=$(on_nuc ip neigh show "$lb" | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1)}')
case $mac in
    52:54:00:00:00:22) announcer=k8s2 ;;
    52:54:00:00:00:23) announcer=k8s3 ;;
    *) announcer= ;;
esac
check "a worker announces $lb to nuc (${announcer:-no worker} at ${mac:-no MAC})" [ -n "$announcer" ]

# allow-gateway: the namespace traefik alone is not enough, the Pod needs the Traefik label too
check "a Pod in $traefik without the Traefik label gets no answer (curl exit 28)" timed_out

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
