# homekube-apps

ArgoCD applications for the [homekube](https://github.com/jangroth/homekube) cluster, managed via the [App-of-Apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

ArgoCD watches this repo. A single root application (`applications/kustomization.yaml`) deploys everything below. Wave annotations control deployment order.

See [spec 005](https://github.com/jangroth/homekube/blob/main/docs/archive/specs/005-production-cluster-setup.md) for full capability descriptions, version policy, and acceptance criteria.

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

The Homepage dashboard ([spec 007](https://github.com/jangroth/homekube/blob/main/docs/archive/specs/007-homepage-dashboard.md)) authenticates its ArgoCD widget with an API token. The token cannot be pre-generated in source — it is minted imperatively and committed as a sealed secret. On a cluster rebuild, re-mint and re-seal (same recovery story as the other sealed secrets on this page).

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

Infisical ([spec 009](https://github.com/jangroth/homekube/blob/main/docs/archive/specs/009-infisical-phase-1.md)) needs its own bootstrap secrets, a backup before every version bump, and a manual restore procedure.

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

The Agent Vault proxy ([spec 010](https://github.com/jangroth/homekube/blob/main/docs/archive/specs/010-agent-vault-hermes.md)) attaches Hermes's API credentials to its outbound requests, so Hermes only holds a session token. Its proxy, services, bundle and session live in Infisical and are created in the UI. Needs Infisical `>= v0.167.2` (proxy tokens); older servers only issue enrollment tokens, which `infisical/cli >= 0.44.7` can't use.

**1. Infisical UI** (`https://192.168.86.247`, default Agent Vault project; the open-source edition can't create others). Each token is shown once: store it in the password manager before closing the dialog.

- **Proxy** `homekube`: Advanced Options → traffic policy **Any host**, poll interval `60`. Store the **proxy token** as "Agent Vault proxy token (homekube)".
- **Access bundle** `hermes`, with services:
  - `tavily`: host `api.tavily.com`, method `POST`, paths `/search`, `/extract`. Bearer credential: header `Authorization`, prefix `Bearer`, value the real Tavily key.
  - `telegram`: host `api.telegram.org`, methods `GET`, `POST`, no paths, no credential. One substitution on surface **Path** (not Header: the token is in `/bot<token>/…`), placeholder `agent-vault-telegram`, value the real bot token.
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

**4. Hermes's `.env`.** Brokered keys are placeholders on the PVC; Hermes treats `dummy`, `placeholder`, `changeme`, `none` and all-`x` values as unset, so use `agent-vault-<service>`:

```sh
kubectl -n hermes exec deploy/hermes -c hermes -- \
  sed -i -e 's/^TAVILY_API_KEY=.*/TAVILY_API_KEY=agent-vault-tavily/' \
    -e 's/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=agent-vault-telegram/' /opt/data/.env
kubectl -n hermes rollout restart deploy/hermes
```

Check with a web search from Hermes: the proxy log (`kubectl -n agent-vault logs deploy/agent-vault-proxy`) shows `"decision":"brokered"` for service `tavily`; a Telegram message shows `telegram` lines with `"substituted":["path"]`. Passthrough requests are not logged at info, so a substitution that doesn't fire leaves no trace: Telegram rejects the placeholder and Hermes parks the platform until `hermes gateway restart`.

On a rebuild, re-seal both from the password manager. A new proxy token re-enrolls the proxy and changes its CA, so `caCert` has to be fetched again; a new session only needs `encryptedHttpsProxy` resealed.

#### Rotation

- **Brokered key** (e.g. Tavily): edit the credential on the service in bundle `hermes`. The proxy picks it up within one poll interval (60s); Hermes is untouched. If Hermes saw a 401 meanwhile it marks the key exhausted: `kubectl -n hermes exec deploy/hermes -c hermes -- su -s /bin/sh hermes -c 'hermes auth reset tavily'`.
- **Telegram bot token**: BotFather `/revoke` issues the new token at once and kills the old one; set it as the `telegram` substitution value. Polls in between get 401 and may park Telegram, so restart Hermes if it stops replying.
- **Session**, make-before-break: create a new session on bundle `hermes`, store its token, reseal (step 2, second block), set `encryptedHttpsProxy` (step 3) and merge. The checksum annotation restarts Hermes. Once a web search shows `brokered`, revoke the old session. A revoked session gets 403 on every proxied request, so revoking first cuts off all of Hermes's web access.
- **Proxy token**: create a new token on proxy `homekube`, store it, reseal `agent-vault-proxy-token` (step 2, first block) and merge, then restart the proxy (`kubectl -n agent-vault rollout restart deploy/agent-vault-proxy`). If the CA fingerprint on the Proxies page changed, redo step 3's `caCert`. A revoked proxy token gets 503 on every request.

---

### Coder (human step)

Coder ([spec 011](https://github.com/jangroth/homekube/blob/main/docs/archive/specs/011-coder-install.md)) needs bootstrap secrets, two owner accounts, its template pushed by hand, and a backup before every version bump.

**1. Bootstrap secrets.** Generate, store in the password manager **before** sealing, then seal. The Dex client secret goes into two Secrets: Coder's and Dex's. On a rebuild, re-seal from the password-manager values.

```sh
PGPW=$(openssl rand -hex 24); OIDC=$(openssl rand -hex 32)

echo "Coder (spec 011)
POSTGRES_USER=coder
POSTGRES_PASSWORD=$PGPW
POSTGRES_DB=coder
DEX_CLIENT_ID=coder
DEX_CLIENT_SECRET=$OIDC
Sealed into: coder/coder-secrets, coder/postgres-credentials, dex/dex-coder-client"
# → paste into the password manager and save before going on; clear the terminal afterwards

seal() { kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o json; }
cd applications/wave-03-apps/coder-extras

kubectl create secret generic coder-secrets -n coder --dry-run=client -o json \
  --from-literal=CODER_PG_CONNECTION_URL="postgres://coder:$PGPW@postgres.coder.svc.cluster.local:5432/coder?sslmode=disable" \
  --from-literal=CODER_OIDC_CLIENT_SECRET="$OIDC" \
| seal > coder-sealedsecret.yaml

kubectl create secret generic postgres-credentials -n coder --dry-run=client -o json \
  --from-literal=POSTGRES_USER=coder --from-literal=POSTGRES_PASSWORD="$PGPW" --from-literal=POSTGRES_DB=coder \
| seal > postgres-sealedsecret.yaml

kubectl create secret generic dex-coder-client -n dex --dry-run=client -o json \
  --from-literal=CODER_CLIENT_SECRET="$OIDC" \
| seal > ../../wave-02-apps/dex-extras/dex-coder-client.yaml

unset PGPW OIDC
```

Dex reads `dex-coder-client` through `envFrom` and doesn't restart when it changes. After resealing it, run `kubectl -n dex rollout restart deploy/dex`.

**2. Owners.** Coder emails are unique, so the break-glass owner uses a `+breakglass` alias. With OIDC signups off, the daily user is created up front, and the first Dex login links to it by email. Don't use "Convert to OIDC" in account settings: it removes the password.

1. **Right after the first sync**, open `https://192.168.86.248` and create the first user with `<you>+breakglass@<domain>`. Store its password in the password manager. Until a user exists, anyone who reaches the UI can claim the owner account through any login method, whatever the signup settings say.
2. From darth (`brew install coder`, ideally matching the server version; homekube-ca must be trusted in the macOS keychain). The email must match the Google account exactly, since the first Dex login links by email:
   ```sh
   coder login https://192.168.86.248   # browser opens; sign in as the break-glass owner, paste the token back
   coder users create --login-type oidc --email <you>@<domain> --username <user>
   coder users edit-roles <user> --roles owner
   coder users list                     # both users, both owner
   ```
3. Log out, then **Sign in with Dex** as the daily user. Another Google account should get "Signups are disabled".

**3. Template.** [`manual/coder-templates/kubernetes/`](manual/coder-templates/kubernetes/) is Coder state, not a Kubernetes object, so ArgoCD doesn't apply it. Change it in git first, merge, then push from `main`. Never edit it in the UI. A merged Renovate bump of its image also needs this push.

```sh
cd manual/coder-templates/kubernetes
coder templates push kubernetes --directory . --yes   # as an owner; the first push creates the template
coder templates versions list kubernetes              # new version is active
```

Existing workspaces keep their version until updated: `coder update <owner>/<workspace>` or **Update** in the UI. The home volume survives the update.

For daily use, log the CLI in as the daily user (`coder login`, then **Sign in with Dex**). `coder ssh <name>` only finds the logged-in user's workspaces; as another owner, use `<owner>/<name>`.

Smoke test after a template change:

```sh
coder create ws1 --template kubernetes --yes
coder ssh ws1 -- 'echo hello > ~/persist.txt'
coder stop ws1 --yes && coder start ws1 --yes
coder ssh ws1 -- cat ~/persist.txt                  # hello
coder delete ws1 --yes
kubectl -n coder-workspaces get pod,pvc             # nothing left
```

Every build, stop and delete included, runs `terraform init`, which fetches provider checksums from registry.terraform.io and github.com. A failure in "Initializing Terraform Directory" with a 5xx from GitHub is upstream: retry the build.

**4. Before merging a Coder bump.** Coder runs DB migrations at startup and has no down-migration. Back up the `data-postgres-0` volume in namespace `coder` first (Longhorn UI → Volumes → the `pvc-…` volume whose PVC is `data-postgres-0` → Create Backup), wait for it to finish, then merge. Coder chart bumps arrive as their own Renovate PR.

---

### GitHub App `homekube-agent` and `agent-sandbox` (human step)

Agents reach GitHub as the GitHub App `homekube-agent` (ADR-0019), installed only on the repos an agent may work on; for now that is `jangroth/agent-sandbox`, a public trivial codebase (public because rulesets on a personal account's private repos are enforced only with GitHub Pro).

**1. App.** GitHub → Settings → Developer settings → GitHub Apps → New GitHub App:

- Name `homekube-agent`, homepage `https://github.com/jangroth/agent-sandbox`, no callback or setup URL
- Webhook **inactive**
- Repository permissions: **Contents** read/write, **Pull requests** read/write, Metadata read; everything else no access
- Installable **only on this account**

**2. Install** (App → Install App → `jangroth`): **Only select repositories** → `agent-sandbox`. The installation ID is the number at the end of the resulting `/settings/installations/<id>` URL.

**3. Ruleset** on the default branch: PR with one approval (the App can't approve its own PR, so it's the owner's), stale approvals dismissed, no force push or deletion, empty bypass list.

```sh
gh api -X POST repos/jangroth/agent-sandbox/rulesets --input - <<'EOF'
{
  "name": "main: PR + owner approval",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "non_fast_forward" },
    { "type": "deletion" }
  ]
}
EOF
gh api repos/jangroth/agent-sandbox/rules/branches/main --jq '[.[].type]'   # pull_request, non_fast_forward, deletion
```

**4. Private key.** App → Credentials → Key pairs → New key. Store the `.pem` contents, App ID, Client ID and installation ID in the password manager as "GitHub App homekube-agent", verify (step 5), then delete the download. Not sealed yet: nothing in the cluster uses the key until the token minter of [Spec: Hermes drives Coder](https://github.com/jangroth/homekube/issues/115).

**5. Mint an installation token by hand** (also the verification). Tokens last one hour.

```sh
PEM=<path-to-pem> APP_ID=<app-id> INSTALLATION_ID=<installation-id>
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64)
jwt="$h.$p.$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$PEM" | b64)"
resp=$(curl -fsS -X POST -H "Authorization: Bearer $jwt" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")
jq -c '{permissions, repository_selection}' <<<"$resp"   # contents/pull_requests write, metadata read, selected
TOKEN=$(jq -r .token <<<"$resp")
curl -fsS -H "Authorization: Bearer $TOKEN" https://api.github.com/installation/repositories \
  | jq -c '[.repositories[].full_name]'                 # ["jangroth/agent-sandbox"]
# Revoke when done: curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" https://api.github.com/installation/token
```

#### Rotation

- **Private key**, make-before-break: create a new key, store it, mint a token with it (step 5), then delete the old key under Credentials → Key pairs. Tokens already minted stay valid until they expire.

---

### Aperture egress Tailscale key (human step)

Workspaces reach Aperture through one shared egress pod (ADR-0020), the only tailnet device on their behalf, tagged `tag:coder-workspaces`. The tag and its tests live in the tailnet policy file in the private `ai-gateway` repo.

**1. Auth key.** Tailscale admin console → Settings → Keys → Generate auth key: description `homekube coder-workspaces egress`, **reusable**, **not ephemeral** (the device must survive pod restarts), pre-approved, tag `tag:coder-workspaces`, 90-day expiry. Store it in the password manager as "Tailscale auth key (coder-workspaces egress)".

**2. Seal** (in a terminal; `read -s` needs a tty):

```sh
seal() { kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o json; }

read -s "TK?Tailscale auth key: "; echo
kubectl create secret generic aperture-egress-tailscale -n aperture-egress \
  --from-literal=TS_AUTHKEY="$TK" --dry-run=client -o json \
| seal > applications/wave-03-apps/aperture-egress/tailscale-authkey-sealedsecret.yaml
unset TK
```

#### Rotation

The key is only used for the first join: the pod keeps its tailnet identity in its state Secret, and tagged devices don't expire. An expired key therefore matters only when that state is lost (rebuild, deleted Secret). Then generate a new key as in step 1, reseal, merge, and restart the egress.

---

### OpenCode through the Aperture egress (human step)

`aperture-egress` (namespace `aperture-egress`) is one pod with two containers. `tailscale` joins the tailnet as `homekube-aperture-egress` in kernel mode with `--shields-up`. `nginx` serves plain HTTP on `aperture-egress.aperture-egress.svc:80` and proxies `/v1/` only (everything else is 404, so Aperture's connectors stay out of reach) to Aperture's tailnet IP `100.126.29.31` with `Host: ai.taild13083.ts.net`, unbuffered so streamed completions pass through. A NetworkPolicy admits only namespace `coder-workspaces`. Aperture sees every workspace as this one device.

The Coder template passes OpenCode its whole config in `OPENCODE_CONFIG_CONTENT`: one `openai-compatible` provider `aperture` at the egress, model `aperture/<model>` from the mutable **OpenCode model** parameter (default `qwen/qwen3.8-27b`, any Aperture model ID), `permission: allow`, no autoupdate, no sharing. Nothing is written to the home volume; the config is rebuilt on every start.

Things to know:

- Aperture's tailnet IP is pinned here (`aperture-egress/configmap.yaml`) and in Hermes's chart values; change both if it moves.
- A ConfigMap change doesn't restart the pod: `kubectl -n aperture-egress rollout restart deploy/aperture-egress`.
- The NetworkPolicy covers pods only: Cilium still admits node and hostNetwork traffic by default.
- `opencode run` exits 0 on an answer and 1 on an error (unknown model: Aperture's `no route found for model`; egress unreachable: `ECONNREFUSED` after about 11 retries).

**1. After merge.** ArgoCD syncs the egress. Check the device `homekube-aperture-egress` appears in the Tailscale admin console with `tag:coder-workspaces`. Then push the template as in [Coder](#coder-human-step) step 3 and update the workspace (`coder update <workspace>`).

**2. Checks** (`ws1` is any workspace on the new template version):

```sh
# Answers through Aperture, non-interactively, with an exit code
coder ssh ws1 -- 'opencode run "Reply with exactly PONG."; echo exit=$?'     # PONG, exit=0
coder ssh ws1 -- 'opencode run -m aperture/nope "Reply PONG."; echo exit=$?' # error, exit=1

# The model parameter switches the model (the header line shows it).
# UI: workspace → Settings → Parameters → OpenCode model = qwen/qwen3.8-flash, then restart.
coder ssh ws1 -- 'opencode run "Reply PONG." | head -3'                       # build · qwen/qwen3.8-flash

# Only workspaces reach the egress
coder ssh ws1 -- curl -s -o /dev/null -w '%{http_code}\n' http://aperture-egress.aperture-egress.svc/v1/models  # 200
kubectl run ae-probe -n default --rm -it --restart=Never --image=curlimages/curl -- \
  curl -m 5 -s -o /dev/null -w '%{http_code}\n' http://aperture-egress.aperture-egress.svc/v1/models        # 000

# No tailnet credential in coder-workspaces
kubectl -n coder-workspaces get secrets -o name                               # no tailscale Secret
coder ssh ws1 -- "tr '\0' '\n' </proc/1/environ | grep -c '^TS_'"            # 0
```

Change the model in the UI: CLI 2.38 against server 2.39 ignored `--parameter` on `coder update`, `restart` and `start`, while the API and UI apply it. Check the pod's environment (`/proc/1/environ`), not a session's: the Coder agent adds `TS_DEBUG_TRIM_WIREGUARD=false` to every session, a networking switch, not a credential.

Renovate's `kubernetes` manager tracks both images in `aperture-egress/deployment.yaml`. `tailscale/tailscale` bumps for the egress and Hermes's sidecar arrive as one grouped PR. To check the tracking without GitHub, run Renovate locally in extract-only mode from a clone in a Docker-shared directory:

```sh
docker run --rm -e LOG_LEVEL=debug -v "$PWD":/usr/src/app renovate/renovate \
  --platform=local --dry-run=extract 2>&1 | grep -E '"depName": "(nginxinc/nginx-unprivileged|tailscale/tailscale)"'
```

---

### Agent Vault for workspaces (human step)

Workspaces reach GitHub through the Agent Vault proxy (ADR-0012), which attaches the `homekube-agent` installation token; workspaces hold only a session token. One bundle and one session serve every workspace until per-task sessions arrive ([Spec: Hermes drives Coder](https://github.com/jangroth/homekube/issues/115)).

**1. Infisical UI** (default Agent Vault project, as for [Agent Vault proxy](#agent-vault-proxy-human-step)). The session token is shown once: store it in the password manager before closing the dialog.

- **Global variable** `GH_TOKEN_AGENT_SANDBOX`: the installation token for `agent-sandbox`. Both services reference it, so one edit updates both.
- **Access bundle** `coder-workspaces`, with services:
  - `github-git`: host `github.com`, methods `GET`, `POST`, no paths. Basic credential: username `x-access-token`, password `{{GH_TOKEN_AGENT_SANDBOX}}`.
  - `github-api`: host `api.github.com`, methods `GET`, `POST`, `PATCH`, `PUT`, `DELETE`, no paths. Bearer credential: header `Authorization`, prefix `Bearer`, value `{{GH_TOKEN_AGENT_SANDBOX}}`.
- **Session** on bundle `coder-workspaces`, label `coder-workspaces`, expiry **Never**. Store the **session token** as "Agent Vault session token (coder-workspaces bundle)".

**2. Seal the session** (in a terminal; `read -s` needs a tty):

```sh
seal() { kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o json; }

# The session token is the password half of the workspace's HTTPS_PROXY URL.
read -s "ST?Session token: "; echo
kubectl create secret generic agent-vault-session -n coder-workspaces \
  --from-literal=HTTPS_PROXY="http://x-agent-vault:${ST}@agent-vault-proxy.agent-vault.svc:17323" \
  --dry-run=client -o json \
| seal > applications/wave-03-apps/coder-extras/agent-vault-session-sealedsecret.yaml
unset ST
```

#### Rotation

- **GitHub token**: set `GH_TOKEN_AGENT_SANDBOX` to a token minted as in [GitHub App `homekube-agent`](#github-app-homekube-agent-and-agent-sandbox-human-step) step 5. The proxy picks it up within one poll interval (60s); workspaces are untouched.
- **Session**, make-before-break: create a new session on bundle `coder-workspaces`, store its token, reseal (step 2), merge, and recreate running workspaces. Once a new workspace's git operation shows `brokered`, revoke the old session. Revoking cuts every workspace off from GitHub, which is also the kill switch.

---

### Renovate PAT (human step)

`.github/workflows/renovate.yml` needs a `RENOVATE_TOKEN` repo secret to open PRs — not creatable by automation.

1. GitHub → Settings → Developer settings → Fine-grained tokens → new token
2. Repository access: only this repo (`jangroth/homekube-apps`)
3. Permissions: **Contents** (read/write), **Pull requests** (read/write), **Issues** (read/write) for the Dependency Dashboard — no `github-actions` manager is enabled, so no workflow-file permission is needed
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
