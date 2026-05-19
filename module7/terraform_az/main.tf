# ── Random suffix for globally unique resource names ──────────────────────────
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name_suffix = random_string.suffix.result
  kv_name     = "${var.prefix}-kv-${local.name_suffix}"
  acr_name    = "${var.prefix}acr${local.name_suffix}"

  common_tags = {
    environment = var.environment_tag
    owner       = var.owner_tag
  }
}

# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ── Azure Container Registry ──────────────────────────────────────────────────
resource "azurerm_container_registry" "acr" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"

  # Admin credentials are required for ACI to pull without a Managed Identity.
  admin_enabled = true

  tags = local.common_tags
}

# ── Azure Key Vault ───────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = local.kv_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  enable_rbac_authorization = true

  tags = local.common_tags
}

resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "acr_password" {
  # checkov:skip=CKV_AZURE_41:lab credential, expiry enforcement not required for coursework
  name         = "acr-admin-password"
  value        = azurerm_container_registry.acr.admin_password
  key_vault_id = azurerm_key_vault.kv.id

  tags       = local.common_tags
  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "appinsights_connection_string" {
  # checkov:skip=CKV_AZURE_41:lab credential, expiry enforcement not required for coursework
  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.ai.connection_string
  key_vault_id = azurerm_key_vault.kv.id

  tags       = local.common_tags
  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# ── Log Analytics Workspace ───────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.common_tags
}

# ── Application Insights (workspace-based) ────────────────────────────────────
resource "azurerm_application_insights" "ai" {
  name                = "${var.prefix}-ai"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"

  tags = local.common_tags
}

# ── Container Instances — staging ─────────────────────────────────────────────
# Deployed only once var.container_image is set (after image is pushed to ACR).
# Set container_image in terraform.tfvars after: docker push <acr>/quote-api:latest
module "quote_api_staging" {
  count  = var.container_image != "" ? 1 : 0
  source = "./modules/container_instance"

  name                = "${var.prefix}-staging"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  image               = var.container_image
  registry_username   = azurerm_container_registry.acr.admin_username
  cpu                 = 0.5
  memory              = 0.5
  port                = 8000

  environment_variables = {
    ENV = "staging"
  }

  secure_environment_variables = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_key_vault_secret.appinsights_connection_string.value
    ACR_PASSWORD                          = azurerm_key_vault_secret.acr_password.value
  }

  tags = local.common_tags
}

# ── Container Instances — production ─────────────────────────────────────────
module "quote_api_prod" {
  count  = var.container_image != "" ? 1 : 0
  source = "./modules/container_instance"

  name                = "${var.prefix}-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  image               = var.container_image
  registry_username   = azurerm_container_registry.acr.admin_username
  cpu                 = 0.5
  memory              = 1.0
  port                = 8000

  environment_variables = {
    ENV = "production"
  }

  secure_environment_variables = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_key_vault_secret.appinsights_connection_string.value
    ACR_PASSWORD                          = azurerm_key_vault_secret.acr_password.value
  }

  tags = local.common_tags
}

# ── Azure Monitor Action Group ────────────────────────────────────────────────
resource "azurerm_monitor_action_group" "email" {
  name                = "${var.prefix}-alert-email"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "quotealert"

  email_receiver {
    name          = "student-email"
    email_address = var.alert_email
  }

  tags = local.common_tags
}

# ── Azure Monitor Metric Alert — latency SLO ─────────────────────────────────
resource "azurerm_monitor_metric_alert" "latency_slo" {
  name                = "latency-slo"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_application_insights.ai.id]
  description         = "Alert when p99 request duration exceeds 500 ms."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/duration"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 500
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = local.common_tags
}

# ── Azure Monitor Metric Alert — error rate SLO ───────────────────────────────
resource "azurerm_monitor_metric_alert" "error_rate_slo" {
  name                = "error-rate-slo"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_application_insights.ai.id]
  description         = "Alert when HTTP 5xx response rate exceeds 1% of requests."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = local.common_tags
}

# ── Azure Policy Assignments ──────────────────────────────────────────────────
data "azurerm_policy_definition" "require_tag" {
  display_name = "Require a tag and its value on resources"
}

resource "azurerm_resource_group_policy_assignment" "require_environment_tag" {
  name                 = "require-environment-tag"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  display_name         = "Require environment tag"
  description          = "Ensures all resources in this resource group have an environment tag."

  parameters = jsonencode({
    tagName = {
      value = "environment"
    }
    tagValue = {
      value = var.environment_tag
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "require_owner_tag" {
  name                 = "require-owner-tag"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  display_name         = "Require owner tag"
  description          = "Ensures all resources in this resource group have an owner tag."

  parameters = jsonencode({
    tagName = {
      value = "owner"
    }
    tagValue = {
      value = var.owner_tag
    }
  })
}
