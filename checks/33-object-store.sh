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

host=db2
client=k8s2
names="db2 192.168.122.12"
mount=/srv/garage
lv=/dev/objects/garage
mapper=/dev/mapper/objects-garage
uid=1501
role=roles/garage
cert=/etc/pki/tls/certs/db2-s3.crt
tls_key=/etc/pki/tls/private/db2-s3.key
ca=/var/lib/pgsql/.postgresql/root.crt
san="DNS:db2, IP Address:192.168.122.12"
zone=dc1
bucket=pg-backups
key=cnpg
garage="runuser -u garage -- /usr/local/bin/garage"
sigv4=aws:amz:garage:s3
object=check-33.txt
stamp=check-33-$(date -u +%Y%m%dT%H%M%SZ)
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

same_file() {
    local sum
    sum=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$(on "$host" "sha256sum $1" | cut -d' ' -f1)" = "${sum:-no file}" ]
}

on_client() {
    ssh -n "$client" "$*" 2>/dev/null
}

s3() {
    printf 'user = "%s"\n' "$cred" |
        ssh "$client" "curl -sS -m 10 -w '%{http_code}' --cacert lab-ca.crt --aws-sigv4 $sigv4 -K - $*" 2>/dev/null
}

check "$host: fstab mounts $mount by the UUID of $lv, as xfs" \
    [ "$(on "$host" "findmnt -s -rn -o SOURCE,FSTYPE $mount")" = "UUID=$(on "$host" "blkid -s UUID -o value $lv") xfs" ]
check "$host: $mount is mounted from $mapper" [ "$(on "$host" "findmnt -rn -o SOURCE $mount")" = "$mapper" ]
check "$host: $mount belongs to garage:garage with mode 750" [ "$(on "$host" "stat -c '%U:%G %a' $mount")" = "garage:garage 750" ]
check "$host: every label under $mount matches the policy" [ -z "$(on "$host" "restorecon -Rnv $mount")" ]

check "$host: the user garage has UID and GID $uid and the shell /usr/sbin/nologin" \
    [ "$(on "$host" 'getent passwd garage' | cut -d: -f3,4,7)" = "$uid:$uid:/usr/sbin/nologin" ]
sum=$(sed -n 's/^garage_sha256: "\(.*\)"$/\1/p' "$role/defaults/main.yml")
check "$host: /usr/local/bin/garage has the checksum in $role/defaults/main.yml" \
    [ "$(on "$host" 'sha256sum /usr/local/bin/garage' | cut -d' ' -f1)" = "${sum:-no checksum}" ]
for f in garage.toml systemd/system/garage.service nginx/conf.d/garage.conf; do
    check "$host: /etc/$f matches $role/files/${f##*/}" same_file "/etc/$f" "$role/files/${f##*/}"
done
check "$host: /etc/garage is root:garage 750 and its two secrets garage:garage 600" \
    [ "$(on "$host" "stat -c '%U:%G %a' /etc/garage /etc/garage/rpc_secret /etc/garage/admin_token" | xargs)" = "root:garage 750 garage:garage 600 garage:garage 600" ]
for u in garage nginx; do
    check "$host: $u.service is enabled and active" [ "$(on "$host" "systemctl is-enabled $u") $(on "$host" "systemctl is-active $u")" = "enabled active" ]
done
listen=$(on "$host" 'ss -Htlnp')
check "$host: Garage listens only on 127.0.0.1, ports 3900, 3901 and 3903" \
    [ "$(awk '/"garage"/ {print $4}' <<< "$listen" | sort | xargs)" = "127.0.0.1:3900 127.0.0.1:3901 127.0.0.1:3903" ]
check "$host: nginx listens on port 443" grep -Eq ':443 .*"nginx"' <<< "$listen"

check "$host: the S3 certificate is root:root 644 and its key root:root 600" \
    [ "$(on "$host" "stat -c '%U:%G %a' $cert $tls_key" | xargs)" = "root:root 644 root:root 600" ]
pubkey=$(on "$host" "openssl x509 -noout -pubkey -in $cert")
check "$host: the key belongs to the certificate" [ "$(on "$host" "openssl pkey -pubout -in $tls_key")" = "${pubkey:-no certificate}" ]
check "$host: the lab CA in $ca signed the certificate" [ "$(on "$host" "openssl verify -CAfile $ca $cert")" = "$cert: OK" ]
check "$host: the certificate names $san" [ "$(on "$host" "openssl x509 -noout -ext subjectAltName -in $cert" | tail -n 1 | xargs)" = "$san" ]
check "$host: the certificate is valid for 30 more days" [ "$(on "$host" "openssl x509 -noout -checkend 2592000 -in $cert")" = "Certificate will not expire" ]
check "$host: httpd_can_network_connect is on, also after a reboot" \
    grep -Eq '^httpd_can_network_connect +\(on +, +on\)' <<< "$(on "$host" 'semanage boolean -l -C')"
check "$host: firewalld opens https in the zone public, permanently" \
    grep -qw https <<< "$(on "$host" 'firewall-cmd --permanent --zone=public --list-services')"

cred=$(ansible "$host" -m ansible.builtin.debug -a "msg={{ garage_s3_key_id }}:{{ garage_s3_secret_key }}" 2>/dev/null |
    grep -o 'GK[0-9a-f]\{24\}:[0-9a-f]\{64\}')
key_id=${cred%%:*}
check "$host: the Garage node has its role in zone $zone" \
    [ "$(on "$host" "$garage status" | awk -v h="$host" '$2 == h {print $3, $5}')" = "127.0.0.1:3901 $zone" ]
check "the vault in inventory/host_vars/$host.yml holds the S3 key" [ -n "$cred" ]
check "$host: Garage has one key, $key, with the ID from the vault" \
    [ "$(on "$host" "$garage key list" | awk '$1 ~ /^GK/ {print $1, $3}')" = "${key_id:-no key} $key" ]
check "$host: the bucket $bucket lets only $key read and write" \
    [ "$(on "$host" "$garage bucket info $bucket" | awk '$2 ~ /^GK/ {print $1, $2, $3}')" = "RW ${key_id:-no key} $key" ]

ca_sum=$(on "$host" "sha256sum $ca" | cut -d' ' -f1)
check "$client: ~/lab-ca.crt is the lab CA of $host" [ "$(on_client sha256sum lab-ca.crt | cut -d' ' -f1)" = "${ca_sum:-no CA}" ]
for n in $names; do
    check "$client: https://$n/ passes TLS with the lab CA and refuses an unsigned request (403)" \
        [ "$(on_client curl -sS -m 10 -o /dev/null -w "'%{http_code}'" --cacert lab-ca.crt "https://$n/$bucket/")" = 403 ]
done
check "$client: $key writes $object with a signed PUT" [ "$(s3 -X PUT --data-binary "$stamp" "https://db2/$bucket/$object")" = 200 ]
check "$client: $key reads $object back with a signed GET" [ "$(s3 "https://db2/$bucket/$object")" = "${stamp}200" ]
check "$client: $key deletes $object" [ "$(s3 -X DELETE "https://db2/$bucket/$object")" = 204 ]

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
