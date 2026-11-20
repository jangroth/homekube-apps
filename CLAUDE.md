# homekube-apps

ArgoCD applications for the homekube cluster, using the App-of-Apps pattern.

See parent `CLAUDE.md` (one level up) for cluster topology and working conventions.

**Agent skills**: use a Matt Pocock skill whenever one covers the task. Its tracker, labels and domain docs (glossary, ADRs) are set in the parent `CLAUDE.md` → `## Agent skills`; in a standalone clone, read it with `gh api repos/jangroth/homekube/contents/CLAUDE.md -H 'Accept: application/vnd.github.raw'`.

---

## Branching

ArgoCD syncs `main` on push, so `main` is the live cluster: every change, one-line bumps included, takes a PR.

---

## Waves

The root application (`applications/kustomization.yaml`) deploys every manifest it lists, synced in waves by the `argocd.argoproj.io/sync-wave: "N"` annotation. An app goes in a later wave than everything it depends on:

| Wave | Holds |
|------|-------|
| `wave-00-init` | Cluster foundations: load balancer, storage, certificates, secrets, DNS, ArgoCD itself |
| `wave-01-apps` | Observability and storage extras |
| `wave-02-apps` | Identity (Dex) and secret store (Infisical) |
| `wave-03-apps` | User-facing apps (Homepage, Hermes, Agent Vault proxy, Coder) |

`manual/` holds one-off manifests for testing and debugging; ArgoCD doesn't manage it.

---

## Adding an App

1. Create `applications/wave-NN-<wave>/<app-name>.yaml` — ArgoCD Application manifest
2. Add it to `applications/kustomization.yaml`

---

## ArgoCD Access

ArgoCD is a LoadBalancer service with a VIP from the Cilium LB-IPAM pool: `kubectl -n argocd get svc cst-argocd-server` shows the IP.
