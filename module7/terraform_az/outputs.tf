output "staging_fqdn" {
  value       = var.container_image != "" ? module.quote_api_staging[0].fqdn : "ACI not deployed yet — set container_image in terraform.tfvars and re-apply"
  description = "Public FQDN for the staging ACI."
}

output "prod_fqdn" {
  value       = var.container_image != "" ? module.quote_api_prod[0].fqdn : "ACI not deployed yet — set container_image in terraform.tfvars and re-apply"
  description = "Public FQDN for the production ACI."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server hostname (used to tag and push images)."
}

output "acr_name" {
  value       = azurerm_container_registry.acr.name
  description = "ACR resource name (used by az acr login)."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Key Vault URI for manual secret verification."
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Key Vault name."
}

output "application_insights_instrumentation_key" {
  value       = azurerm_application_insights.ai.instrumentation_key
  sensitive   = true
  description = "App Insights instrumentation key (kept for compatibility; prefer connection_string)."
}

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the created resource group."
}
