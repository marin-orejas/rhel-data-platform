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
secret=web-token
manifests=kubernetes/apps/web

cd "$(dirname "$0")/.." || exit 1

release=$(awk -F= '/- APP_RELEASE=/ {print $2}' "$manifests/kustomization.yaml")
page=$(cat "$manifests/index.html")

kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

container() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.containers[0].$1}"
}

volume() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$1\")].$2}"
}

mount_path() {
    container "volumeMounts[?(@.name==\"$1\")].mountPath"
}

env_source() {
    local ref="env[?(@.name==\"$1\")].valueFrom.$2"
    echo "$(container "$ref.name")/$(container "$ref.key")"
}

setting() {
    kube get configmap "$cm" -n "$ns" -o jsonpath="{.data.$1}"
}

secret_keys() {
    kube get secret "$secret" -n "$ns" -o go-template='{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
}

check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

check "the Secret $secret is Opaque" [ "$(kube get secret "$secret" -n "$ns" -o jsonpath='{.type}')" = Opaque ]
check "$secret has the one key token" [ "$(secret_keys)" = token ]
check "the service account default of $ns cannot read Secrets" \
    [ "$(kube auth can-i get secrets -n "$ns" --as="system:serviceaccount:$ns:default")" = no ]

cm=$(volume page configMap.name)
check "the volume page uses a generated ConfigMap (${cm:-none})" grep -Eq '^web-config-[a-z0-9]{10}$' <<< "$cm"
check "$cm holds APP_RELEASE $release from kustomization.yaml" [ "$(setting APP_RELEASE)" = "$release" ]
check "$cm holds index.html from the repo" [ "$(setting 'index\.html')" = "$page" ]

check "APP_RELEASE comes from $cm" [ "$(env_source APP_RELEASE configMapKeyRef)" = "$cm/APP_RELEASE" ]
check "APP_TOKEN comes from $secret" [ "$(env_source APP_TOKEN secretKeyRef)" = "$secret/token" ]
check "the volume token comes from $secret" [ "$(volume token secret.secretName)" = "$secret" ]
check "the files of the volume token have mode 0440" [ "$(volume token secret.defaultMode)" = 288 ]
check "httpd mounts the page on /var/www/html" [ "$(mount_path page)" = /var/www/html ]
check "httpd mounts the token on /etc/web, outside the DocumentRoot" [ "$(mount_path token)" = /etc/web ]

pods=$(kube get pods -n "$ns" -l app="$app" -o name)
replicas=$(kube get deployment "$app" -n "$ns" -o jsonpath='{.spec.replicas}')
check "$ns has one Pod of $app per replica (${replicas:-none})" [ "$(wc -w <<< "$pods")" = "${replicas:-none}" ]
for pod in $pods; do
    name=${pod#pod/}
    check "$name has APP_RELEASE $release" [ "$(kube exec "$pod" -n "$ns" -- printenv APP_RELEASE)" = "$release" ]
    check "$name has the same token in APP_TOKEN and /etc/web/token" \
        kube exec "$pod" -n "$ns" -- sh -c 'test -n "$APP_TOKEN" && test "$APP_TOKEN" = "$(cat /etc/web/token)"'
    check "$name serves index.html of the repo at /" \
        [ "$(kube exec "$pod" -n "$ns" -- curl -sf http://localhost:8080/)" = "$page" ]
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
