terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ── Log Analytics workspace (required by Container Apps Environment) ──────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-thumbnail"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.common_tags
}

# ── Container Apps Environment ────────────────────────────────────────────────
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-thumbnail"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = var.common_tags
}

# ── Container App ─────────────────────────────────────────────────────────────
resource "azurerm_container_app" "thumbnail" {
  name                         = "ca-thumbnail"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.managed_identity_id
  }

  ingress {
    external_enabled = true
    target_port      = 80

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 3

    container {
      name   = "thumbnail"
      image  = "${var.acr_login_server}/thumbnail:latest"
      cpu    = 0.5
      memory = "1Gi"

      liveness_probe {
        path      = "/thumbnail"
        port      = 80
        transport = "HTTP"
      }
    }
  }
}
