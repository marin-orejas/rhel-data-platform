# cert-manager

cert-manager v1.21.3 issues and renews TLS certificates in the [Kubernetes cluster](cluster.md), for now only the two of [plugin-barman-cloud](cloudnativepg-backups.md#plugin). It runs three pods on the workers.

Checks: [31](../../../checks/31-storage.sh), [34](../../../checks/34-backups.sh) · Files: [`kubernetes/cert-manager/values.yaml`](../../../kubernetes/cert-manager/values.yaml)

## Setup

| Part | Setup |
|---|---|
| Chart | `cert-manager` v1.21.3 from `oci://quay.io/jetstack/charts/cert-manager`, release `cert-manager` in `cert-manager` |
| Values | `crds.enabled: true` in `kubernetes/cert-manager/values.yaml`, so the chart installs the CRDs (off by default) |
| Namespace | `cert-manager`, made by `helm install --create-namespace` |
| CRDs | Six: `certificates`, `certificaterequests`, `issuers` and `clusterissuers` in `cert-manager.io`, `orders` and `challenges` in `acme.cert-manager.io` |
| CRDs on uninstall | Kept (`crds.keep: true`, the default) |
| Controller | Deployment `cert-manager`, one pod |
| CA injector | Deployment `cert-manager-cainjector`, one pod |
| Webhook | Deployment `cert-manager-webhook`, one pod. The API server sends it every new or changed cert-manager resource to check. |
| Placement | k8s2 and k8s3 (no toleration for the [control-plane taint](cluster.md#nodes)) |
| Startup check | Job `cert-manager-startupapicheck`, a post-install hook. `helm install` waits for it, about a minute, and deletes it when it succeeds. |
| Certificates in use | `barman-cloud-client` and `barman-cloud-server` in `cnpg-system`, for [plugin-barman-cloud](cloudnativepg-backups.md#plugin) |

## Why

- The OCI chart, because the cert-manager Helm docs recommend it and the repo `charts.jetstack.io` gets new versions a few hours later. So there is no `helm repo add`.
- `crds.keep` stays at its default `true`, because a deleted CRD takes every Certificate and Issuer of its kind with it.

## Limits

- cert-manager 1.21 supports Kubernetes 1.33 to 1.36, so the cluster stays on 1.36 until a cert-manager release supports 1.37.
- One pod each, so while `cert-manager-webhook` is down, the API server refuses new and changed cert-manager resources.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-19 | Self-signed Issuer and a Certificate for `test.cm-test.svc` in the namespace `cm-test` | `READY True` and the Secret `test-tls`, valid for 90 days with renewal 30 days before the end (the defaults). The namespace was deleted after the test. |
