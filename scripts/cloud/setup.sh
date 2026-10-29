#!/usr/bin/env bash
# Setup for the Claude Code cloud environment used by the nightly routine.
set -euo pipefail

version="$(curl -fsSL https://raw.githubusercontent.com/jangroth/homekube-main/main/ansible/group_vars/all.yml \
  | sed -n 's/^kubernetes_version: "\(.*\)"$/\1/p')"
[[ -n "$version" ]] || { echo "kubernetes_version not found" >&2; exit 1; }

arch="$(dpkg --print-architecture)"
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v${version}/bin/linux/${arch}/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client
