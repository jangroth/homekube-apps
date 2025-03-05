# homekube-apps

ArgoCD apps for [homekube](https://github.com/jangroth/homekube).

## Init Wave

`argocd.argoproj.io/sync-wave: "-1"`

- [metallb](applications/metallb.yaml)

## First Wave

`argocd.argoproj.io/sync-wave: "1"`

- [test-lb](apps/test-llb.yaml)