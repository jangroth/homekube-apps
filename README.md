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
| Longhorn | `longhorn-system` | -1 | 1.11.2 | `192.168.86.242:80` |
| kube-prometheus-stack (Prometheus + Alertmanager) | `observability` | 01 | 87.0.1 | Prometheus `:30002`, Alertmanager `:30004` |
| Loki | `observability` | 01 | 7.0.0 | internal (`observability` svc) |
| Alloy | `observability` | 01 | 1.8.1 | DaemonSet log shipper |
| Grafana | `observability` | 01 | (kube-prometheus subchart) | `192.168.86.243:443` |
| Dex | `dex` | 02 | 0.24.1 | `192.168.86.244:5556` (LAN), `https://pi0.taild13083.ts.net/dex` (browser/OIDC) |

### Dex Google OAuth client (human step)

Cap-9 (Identity & SSO) uses Google as the upstream identity provider via Dex. Complete these steps before deploying the `dex` ArgoCD Application.

**1. Enable Tailscale HTTPS on pi0** (one-time, gives Dex a publicly trusted cert via Let's Encrypt):

```sh
ssh homekube@pi0
tailscale cert pi0.taild13083.ts.net   # issues the cert, stored in /var/lib/tailscale/certs/
```

**2. Create the Google OAuth2 client** in [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
- Application type: **Web application**
- Name: `homekube-dex`
- Authorized redirect URIs: `https://pi0.taild13083.ts.net/dex/callback`
- Note the **Client ID** and **Client Secret**

**3. Seal the credentials:**

```sh
kubectl create secret generic dex-google-oauth \
  --from-literal=clientID=<GOOGLE_CLIENT_ID> \
  --from-literal=clientSecret=<GOOGLE_CLIENT_SECRET> \
  --namespace dex \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    --namespace dex \
  > applications/wave-02-apps/dex-extras/dex-google-oauth.yaml
```

**4. After Dex is deployed**, configure `tailscale serve` on pi0 to proxy HTTPS → Dex LB VIP:

```sh
ssh homekube@pi0
sudo tailscale serve --bg --https=443 http://192.168.86.244:5556
# Verify: curl -s https://pi0.taild13083.ts.net/dex/.well-known/openid-configuration | jq .issuer
```

**5. Approve the Tailscale route** if prompted in the [Tailscale admin console](https://login.tailscale.com/admin).

---

### Alertmanager Telegram secret (human step)

Before pushing the Alertmanager Telegram config, create the sealed secret:

```sh
# 1. Create a bot via @BotFather; get the bot token and target chat ID.
# 2. Seal and commit:
kubectl create secret generic alertmanager-telegram \
  --from-literal=bot_token=<YOUR_TELEGRAM_BOT_TOKEN> \
  --namespace observability \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    --namespace observability \
  > applications/wave-01-apps/prometheus-extras/alertmanager-telegram.yaml

# 3. Get the chat ID — send a message to the bot, then:
#      curl https://api.telegram.org/bot<TOKEN>/getUpdates | jq '.result[].message.chat.id'
#    Replace chat_id: 0 in kube-prometheus.yaml (alertmanager.config.receivers) with the integer.
# 4. Commit alertmanager-telegram.yaml first (or in the same commit), then push.
#    Alertmanager mounts this secret — it cannot start without it.
```

---

### Homepage widget credentials (human step)

The Homepage dashboard ([spec 007](../docs/specs/007-homepage-dashboard.md)) authenticates its ArgoCD widget with an API token. The token cannot be pre-generated in source — it is minted imperatively and committed as a sealed secret. On a cluster rebuild, re-mint and re-seal (same recovery story as the other sealed secrets on this page).

> Grafana gets a **link only, no widget**: Homepage's Grafana widget unconditionally calls `/api/admin/stats`, which requires Grafana server-admin credentials — unacceptable in the pod env of an unauthenticated dashboard. See spec 007, Open Question 2.

**1. ArgoCD API token.** The `homepage` local account (`apiKey` capability, `role:readonly`) is declared in the ArgoCD Helm values in `homekube-main` (`ansible/roles/gitops/files/argocd-helm-values.yaml`) — only the token is minted by hand:

```sh
argocd login 192.168.86.241 --username admin --insecure --grpc-web
argocd account generate-token --account homepage
```

**2. Seal the token:**

```sh
kubectl create secret generic homepage-widget-secrets \
  --from-literal=HOMEPAGE_VAR_ARGOCD_TOKEN=<ARGOCD_TOKEN> \
  --namespace homepage \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    --namespace homepage \
  > applications/wave-03-apps/homepage/sealedsecret.yaml
```

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
