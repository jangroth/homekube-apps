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
| Grafana | `observability` | 01 | (kube-prometheus subchart) | `192.168.86.243:80` |

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
