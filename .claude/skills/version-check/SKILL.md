# version-check — Component Version Audit

When invoked, enumerate all Helm chart versions pinned in `homekube-apps` (and optionally `homekube-main`) and compare each against the latest available version in its upstream repository. Produce a Markdown table flagging anything behind.

Run from the `homekube-apps` repo root. No arguments needed.

---

## Step 1 — Extract pinned Helm chart versions from homekube-apps

Run this Python snippet from the repo root:

```python
import yaml, glob

charts = []
for path in sorted(glob.glob('applications/**/*.yaml', recursive=True)):
    try:
        for doc in yaml.safe_load_all(open(path)):
            if not doc or doc.get('kind') != 'Application':
                continue
            spec = doc.get('spec', {})
            sources = spec.get('sources', []) or []
            single = spec.get('source')
            if single:
                sources = [single] + sources
            for src in sources:
                if src and src.get('chart'):
                    charts.append({
                        'app':     doc['metadata']['name'],
                        'chart':   src['chart'],
                        'repoURL': src['repoURL'].rstrip('/'),
                        'pinned':  src['targetRevision'],
                        'file':    path,
                    })
    except Exception:
        pass

for c in charts:
    print(f"{c['chart']:35s} {c['pinned']:15s} {c['repoURL']}")
```

---

## Step 2 — Fetch latest versions from upstream Helm repos

For each **unique** `repoURL`, fetch its `index.yaml` once and look up the latest version for each chart from that repo:

```bash
curl -sS --max-time 15 "<repoURL>/index.yaml" > /tmp/helm-index.yaml
```

Then parse with Python:

```python
import yaml

with open('/tmp/helm-index.yaml') as f:
    index = yaml.safe_load(f)

# entries are sorted newest-first; take [0].version
latest = {name: entries[0]['version'] for name, entries in index.get('entries', {}).items() if entries}
```

Group charts by `repoURL` so each index is fetched at most once.

---

## Step 3 — Check homekube-main Ansible vars (optional)

If a `homekube-main` checkout is present (check `../homekube-main`), look for version-pinning variables:

```bash
grep -r "_version\s*:" ../homekube-main/ansible/group_vars/ 2>/dev/null | grep -v "^#"
```

For each variable (e.g. `cilium_version`, `argocd_chart_version`), identify the upstream source — typically a GitHub repo — and check the latest release:

```bash
curl -sS --max-time 10 "https://api.github.com/repos/<owner>/<repo>/releases/latest" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])"
```

Known mappings:

| Variable | GitHub repo |
|----------|-------------|
| `cilium_version` | `cilium/cilium` |
| `argocd_chart_version` | `argoproj/argo-helm` (chart releases) |
| `argocd_version` | `argoproj/argo-cd` |

Extend the table as you find new variables.

---

## Step 4 — Report

Print a Markdown table for each scope:

### homekube-apps Helm charts

| Chart | App | Pinned | Latest | Status |
|-------|-----|--------|--------|--------|
| cert-manager | cert-manager | v1.20.2 | v1.21.0 | ⚠ behind |
| longhorn | longhorn | v1.11.2 | v1.11.2 | ✓ current |
| … | | | | |

### homekube-main Ansible vars (if checked)

| Variable | Pinned | Latest | Status |
|----------|--------|--------|--------|
| cilium_version | 1.17.0 | 1.17.3 | ⚠ behind |
| … | | | |

**Version comparison note:** strip a leading `v` before comparing (e.g. `v1.20.2` == `1.20.2`). Treat pre-release suffixes (`-rc`, `-beta`) as behind a matching stable release.

End with a one-line summary: **N current, M behind**.

---

## Step 5 — Next steps (optional)

If anything is behind, offer to open an issue in `jangroth/homekube` or to update the pinned version directly in the relevant Application manifest or Ansible var file. Don't auto-update without confirmation — version bumps touch live cluster state.
