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

hosts="k8s1 k8s2 k8s3"
packages="cri-o-1.36.9 kubelet-1.36.7 kubeadm-1.36.7 kubectl-1.36.7 cri-tools-1.36.0 kubernetes-cni-1.9.1"
locked="cri-o-1.36.9 kubelet-1.36.7 kubeadm-1.36.7 kubectl-1.36.7"
exclude="exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni"
pause=registry.k8s.io/pause:3.10.2
control_ports="10250/tcp 10257/tcp 10259/tcp 2379-2380/tcp 4789/udp 5473/tcp 6443/tcp 7946/tcp 7946/udp"
worker_ports="10250/tcp 30000-32767/tcp 4789/udp 5473/tcp 7946/tcp 7946/udp"
pod_network=10.244.0.0/16
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

sorted() {
    tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | xargs
}

no_swap_args() {
    [ -n "$1" ] &&
        [ "$(grep -c 'rd\.lvm\.lv=rhel/root' <<< "$1")" -eq "$(grep -c . <<< "$1")" ] &&
        ! grep -Eq 'resume=|rd\.lvm\.lv=rhel/swap' <<< "$1"
}

for h in $hosts; do
    if [ "$h" = k8s1 ]; then
        ports=$control_ports
    else
        ports=$worker_ports
    fi

    check "$h: the hostname is $h" [ "$(on "$h" 'hostname -s')" = "$h" ]

    check "$h: no swap is active" [ -z "$(on "$h" 'swapon --show --noheadings')" ]
    fstab=$(on "$h" 'cat /etc/fstab')
    check "$h: /etc/fstab mounts /" grep -Eq '^[^#]\S*\s+/\s' <<< "$fstab"
    check "$h: /etc/fstab mounts no swap" [ -z "$(grep -E '^[^#]\S*\s+\S+\s+swap\s' <<< "$fstab")" ]
    check "$h: VG rhel holds only the LV root" [ "$(on "$h" 'lvs --noheadings -o lv_name rhel' | xargs)" = root ]

    check "$h: this boot has no swap arguments" no_swap_args "$(on "$h" 'cat /proc/cmdline')"
    check "$h: no boot entry has swap arguments" no_swap_args "$(on "$h" 'grubby --info=ALL' | grep '^args=')"
    check "$h: /etc/kernel/cmdline has no swap arguments" no_swap_args "$(on "$h" 'cat /etc/kernel/cmdline')"
    check "$h: GRUB_CMDLINE_LINUX has no swap arguments" no_swap_args "$(on "$h" 'cat /etc/default/grub' | grep '^GRUB_CMDLINE_LINUX=')"

    check "$h: net.ipv4.ip_forward is 1" [ "$(on "$h" 'sysctl -n net.ipv4.ip_forward')" = 1 ]
    check "$h: /etc/sysctl.d/k8s.conf sets net.ipv4.ip_forward = 1" grep -qx 'net.ipv4.ip_forward = 1' <<< "$(on "$h" 'cat /etc/sysctl.d/k8s.conf')"

    installed=$(on "$h" "rpm -q $packages")
    for p in $packages; do
        check "$h: $p is installed" grep -q "^$p-" <<< "$installed"
    done
    locks=$(on "$h" 'cat /etc/dnf/plugins/versionlock.list')
    for p in $locked; do
        check "$h: dnf versionlock holds $p" grep -q "^${p%-*}-0:${p##*-}-" <<< "$locks"
    done
    check "$h: kubernetes.repo hides its packages from dnf upgrade" grep -qx "$exclude" <<< "$(on "$h" 'cat /etc/yum.repos.d/kubernetes.repo')"

    check "$h: crio is enabled" [ "$(on "$h" 'systemctl is-enabled crio')" = enabled ]
    check "$h: crio is active" [ "$(on "$h" 'systemctl is-active crio')" = active ]
    check "$h: CRI-O uses the pause image $pause" grep -Eq "^\s*pause_image = \"$pause\"" <<< "$(on "$h" 'crio status config')"
    check "$h: kubelet is enabled" [ "$(on "$h" 'systemctl is-enabled kubelet')" = enabled ]

    check "$h: SELinux is enforcing" [ "$(on "$h" getenforce)" = Enforcing ]
    check "$h: firewall allows $ports" [ "$(on "$h" 'firewall-cmd --list-ports' | sorted)" = "$ports" ]
    check "$h: firewall trusts $pod_network" [ "$(on "$h" 'firewall-cmd --zone=trusted --list-sources')" = "$pod_network" ]
done

recap=$(ansible-playbook playbooks/base.yml --check --limit k8s "${opts[@]}" 2>/dev/null)
for h in $hosts; do
    check "$h matches playbooks/base.yml (changed=0)" grep -Eq "^$h +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " <<< "$recap"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
