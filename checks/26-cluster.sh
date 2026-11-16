#!/usr/bin/env bash
# Lesson 26 checks: the cluster that kubeadm built from kubernetes/kubeadm/config.yaml, with Calico.
# Reads the cluster with kubectl through the tunnel, and the three nodes with read-only commands
# sent through Ansible as root: the API server answers at 127.0.0.1:6443 with the desktop
# kubeconfig (mode 600), three nodes Ready at v1.36.6 on CRI-O 1.36.8 with k8s1 as the only
# control plane, the static pods of k8s1 and their manifests, the values of the kubeadm config
# in the cluster, 127.0.0.1 in the certificate of the API server, kube-proxy in nftables mode,
# Calico v3.33.1 available with the pool and data plane of kubernetes/calico/custom-resources.yaml,
# no bootstrap token left, kubelet active on every node with the nftables tables of kube-proxy
# and Calico, and the five files of kubernetes/nodes/ equal to the files on every node.
# Check 25 covers the packages, swap, CRI-O, kubelet enabled and the firewall.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible)
# and the tunnel open in a second terminal (ssh -N -L 6443:192.168.122.21:6443 nuc):
#   bash checks/26-cluster.sh
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

hosts="k8s1 k8s2 k8s3"
server=https://127.0.0.1:6443
# kubernetesVersion and podSubnet in kubernetes/kubeadm/config.yaml
version=v1.36.6
pod_network=10.244.0.0/16
runtime=cri-o://1.36.8
static_pods="etcd kube-apiserver kube-controller-manager kube-scheduler"
apiserver_cert=/etc/kubernetes/pki/apiserver.crt
calico=v3.33.1
tigera="apiserver calico ippools tiers"
# The files of kubernetes/nodes/, at the same path on every node
node_files="/etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/cri-o.repo /etc/sysctl.d/k8s.conf
/etc/crio/crio.conf.d/20-pause-image.conf /etc/NetworkManager/conf.d/calico.conf"
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# Run kubectl with the desktop kubeconfig and print only its output.
kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

