# ── Random suffix for globally-unique resource names ──────────────────────────
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name_suffix    = var.storage_suffix != "" ? var.storage_suffix : random_string.suffix.result
  storage_name   = "${var.prefix}lake${local.name_suffix}"
  aml_store_name = "${var.prefix}amlst${local.name_suffix}"
  kv_name        = "${var.prefix}-kv-${local.name_suffix}"
  adf_name       = "${var.prefix}-adf-${local.name_suffix}"
  dbw_name       = "${var.prefix}-dbw-${local.name_suffix}"
  aml_name       = "${var.prefix}-aml-${local.name_suffix}"
  acr_name       = "${var.prefix}acr${local.name_suffix}"
  appins_name    = "${var.prefix}-appins-${local.name_suffix}"
}

# ── Resource Group ─────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ── Azure Data Lake Storage Gen2 ──────────────────────────────────────────────
# StorageV2 + hierarchical namespace (HNS) enables ADLS Gen2 semantics.
# Databricks mounts ADLS using the ABFS driver (abfss://); HNS is mandatory.
# HNS cannot be enabled after account creation — do not remove this flag.
resource "azurerm_storage_account" "lake" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

# ── Standard storage account for AML workspace ───────────────────────────────
# AML requires a standard Blob Storage account (no HNS) as its backing store.
# The ADLS Gen2 lake above (HNS=true) is used only for pipeline data.
resource "azurerm_storage_account" "aml_store" {
  name                     = local.aml_store_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
}

# Grant the Terraform deployer rights to create ADLS Gen2 filesystems.
# The azurerm provider uses Azure AD auth for storage data-plane calls by default —
# without this role the filesystem creates will fail with HTTP 403.
resource "azurerm_role_assignment" "deployer_lake_contributor" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "raw" {
  name               = "raw"
  storage_account_id = azurerm_storage_account.lake.id

  depends_on = [azurerm_role_assignment.deployer_lake_contributor]
}

resource "azurerm_storage_data_lake_gen2_filesystem" "processed" {
  name               = "processed"
  storage_account_id = azurerm_storage_account.lake.id

  depends_on = [azurerm_role_assignment.deployer_lake_contributor]
}

resource "azurerm_storage_data_lake_gen2_filesystem" "gold" {
  name               = "gold"
  storage_account_id = azurerm_storage_account.lake.id

  depends_on = [azurerm_role_assignment.deployer_lake_contributor]
}

# ── Azure Key Vault ───────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  enable_rbac_authorization  = true
}

# Grant the Terraform deployer rights to write secrets
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "adls_key" {
  name         = "adls-storage-key"
  value        = azurerm_storage_account.lake.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# Placeholder for the Databricks PAT token.
# Students update this secret manually after workspace provisioning (step 3 of the README).
resource "azurerm_key_vault_secret" "databricks_pat" {
  name         = "databricks-pat-token"
  value        = "REPLACE_ME_AFTER_DATABRICKS_PROVISIONING"
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ── Azure Data Factory ────────────────────────────────────────────────────────
resource "azurerm_data_factory" "adf" {
  name                = local.adf_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "adf_kv_reader" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

resource "azurerm_role_assignment" "adf_storage_contributor" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# ── Azure Databricks Workspace ────────────────────────────────────────────────
resource "azurerm_databricks_workspace" "dbw" {
  name                = local.dbw_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "premium"

  managed_resource_group_name = "${var.resource_group_name}-dbw-managed"

  tags = {
    module = "module6"
  }

  # Azure Databricks control plane injects internal tags at creation time.
  lifecycle {
    ignore_changes = [tags]
  }
}

# ── Application Insights (required by AML workspace) ─────────────────────────
resource "azurerm_application_insights" "appins" {
  name                = local.appins_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"

  # Azure auto-assigns a Log Analytics workspace_id in workspace-based regions.
  # Once set it cannot be removed, so ignore any drift on this field.
  lifecycle {
    ignore_changes = [workspace_id]
  }
}

# ── Container Registry (required by AML workspace) ───────────────────────────
resource "azurerm_container_registry" "acr" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ── Azure Machine Learning Workspace ─────────────────────────────────────────
# Passes the shared Key Vault so the resource group contains only one KV, not two.
resource "azurerm_machine_learning_workspace" "aml" {
  name                    = local.aml_name
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  application_insights_id = azurerm_application_insights.appins.id
  container_registry_id   = azurerm_container_registry.acr.id
  key_vault_id            = azurerm_key_vault.kv.id
  storage_account_id      = azurerm_storage_account.aml_store.id

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_role_assignment" "aml_storage_reader" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_workspace.aml.identity[0].principal_id
}

resource "azurerm_role_assignment" "aml_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_machine_learning_workspace.aml.identity[0].principal_id
}

# ── AML Compute Cluster ───────────────────────────────────────────────────────
# Scales to 0 when idle — no charges when not running a job.
resource "azurerm_machine_learning_compute_cluster" "cpu_cluster" {
  name                          = "cpu-cluster"
  location                      = azurerm_resource_group.rg.location
  vm_priority                   = "Dedicated"
  vm_size                       = "Standard_DS2_v2"
  machine_learning_workspace_id = azurerm_machine_learning_workspace.aml.id

  scale_settings {
    min_node_count                       = 0
    max_node_count                       = 2
    scale_down_nodes_after_idle_duration = "PT30M"
  }

  identity {
    type = "SystemAssigned"
  }
}

# Training jobs run as the CLUSTER's identity, not the workspace's identity.
# Without this assignment, DefaultAzureCredential() in train.py receives HTTP 403
# when reading Parquet from the gold container.
resource "azurerm_role_assignment" "cpu_cluster_storage_reader" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_compute_cluster.cpu_cluster.identity[0].principal_id
}
