output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the module6 resource group."
}

output "location" {
  value       = azurerm_resource_group.rg.location
  description = "Azure region. Used in az keyvault purge --location after destroy."
}

output "storage_account_name" {
  value       = azurerm_storage_account.lake.name
  description = "ADLS Gen2 storage account name. Use this in az storage blob upload-batch commands."
}

output "storage_account_key" {
  value       = azurerm_storage_account.lake.primary_access_key
  sensitive   = true
  description = "Primary access key for the ADLS account. Stored in Key Vault as adls-storage-key."
}

output "adf_name" {
  value       = azurerm_data_factory.adf.name
  description = "Azure Data Factory name. Use this in az datafactory pipeline create-run commands."
}

output "databricks_workspace_url" {
  value       = "https://${azurerm_databricks_workspace.dbw.workspace_url}"
  description = "URL of the Databricks workspace. Open in a browser to access notebooks."
}

output "databricks_workspace_id" {
  value       = azurerm_databricks_workspace.dbw.workspace_id
  description = "Numeric Databricks workspace ID."
}

output "aml_workspace_name" {
  value       = azurerm_machine_learning_workspace.aml.name
  description = "AML workspace name. Use with --workspace-name in az ml commands."
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Key Vault name. Update the databricks-pat-token secret here after workspace provisioning."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Key Vault URI. Used in ADF linked service configuration."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server. Used by AML to store training environment images."
}
