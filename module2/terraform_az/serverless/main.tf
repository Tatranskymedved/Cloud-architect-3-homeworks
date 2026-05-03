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

# ── App Service plan — Consumption (Y1 = true scale-to-zero) ─────────────────
resource "azurerm_service_plan" "functions" {
  name                = "asp-thumbnail-consumption"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = var.common_tags
}

# ── Function app ──────────────────────────────────────────────────────────────
resource "azurerm_linux_function_app" "thumbnail" {
  name                          = var.function_app_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  service_plan_id               = azurerm_service_plan.functions.id
  storage_account_name          = var.storage_account_name
  storage_uses_managed_identity = true

  # System-assigned identity → used for storage access (roles assigned below)
  # User-assigned identity  → grants AcrPull / Blob Reader from shared module
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # Connection string used by func CLI to upload the deployment package
    AzureWebJobsStorage            = var.storage_account_connection_string
    # Enable Oryx build — compiles Pillow native binaries against Linux runtime
    ENABLE_ORYX_BUILD              = "true"
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    # Disable Application Insights auto-instrumentation (not used in this lab)
    APPINSIGHTS_INSTRUMENTATIONKEY = ""
  }

  tags = var.common_tags
}

# ── Storage role assignments for the Function App's system-assigned identity ──
# Required when storage_uses_managed_identity = true
resource "azurerm_role_assignment" "func_blob_owner" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.thumbnail.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_queue_contributor" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.thumbnail.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_table_contributor" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_linux_function_app.thumbnail.identity[0].principal_id
}
