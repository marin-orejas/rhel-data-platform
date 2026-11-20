# cert-manager

cert-manager v1.21.3 issues TLS certificates in the [Kubernetes cluster](cluster.md) from its Issuers and renews them. It runs three pods on the workers and has no Issuer yet.

Checks: [31](../../../checks/31-storage.sh) · Files: [`kubernetes/cert-manager/values.yaml`](../../../kubernetes/cert-manager/values.yaml)

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

## Why

- The OCI chart, because the cert-manager Helm docs recommend it and the repo `charts.jetstack.io` gets new versions a few hours later. So there is no `helm repo add`.
- `crds.keep` stays at its default `true`, because a deleted CRD takes every Certificate and Issuer of its kind with it.

## Limits

- cert-manager 1.21 supports Kubernetes 1.33 to 1.36, so a cluster upgrade to 1.37 first needs a release that supports it (item 36).
- One pod each, so while `cert-manager-webhook` is down, the API server refuses new and changed cert-manager resources.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-19 | Self-signed Issuer and a Certificate for `test.cm-test.svc` in the namespace `cm-test` | `READY True` and the Secret `test-tls`, valid for 90 days with renewal 30 days before the end (the defaults). The namespace was deleted after the test. |

## Planned

- plugin-barman-cloud, which needs cert-manager for its own certificates (item 34).
