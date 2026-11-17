#!/usr/bin/env bash
# Lesson 28 checks: the settings of the app web, from a ConfigMap and a Secret.
# Reads the cluster with kubectl through the tunnel: the Secret web-token made by hand (its type
# and its key names, never its data), no access to Secrets for the service account default of web,
# the ConfigMap that Kustomize generates (read by name from the Deployment, because the name ends
# in a hash of its data) with the APP_RELEASE of kustomization.yaml and the index.html of the repo,
# the Deployment taking APP_RELEASE from that ConfigMap and the token from web-token as APP_TOKEN
# and as /etc/web/token, one Pod of web per replica, and in every Pod the APP_RELEASE of the repo,
# the same token in the variable and in the file, and our page at /.
# A container reads its variables when it starts, so a Pod keeps the old APP_RELEASE after a live
# change of the ConfigMap until it restarts. Check 27 compares the whole folder with kubectl diff -k.
# Run on the desktop from the repo root, with the tunnel open in a second terminal
# (ssh -N -L 6443:192.168.122.21:6443 nuc):
#   bash checks/28-app-settings.sh
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
secret=web-token
manifests=kubernetes/apps/web

# The manifests are read from the repo root
cd "$(dirname "$0")/.." || exit 1

# APP_RELEASE in the configMapGenerator of kustomization.yaml, and the page in index.html
release=$(awk -F= '/- APP_RELEASE=/ {print $2}' "$manifests/kustomization.yaml")
page=$(cat "$manifests/index.html")

# Run kubectl with the desktop kubeconfig and print only its output.
kube() {
    kubectl --request-timeout=10s "$@" 2>/dev/null
}

# A field of httpd, the one container in the Pod template of the Deployment
container() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.containers[0].$1}"
}

# A field of a volume in the Pod template of the Deployment
volume() {
    kube get deployment "$app" -n "$ns" -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$1\")].$2}"
}

# The mount path of a volume in httpd
mount_path() {
    container "volumeMounts[?(@.name==\"$1\")].mountPath"
}

# The ConfigMap or Secret and the key that a variable of httpd comes from, as name/key
env_source() {
    local ref="env[?(@.name==\"$1\")].valueFrom.$2"
    echo "$(container "$ref.name")/$(container "$ref.key")"
}

# A key of the ConfigMap that the Deployment uses
setting() {
    kube get configmap "$cm" -n "$ns" -o jsonpath="{.data.$1}"
}

# The key names of the Secret, one per line. Its values are never printed.
secret_keys() {
    kube get secret "$secret" -n "$ns" -o go-template='{{range $key, $value := .data}}{{$key}}{{"\n"}}{{end}}'
}

# The API server through the tunnel
check "the API server answers at $server" [ "$(kube get --raw /readyz)" = ok ]
if [ "$failed" -gt 0 ]; then
    echo
    echo "Open the tunnel in a second terminal first: ssh -N -L 6443:192.168.122.21:6443 nuc"
    exit "$failed"
fi

# The Secret, made by hand and not in the repo, and who may read it
check "the Secret $secret is Opaque" [ "$(kube get secret "$secret" -n "$ns" -o jsonpath='{.type}')" = Opaque ]
check "$secret has the one key token" [ "$(secret_keys)" = token ]
check "the service account default of $ns cannot read Secrets" \
    [ "$(kube auth can-i get secrets -n "$ns" --as="system:serviceaccount:$ns:default")" = no ]

# The ConfigMap that Kustomize generates, named web-config and a hash of its data
cm=$(volume page configMap.name)
check "the volume page uses a generated ConfigMap (${cm:-none})" grep -Eq '^web-config-[a-z0-9]{10}$' <<< "$cm"
check "$cm holds APP_RELEASE $release from kustomization.yaml" [ "$(setting APP_RELEASE)" = "$release" ]
check "$cm holds index.html from the repo" [ "$(setting 'index\.html')" = "$page" ]

# httpd takes the settings from the ConfigMap and the token from the Secret
check "APP_RELEASE comes from $cm" [ "$(env_source APP_RELEASE configMapKeyRef)" = "$cm/APP_RELEASE" ]
check "APP_TOKEN comes from $secret" [ "$(env_source APP_TOKEN secretKeyRef)" = "$secret/token" ]
check "the volume token comes from $secret" [ "$(volume token secret.secretName)" = "$secret" ]
check "the files of the volume token have mode 0440" [ "$(volume token secret.defaultMode)" = 288 ]
check "httpd mounts the page on /var/www/html" [ "$(mount_path page)" = /var/www/html ]
check "httpd mounts the token on /etc/web, outside the DocumentRoot" [ "$(mount_path token)" = /etc/web ]

# Every Pod of web: the settings it started with and the page it serves.
# The loop checks nothing when it finds no Pod, so the number of Pods is a check of its own.
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
