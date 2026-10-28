# homekube-apps nightly todo

Routine prompt stored here so it is versioned and reviewable.
The claude.ai routine config should contain only: `Follow the instructions in .claude/routines/nightly-todo.md please`

## Routine settings (as of 2026-10-28)

| Setting       | Value                                                  |
|---------------|--------------------------------------------------------|
| Name          | homekube-apps - nightly todo                           |
| Trigger ID    | trig_01P852NPoKhaxLW2pNwLoinN                          |
| Schedule      | `0 16 * * *` (UTC — 16:00 daily)                      |
| Model         | claude-sonnet-4-6                                      |
| Allowed tools | Default (all tools available in the cloud session)     |
| Repository    | jangroth/homekube-apps (branch: auto/issue-<n>-<slug>) |

## Prompt

Your task:

1. Fetch open GitHub issues directly from your tracker repository using the MCP GitHub tools or REST API (`gh api repos/jangroth/homekube/issues?state=open&labels=agent-safe,repo:homekube-apps`). Collect each issue's number, title, and body.

2. Fetch open PRs in the current application repository (`jangroth/homekube-apps`). Collect each PR's number, head branch name, and body.

3. Exclude any issue that already has an active PR. An issue is in flight if an open PR's branch matches `auto/issue-<number>-*` or its body contains a cross-repo closing keyword pointing to the tracker (e.g., `Closes jangroth/homekube#<number>` or `jangroth/homekube#<number>`).

4. Select one eligible issue at random. If no issues remain, exit cleanly with a short summary.

5. Spin up a new branch named `auto/issue-<number>-<slug>` from `main`.

6. Implement the fix based on the architecture rules outlined in this repo's CLAUDE.md file (App-of-Apps pattern, wave structure, Helm-values vs manifest ownership).

7. Validate that your Kubernetes configurations render successfully by running: `kubectl kustomize applications/`

8. Open a new pull request. In the PR description, ensure you include `Closes jangroth/homekube#<number>` to trigger cross-repo issue closing. Assign it to `jangroth` and mark it for human review. Do not auto-merge.
