# homekube-apps

ArgoCD applications for the [homekube](https://github.com/jangroth/homekube) cluster, managed via the [App-of-Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

ArgoCD watches this repo. A single root application (`applications/kustomization.yaml`) deploys everything below. Wave annotations control deployment order.

See [spec 005](../docs/specs/005-production-cluster-setup.md) for full capability descriptions, version policy, and acceptance criteria.

---

## Deployed Components

> ArgoCD itself is installed via Ansible (`homekube-main`), not managed here.

| Component | Namespace | Wave | Chart Version | Access |
|-----------|-----------|------|---------------|--------|
| Cilium LB-IPAM + L2 | `kube-system` | -1 | — (CRs only) | VIP pool `192.168.86.241–251` |
| ArgoCD config | `argocd` | -1 | — | `192.168.86.241:80` |
| metrics-server | `kube-system` | -1 | — | `kubectl top` |
| sealed-secrets | `kube-system` | -1 | 2.18.6 | `kubeseal` CLI |
| cert-manager | `cert-manager` | -1 | 1.20.2 | `ClusterIssuer/homekube-ca` |
| kubelet-csr-approver | `kube-system` | -1 | 1.2.14 | automatic CSR approval |

---

## Wave Structure

| Wave | Purpose |
|------|---------|
| `-1` (`wave-00-init`) | Foundation: secrets, TLS, node hygiene, load balancer, storage |
| `01` (`wave-01-apps`) | Observability: metrics, logs, dashboards |
| `02` | Identity & SSO |
| `03` | Service mesh, backups |

---

## Adding an App

1. Create `applications/wave-NN-<name>/<app>.yaml` — ArgoCD `Application` manifest
2. Add the path to `applications/kustomization.yaml`
3. Commit and push — ArgoCD picks it up automatically
