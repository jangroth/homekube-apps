# homekube-apps

ArgoCD applications for the homekube cluster, using the App-of-Apps pattern.

See parent `CLAUDE.md` (one level up) for cluster topology and working conventions.

---

## Pattern

ArgoCD runs on the cluster and watches this repo. A single root application (`applications/kustomization.yaml`) deploys all other applications. Apps are synced in waves to manage dependency order.

---

## Wave Structure

| Wave | Sync Order | Apps |
|------|-----------|------|
| `wave-00-init` | First | Cilium LB (pool + L2 policy), Longhorn, metrics-server, ArgoCD config, sealed-secrets, cert-manager (+ config), CoreDNS patch, kubelet-csr-approver |
| `wave-01-apps` | After init | Longhorn extras, kube-prometheus, Loki, Alloy, Prometheus extras (Alertmanager Telegram) |
| `wave-02-apps` | After apps | Dex (OIDC) |
| `wave-03-apps` | Last | Homepage dashboard |

Wave is set via annotation: `argocd.argoproj.io/sync-wave: "N"`

---

## Adding an App

1. Create `applications/wave-NN-<wave>/<app-name>.yaml` — ArgoCD Application manifest
2. Add it to `applications/kustomization.yaml`
3. Commit and push — ArgoCD picks it up automatically

---

## Key Files

| Path | Purpose |
|------|---------|
| `applications/kustomization.yaml` | Root kustomization — lists all app manifests |
| `applications/wave-00-init/` | Foundation apps (load balancer, storage, metrics) |
| `applications/wave-01-apps/` | Observability and storage extras |
| `applications/wave-02-apps/` | OIDC (Dex) |
| `applications/wave-03-apps/` | Dashboard (Homepage) |
| `manual/` | One-off manifests for testing/debugging (not managed by ArgoCD) |

---

## ArgoCD Access

After cluster setup: ArgoCD is exposed as LoadBalancer (VIP from Cilium LB-IPAM pool).
`kubectl -n argocd get svc cst-argocd-server` to see the assigned IP.
