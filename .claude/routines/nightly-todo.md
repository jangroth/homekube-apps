# Nightly todo routine

Run daily by the "homekube-apps - nightly todo" Claude Code routine. The routine prompt only points to this file.

## Routine settings

| Setting       | Value                                                                 |
|---------------|-----------------------------------------------------------------------|
| Trigger       | `trig_01P852NPoKhaxLW2pNwLoinN`                                       |
| Schedule      | `0 16 * * *` (16:00 UTC daily)                                        |
| Model         | claude-opus-5-5                                                       |
| Allowed tools | Bash, Read, Write, Edit, Glob, Grep, WebFetch, WebSearch              |
| Environment   | `claude-code-homekube-apps`, see [cloud-environment.md](cloud-environment.md)          |
| Source        | `jangroth/homekube-apps`                                              |

## Prompt

GraphQL is blocked in cloud sessions, so `gh issue list` / `gh pr list` fail; use `gh api` (REST).

1. Attach the tracker repo for API access: `add_repo` with owner `jangroth`, repo `homekube`, access `push`.
2. Fetch open issues labelled `agent-safe` and `repo:homekube-apps` from the tracker: `gh api "repos/jangroth/homekube/issues?state=open&labels=agent-safe,repo:homekube-apps&per_page=100" --jq '[.[] | {number, title, body}]'`
3. Fetch open PRs in this repo: `gh api "repos/jangroth/homekube-apps/pulls?state=open&per_page=100" --jq '[.[] | {number, branch: .head.ref, body}]'`
4. Exclude issues already in flight. An issue is in flight if an open PR's branch matches `auto/issue-<number>-*` or its body references it (e.g. `Closes jangroth/homekube#<number>` or `jangroth/homekube#<number>`).
5. Pick one remaining issue at random. If none are eligible, exit cleanly with a summary of what was checked.
6. Create a new branch named `auto/issue-<number>-<slug>` from `origin/main`.
7. Implement the fix according to the rules in CLAUDE.md (App-of-Apps pattern, wave structure, Helm-values vs manifest ownership).
8. Run `kubectl kustomize applications/` to verify the manifests render.
9. Open a PR with `Closes jangroth/homekube#<number>` in the body. Assign it to jangroth and mark it for human review. Do not auto-merge.
10. Do not modify this file, `cloud-environment.md` or `scripts/cloud/setup.sh` unless the issue explicitly asks for it.
