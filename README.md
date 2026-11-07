# homekube-apps

ArgoCD applications for the [homekube](https://github.com/jangroth/homekube) cluster, managed via the [App-of-Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

ArgoCD watches this repo. A single root application (`applications/kustomization.yaml`) deploys everything below. Wave annotations control deployment order.

See [spec 005](../docs/specs/005-production-cluster-setup.md) for full capability descriptions, version policy, and acceptance criteria.

---

## Deployed Components

The full component/version/access table lives in the top-level [`homekube` README](../README.md#argocd-deployed-workloads) — this repo only covers ArgoCD-specific mechanics and repo-local operational runbooks.

> ArgoCD itself is installed via Ansible (`homekube-main`), not managed here.

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

### Infisical (human step)

Infisical ([spec 009](../docs/specs/009-infisical-phase-1.md)) needs its own bootstrap secrets, a backup before every version bump, and a manual restore procedure.

**1. Bootstrap secrets.** Generate the values, store them in the password manager **before** sealing, then seal. `ENCRYPTION_KEY` encrypts every stored secret and can't be rotated, so losing it makes the data unrecoverable even when you have a backup. On a rebuild, re-seal from the password-manager values; don't generate new ones.

```sh
ENC=$(openssl rand -hex 16); AUTH=$(openssl rand -base64 32); PGPW=$(openssl rand -hex 24)
# → store ENC, AUTH, PGPW in the password manager now

cd applications/wave-02-apps/infisical-extras
seal() { kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o json; }   # zsh doesn't word-split "$VAR" commands

kubectl create secret generic infisical-secrets -n infisical --dry-run=client -o json \
  --from-literal=ENCRYPTION_KEY="$ENC" --from-literal=AUTH_SECRET="$AUTH" \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:$PGPW@postgres.infisical.svc.cluster.local:5432/infisical" \
  --from-literal=REDIS_URL='redis://redis.infisical.svc.cluster.local:6379' \
| seal > infisical-sealedsecret.yaml

kubectl create secret generic postgres-credentials -n infisical --dry-run=client -o json \
  --from-literal=POSTGRES_USER=infisical --from-literal=POSTGRES_PASSWORD="$PGPW" --from-literal=POSTGRES_DB=infisical \
| seal > postgres-sealedsecret.yaml

unset ENC AUTH PGPW
```

`rolloutOnEveryRender` is off, so changing `infisical-secrets` doesn't restart the pod. After the sync, run `kubectl -n infisical rollout restart deploy/infisical`.

**2. Before merging an Infisical bump.** Each release runs its DB migrations at startup, and there's no down-migration: the only way back is to restore the volume. Take a manual Longhorn backup of the `data-postgres-0` volume and wait for it to finish (Longhorn UI → Volumes → the `pvc-…` volume whose PVC is `data-postgres-0` → Create Backup), then merge. Postgres and Redis major bumps are disabled in Renovate. A Postgres major is a dump-and-restore migration.

**3. Restore.** The manifests are in [`manual/infisical-restore/`](manual/infisical-restore/). They restore a backup into a new volume in the throwaway namespace `infisical-restore`, so the live namespace is untouched. The same procedure is the starting point for a real recovery.

```sh
cd manual/infisical-restore
# 1. Set spec.fromBackup in 01-volume.yaml to the backup URL (Longhorn UI → Backup → volume → backup → URL)
kubectl apply -f 01-volume.yaml
kubectl -n longhorn-system get volumes.longhorn.io infisical-restore-pg -w   # wait for state "detached"
kubectl apply -f 02-pv-pvc.yaml
# 2. Create plain Secrets infisical-secrets and postgres-credentials in infisical-restore
#    (the commands in step 1 without --dry-run/seal, -n infisical-restore, and hosts *.infisical-restore.svc)
kubectl apply -f 03-workloads.yaml   # Infisical restarts until Postgres is up
kubectl -n infisical-restore port-forward deploy/infisical 8080:8080   # http://localhost:8080
# 3. Clean up
kubectl delete namespace infisical-restore
kubectl delete pv infisical-restore-pg
kubectl -n longhorn-system delete volumes.longhorn.io infisical-restore-pg
```

---

### Agent Vault proxy (human step)

The Agent Vault proxy ([spec 010](../docs/specs/010-agent-vault-hermes.md)) attaches Hermes's API credentials to its outbound requests, so Hermes only holds a session token. Its proxy, services, bundle and session live in Infisical and are created in the UI. Needs Infisical `>= v0.167.2` (proxy tokens); older servers only issue enrollment tokens, which `infisical/cli >= 0.44.7` can't use.

**1. Infisical UI** (`https://192.168.86.247`, default Agent Vault project; the open-source edition can't create others). Each token is shown once: store it in the password manager before closing the dialog.

- **Proxy** `homekube`: Advanced Options → traffic policy **Any host**, poll interval `60`. Store the **proxy token** as "Agent Vault proxy token (homekube)".
- **Access bundle** `hermes`, with service `tavily`:
  - Host `api.tavily.com`, method `POST`, paths `/search`, `/extract`
  - Bearer credential: header `Authorization`, prefix `Bearer`, value the real Tavily key
- **Session** on bundle `hermes`, label `hermes`, expiry **Never**. Store the **session token** as "Agent Vault session token (hermes bundle)".

**2. Seal both tokens.** `read -s` keeps them out of shell history (zsh syntax; bash: `read -s -p "Proxy token: " PT`).

```sh
seal() { kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o json; }

read -s "PT?Proxy token: "; echo
kubectl create secret generic agent-vault-proxy-token -n agent-vault \
  --from-literal=INFISICAL_AGENT_VAULT_PROXY_TOKEN="$PT" --dry-run=client -o json \
| seal > applications/wave-03-apps/agent-vault/proxy-token-sealedsecret.yaml
unset PT

# The session token is the password half of Hermes's HTTPS_PROXY URL.
read -s "ST?Session token: "; echo
kubectl create secret generic hermes-agent-vault -n hermes \
  --from-literal=HTTPS_PROXY="http://x-agent-vault:${ST}@agent-vault-proxy.agent-vault.svc:17323" \
  --dry-run=client -o json \
| seal > /tmp/hermes-agent-vault.json
unset ST
```

The proxy pod doesn't start without `agent-vault-proxy-token`. Once it is Ready, the Proxies page shows `homekube` as connected, with a Certificate Authority fingerprint.

**3. Hermes values.** The herminator chart renders `hermes-agent-vault` itself, so only its ciphertext goes into git, in `applications/wave-03-apps/hermes.yaml` under `agentVault`:

```sh
jq -r .spec.encryptedData.HTTPS_PROXY /tmp/hermes-agent-vault.json   # → encryptedHttpsProxy
rm /tmp/hermes-agent-vault.json

kubectl -n agent-vault port-forward deploy/agent-vault-proxy 17323 &
curl -s http://localhost:17323/_agent-vault/ca | jq -er .certificate > /tmp/agent-vault-ca.pem
kill %1
openssl x509 -in /tmp/agent-vault-ca.pem -noout -fingerprint -sha256
```

The fingerprint must match the one on the Proxies page (hover for the full value) before the PEM goes into `caCert`; keep it in the comment above `caCert`. Either value changing restarts Hermes.

On a rebuild, re-seal both from the password manager. A new proxy token re-enrolls the proxy and changes its CA, so `caCert` has to be fetched again; a new session only needs `encryptedHttpsProxy` resealed.

---

### Renovate PAT (human step)

`.github/workflows/renovate.yml` needs a `RENOVATE_TOKEN` repo secret to open PRs — not creatable by automation.

1. GitHub → Settings → Developer settings → Fine-grained tokens → new token
2. Repository access: only this repo (`jangroth/homekube-apps`)
3. Permissions: **Contents** (read/write), **Pull requests** (read/write) — no `github-actions` manager is enabled, so no workflow-file permission is needed
4. Add as repo secret `RENOVATE_TOKEN`: Settings → Secrets and variables → Actions

Trigger a run manually instead of waiting for the weekly cron (Monday 06:00 UTC):

```sh
gh workflow run renovate.yml --repo jangroth/homekube-apps
```

> Renovate's Dependency Dashboard issue is always created in this repo, not `jangroth/homekube` — Renovate has no option to target a different repo for it. Exception to the single-tracker convention: it's a bot-managed, self-rewriting status report, not a tracked task.

---

## Nightly routine

A Claude Code cloud routine ("homekube-apps - nightly todo", daily 16:00 UTC / 02:00 AEST) picks up one open tracker issue labelled `agent-safe` + `repo:homekube-apps` and opens a PR for review. Its config lives in the repo:

- `.claude/routines/nightly-todo.md` — the routine's instructions and settings, including the exact routine prompt, which points to this file and authorises the branch, commit, push and PR
- `.claude/routines/cloud-environment.md` — the cloud environment's settings: name, network allowlist, setup script
- `scripts/cloud/setup.sh` — the cloud environment's setup script; the environment's script only runs `bash /home/user/homekube-apps/scripts/cloud/setup.sh`

---

## Wave Structure

| Wave | Purpose |
|------|---------|
| `-1` (`wave-00-init`) | Foundation: secrets, TLS, node hygiene, load balancer, storage |
| `01` (`wave-01-apps`) | Observability: metrics, logs, dashboards |
| `02` | Identity & SSO |
| `03` (`wave-03-apps`) | Cluster dashboard; later: service mesh, backups |

---

## Adding an App

1. Create `applications/wave-NN-<name>/<app>.yaml` — ArgoCD `Application` manifest
2. Add the path to `applications/kustomization.yaml`
3. Commit and push — ArgoCD picks it up automatically