# The Ready condition of a node or a pod
ready() {
    kube get "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# Two or more pod addresses, all in 10.244.0.0/16
in_pod_network() {
    [ "$(wc -w <<< "$1")" -ge 2 ] && ! tr ' ' '\n' <<< "$1" | grep -vq '^10\.244\.'
}

# The API server through the tunnel, with the desktop kubeconfig
check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi
check "the kubeconfig points at $server" [ "$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')" = "$server" ]
check "~/.kube/config on the desktop has mode 600" [ "$(stat -c %a "$HOME/.kube/config")" = 600 ]
check "the API server runs $version" grep -Eq "\"gitVersion\": *\"$version\"" <<< "$(kube get --raw /version)"

# Nodes: three, Ready, with k8s1 the only control plane
check "the cluster has the nodes k8s1, k8s2 and k8s3" [ "$(kube get nodes -o name | xargs)" = "node/k8s1 node/k8s2 node/k8s3" ]
check "k8s1 is the only control plane" [ "$(kube get nodes -l node-role.kubernetes.io/control-plane -o name)" = node/k8s1 ]
check "k8s1 has only the control-plane taint" [ "$(kube get node k8s1 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect} {end}' | xargs)" = node-role.kubernetes.io/control-plane:NoSchedule ]
for h in $hosts; do
    check "$h is Ready" [ "$(ready node "$h")" = True ]
    check "$h runs kubelet $version" [ "$(kube get node "$h" -o jsonpath='{.status.nodeInfo.kubeletVersion}')" = "$version" ]
    check "$h runs $runtime" [ "$(kube get node "$h" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')" = "$runtime" ]
done

# Control plane: the static pods of k8s1 run from the manifests kubeadm wrote
manifests=$(on k8s1 'ls /etc/kubernetes/manifests')
for p in $static_pods; do
    check "k8s1: /etc/kubernetes/manifests/$p.yaml exists" grep -qx "$p.yaml" <<< "$manifests"
    check "$p-k8s1 is Ready" [ "$(ready pod -n kube-system "$p-k8s1")" = True ]
done
check "k8s1: ~/.kube/config of makilele has mode 600" [ "$(on k8s1 'stat -c %a /home/makilele/.kube/config')" = 600 ]

# The kubeadm config as the cluster keeps it
cluster_config=$(kube get configmap -n kube-system kubeadm-config -o jsonpath='{.data.ClusterConfiguration}')
check "kubeadm-config has kubernetesVersion $version" grep -qx "kubernetesVersion: $version" <<< "$cluster_config"
check "kubeadm-config has podSubnet $pod_network" grep -Eqx "\s*podSubnet: $pod_network" <<< "$cluster_config"

# The certificate of the API server: 127.0.0.1 for the tunnel, and 30 more days
sans=$(on k8s1 "openssl x509 -noout -ext subjectAltName -in $apiserver_cert")
check "the API server certificate holds 127.0.0.1" grep -Eq 'IP Address:127\.0\.0\.1(,|$)' <<< "$sans"
check "the API server certificate holds 192.168.122.21" grep -Eq 'IP Address:192\.168\.122\.21(,|$)' <<< "$sans"
check "the API server certificate is valid for 30 more days" [ "$(on k8s1 "openssl x509 -noout -checkend 2592000 -in $apiserver_cert")" = "Certificate will not expire" ]

# kube-proxy in nftables mode on every node, and CoreDNS
check "kube-proxy runs in nftables mode" grep -qx 'mode: nftables' <<< "$(kube get configmap -n kube-system kube-proxy -o jsonpath='{.data.config\.conf}')"
check "kube-proxy is ready on 3 nodes" [ "$(kube get daemonset -n kube-system kube-proxy -o jsonpath='{.status.numberReady}')" = 3 ]
check "coredns has 2 ready replicas" [ "$(kube get deployment -n kube-system coredns -o jsonpath='{.status.readyReplicas}')" = 2 ]
check "the coredns pods have addresses in $pod_network" in_pod_network "$(kube get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}')"

# Calico: the operator's Installation, its status and the pool
check "Calico runs $calico" [ "$(kube get installation default -o jsonpath='{.status.calicoVersion}')" = "$calico" ]
for t in $tigera; do
    check "tigerastatus $t is Available" [ "$(kube get tigerastatus "$t" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = True ]
done
check "Calico uses the nftables data plane without BGP" [ "$(kube get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane} {.spec.calicoNetwork.bgp}')" = "Nftables Disabled" ]
check "the pool default-ipv4-ippool is $pod_network with VXLAN and NAT" [ "$(kube get ippools.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr} {.spec.vxlanMode} {.spec.ipipMode} {.spec.natOutgoing}')" = "$pod_network Always Never true" ]
check "calico-node is ready on 3 nodes" [ "$(kube get daemonset -n calico-system calico-node -o jsonpath='{.status.numberReady}')" = 3 ]

# The join tokens were deleted after the joins
check "no bootstrap token is left" [ -z "$(kube get secrets -n kube-system --field-selector type=bootstrap.kubernetes.io/token -o name)" ]

# Every node: kubelet, the nftables tables, the CNI config and the files of kubernetes/nodes/
for h in $hosts; do
    check "$h: kubelet is active" [ "$(on "$h" 'systemctl is-active kubelet')" = active ]
    tables=$(on "$h" 'nft list tables')
    check "$h: kube-proxy has its nftables table" grep -qx 'table ip kube-proxy' <<< "$tables"
    check "$h: Calico has its nftables table" grep -qx 'table ip calico' <<< "$tables"
    check "$h: /etc/cni/net.d has the Calico config" grep -qx 10-calico.conflist <<< "$(on "$h" 'ls /etc/cni/net.d')"
    sums=$(on "$h" "sha256sum $(xargs <<< "$node_files")")
    for f in $node_files; do
        repo_sum=$(sha256sum "../kubernetes/nodes$f" 2>/dev/null | cut -d' ' -f1)
        check "$h: $f matches kubernetes/nodes$f" grep -qx "${repo_sum:-no file in the repo}  $f" <<< "$sums"
    done
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
