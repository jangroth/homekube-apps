terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.20"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }
}

provider "coder" {}

# In-cluster config from coderd's service account.
provider "kubernetes" {}

locals {
  namespace = "coder-workspaces"
  # renovate: datasource=docker depName=codercom/example-base
  image = "codercom/example-base:ubuntu-20261105"
  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
    "com.coder.resource"         = "true"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.workspace.name"   = data.coder_workspace.me.name
    "com.coder.user.id"          = data.coder_workspace_owner.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }
  ca_bundle = "/etc/coder-ca/bundle.crt"
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory limit"
  type         = "string"
  default      = "1Gi"
  mutable      = true
  option {
    name  = "1 GiB"
    value = "1Gi"
  }
  option {
    name  = "2 GiB"
    value = "2Gi"
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "arm64"

  metadata {
    display_name = "CPU"
    key          = "0_cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory"
    key          = "1_mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Home disk"
    key          = "2_home"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

# Survives stop (no count); removed with the workspace.
resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = local.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    security_context {
      run_as_user     = 1000
      run_as_group    = 1000
      fs_group        = 1000
      run_as_non_root = true
      seccomp_profile {
        type = "RuntimeDefault"
      }
    }

    affinity {
      node_affinity {
        required_during_scheduling_ignored_during_execution {
          node_selector_term {
            match_expressions {
              key      = "node-role.kubernetes.io/control-plane"
              operator = "DoesNotExist"
            }
          }
        }
      }
    }

    # System bundle plus homekube-ca, so curl and the agent trust coderd without root.
    init_container {
      name    = "ca-bundle"
      image   = local.image
      command = ["sh", "-c", "cat /etc/ssl/certs/ca-certificates.crt /etc/homekube-ca/homekube-ca.crt > ${local.ca_bundle}"]
      security_context {
        allow_privilege_escalation = false
        run_as_non_root            = true
      }
      resources {
        requests = {
          cpu    = "10m"
          memory = "16Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "64Mi"
        }
      }
      volume_mount {
        name       = "coder-ca"
        mount_path = "/etc/coder-ca"
      }
      volume_mount {
        name       = "homekube-ca"
        mount_path = "/etc/homekube-ca"
        read_only  = true
      }
    }

    container {
      name    = "dev"
      image   = local.image
      command = ["sh", "-c", coder_agent.main.init_script]

      # Container-level default (false) would override the pod's run_as_non_root.
      security_context {
        allow_privilege_escalation = false
        run_as_non_root            = true
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "SSL_CERT_FILE"
        value = local.ca_bundle
      }
      env {
        name  = "CURL_CA_BUNDLE"
        value = local.ca_bundle
      }

      resources {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "1"
          memory = data.coder_parameter.memory.value
        }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
      volume_mount {
        name       = "coder-ca"
        mount_path = "/etc/coder-ca"
        read_only  = true
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }
    volume {
      name = "coder-ca"
      empty_dir {}
    }
    volume {
      name = "homekube-ca"
      config_map {
        name = "homekube-ca"
      }
    }
  }
}
