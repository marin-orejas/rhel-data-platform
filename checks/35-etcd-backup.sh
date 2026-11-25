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
host=k8s1
version=3.6.8
bin=/usr/local/bin
dest=/srv/etcd-backup
keep=7
data=/var/lib/etcd
unit=etcd-snapshot
repo_files="/usr/local/bin/etcd-snapshot.sh /etc/systemd/system/etcd-snapshot.service /etc/systemd/system/etcd-snapshot.timer"
bumped=1000810432
test_ns=etcd-test
ns=pg
cluster=pg
record="2372|1|2372"
pki=/etc/kubernetes/pki/etcd
etcdctl="$bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$pki/ca.crt --cert=$pki/healthcheck-client.crt --key=$pki/healthcheck-client.key"
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

sql() {
    kube exec "$1" -n "$ns" -c postgres -- psql -d "$2" -XAtc "$3"
}

field() {
    grep -o "\"$1\":[^,}]*" <<< "$2" | head -n 1 | cut -d: -f2 | tr -d '"'
}

kept() {
    [ "$count" -ge 1 ] && [ "$count" -le "$keep" ]
}

valid() {
    [ "${snap_rev:-0}" -gt 0 ] && [ "${snap_keys:-0}" -gt 0 ]
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

stats=$(on "$host" "stat -c '%n %a %U %C' $bin/etcdctl $bin/etcdutl $bin/etcd-snapshot.sh $data $data/member $dest")
for t in etcdctl etcdutl; do
    check "$host: $bin/$t is $version" grep -qx "$t version: $version" <<< "$(on "$host" "$bin/$t version")"
done
for t in etcdctl etcdutl etcd-snapshot.sh; do
    check "$host: $bin/$t has mode 755, owner root and the type bin_t" grep -Eqx "$bin/$t 755 root [a-z_]+:object_r:bin_t:s0" <<< "$stats"
done

status=$(on "$host" "$etcdctl endpoint status -w json")
rev=$(field revision "$status")
check "$host: etcd is healthy through the healthcheck-client certificate" grep -q 'is healthy' <<< "$(on "$host" "$etcdctl endpoint health")"
check "$host: the etcd server runs $version, the same as the tools" [ "$(field version "$status")" = "$version" ]
check "$host: etcd runs on the restored data, revision ${rev:-none} above $bumped" [ "${rev:-0}" -gt "$bumped" ]
for d in $data $data/member; do
    check "$host: $d has mode 700, owner root and the type var_lib_t" grep -Eqx "$d 700 root [a-z_]+:object_r:var_lib_t:s0" <<< "$stats"
done

sums=$(on "$host" "sha256sum $repo_files")
for f in $repo_files; do
    repo_sum=$(sha256sum "../kubernetes/etcd$f" 2>/dev/null | cut -d' ' -f1)
    check "$host: $f matches kubernetes/etcd$f" grep -qx "${repo_sum:-no file in the repo}  $f" <<< "$sums"
done
timer=$(on "$host" "systemctl show $unit.timer -p UnitFileState -p ActiveState -p Persistent -p TimersCalendar -p NeedDaemonReload")
service=$(on "$host" "systemctl show $unit.service -p Result -p NeedDaemonReload")
check "$host: $unit.timer is enabled" grep -qx 'UnitFileState=enabled' <<< "$timer"
check "$host: $unit.timer is active" grep -qx 'ActiveState=active' <<< "$timer"
check "$host: $unit.timer runs at 01:00 UTC" grep -q 'OnCalendar=\*-\*-\* 01:00:00 UTC ;' <<< "$timer"
check "$host: $unit.timer catches up a missed run (Persistent=yes)" grep -qx 'Persistent=yes' <<< "$timer"
check "$host: systemd runs $unit.timer as it is on disk" grep -qx 'NeedDaemonReload=no' <<< "$timer"
check "$host: systemd runs $unit.service as it is on disk" grep -qx 'NeedDaemonReload=no' <<< "$service"
check "$host: the last run of $unit.service succeeded" grep -qx 'Result=success' <<< "$service"

files=$(on "$host" "ls $dest")
snaps=$(grep -Ex 'etcd-[0-9]{8}T[0-9]{6}Z\.db' <<< "$files")
count=$(grep -c . <<< "$snaps")
newest=$(tail -n 1 <<< "$snaps")
newest=${newest:-none}
snap=$(on "$host" "$bin/etcdutl snapshot status $dest/$newest -w json")
snap_rev=$(field revision "$snap")
snap_keys=$(field totalKey "$snap")
check "$host: $dest has mode 700 and owner root" grep -Eqx "$dest 700 root .*" <<< "$stats"
check "$host: $dest keeps 1 to $keep snapshots (now $count)" kept
check "$host: no unfinished snapshot (.tmp or .part) is left in $dest" [ -z "$(grep -E '\.(tmp|part)$' <<< "$files")" ]
check "$host: the newest snapshot $newest has mode 600 and owner root" [ "$(on "$host" "stat -c '%a %U' $dest/$newest")" = "600 root" ]
check "$host: etcdutl reads $newest as a valid snapshot (revision ${snap_rev:-none}, ${snap_keys:-no} keys)" valid

primary=$(kube get cluster "$cluster" -n "$ns" -o jsonpath='{.status.currentPrimary}')
[ -n "$primary" ] || primary=none
check "the namespace $test_ns, deleted after the snapshot and brought back by the restore, is Active" \
    [ "$(kube get namespace "$test_ns" -o jsonpath='{.status.phase}')" = Active ]
check "deployment/$test_ns in $test_ns has 2 ready replicas" \
    [ "$(kube get deployment "$test_ns" -n "$test_ns" -o jsonpath='{.status.readyReplicas}')" = 2 ]
check "configmap/$test_ns in $test_ns holds lesson=35" \
    [ "$(kube get configmap "$test_ns" -n "$test_ns" -o jsonpath='{.data.lesson}')" = 35 ]
check "etcd_restore_test keeps the rows the client wrote through the restore: 2372, ids 1 to 2372" \
    [ "$(sql "$primary" app 'SELECT count(*), min(id), max(id) FROM etcd_restore_test')" = "$record" ]
check "etcd_restore_test belongs to app" \
    [ "$(sql "$primary" app "SELECT tableowner FROM pg_tables WHERE tablename = 'etcd_restore_test'")" = app ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
