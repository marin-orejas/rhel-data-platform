#!/usr/bin/env bash
umask 077
set -o pipefail

export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

dest=/srv/etcd-backup
keep=7
file="$dest/etcd-$(date -u +%Y%m%dT%H%M%SZ).db"
tmp="$file.tmp"

if ! /usr/local/bin/etcdctl snapshot save "$tmp"; then
    echo "Error: snapshot failed" >&2
    rm -f "$tmp"
    exit 1
fi

if ! /usr/local/bin/etcdutl snapshot status "$tmp" -w table; then
    echo "Error: $tmp is not a valid snapshot" >&2
    rm -f "$tmp"
    exit 1
fi

mv "$tmp" "$file"
echo "Saved $file"

ls -1 "$dest"/etcd-*.db | head -n -"$keep" | xargs -r rm -v
