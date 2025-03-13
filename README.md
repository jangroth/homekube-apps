# homekube-apps

ArgoCD apps for [homekube](https://github.com/jangroth/homekube).

## Init Wave

`argocd.argoproj.io/sync-wave: "-1"`

- [metallb](applications/wave-00-init/metallb.yaml)
- [metrics-server](applications/wave-00-init/metrics-server.yaml)
    - Note [TLS requirements for metrics-server](https://github.com/kubernetes-sigs/metrics-server#requirements). This cluster has [serverTLSBootstrap](https://github.com/jangroth/homekube/blob/2b68020e8e7af61f524a29f254e15908a9a24493/ansible/roles/kubeadm/files/kubeadm-config.yaml#L59) enabled for Kubelets.

## Apps Wave

`argocd.argoproj.io/sync-wave: "1"`

- [kubernetes-dashboard](applications/wave-01-apps/kubernetes-dashboard.yaml)
- [test-lb](applications/wave-01-apps/test-lb.yaml)
