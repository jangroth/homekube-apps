# Cloud environment

The claude.ai cloud environment the nightly routine runs in. These settings exist only in the environment config on claude.ai; this file records what they should be.

| Setting               | Value                                                   |
|-----------------------|---------------------------------------------------------|
| Name                  | `claude-code-homekube-apps`                             |
| Network access        | Custom: only the allowed domains below                  |
| Environment variables | None                                                    |
| Setup script          | `bash /home/user/homekube-apps/scripts/cloud/setup.sh`  |

## Allowed domains

```
github.com                 # git clone and push
api.github.com             # gh api calls for issues and PRs
raw.githubusercontent.com  # setup.sh reads kubernetes_version from homekube-main
dl.k8s.io                  # kubectl download
cdn.dl.k8s.io              # kubectl download (redirect target of dl.k8s.io)
```
