output "postgres_primary_fqdn" {
  value       = module.postgres.primary_fqdn
  description = "FQDN of the PostgreSQL primary server (public access, IP firewall protected)."
}

output "postgres_primary_server_name" {
  value       = module.postgres.primary_server_name
  description = "Short name of the primary Flexible Server — used in az postgres flexible-server commands."
}

output "postgres_replica_fqdn" {
  value       = module.postgres.replica_fqdn
  description = "FQDN of the PostgreSQL read replica (public access, IP firewall protected)."
}

output "redis_hostname" {
  value       = azurerm_redis_cache.redis.hostname
  description = "Hostname of the Redis cache (public access enabled, TLS port 6380, password required)."
}

output "storage_account_name" {
  value       = azurerm_storage_account.assets.name
  description = "Name of the Azure Storage account used for product assets."
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Name of the Key Vault — used in az keyvault commands."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "URI of the Key Vault where secrets (pg password, redis key, storage key) are stored."
}

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the resource group containing all module 5 resources."
}

output "location" {
  value       = azurerm_resource_group.rg.location
  description = "Azure region where all resources are deployed."
}

output "vnet_name" {
  value       = azurerm_virtual_network.vnet.name
  description = "Name of the Virtual Network."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server — use as the image prefix when tagging and pushing the Docker image."
}

output "acr_name" {
  value       = azurerm_container_registry.acr.name
  description = "ACR resource name — used in: az acr login --name <acr_name>"
}

output "api_url" {
  value       = var.container_image != "" ? "http://${azurerm_container_group.api[0].fqdn}:8000" : "ACI not deployed yet — push image to ACR and set container_image in terraform.tfvars, then re-apply."
  description = "Public URL of the FastAPI service on Azure Container Instances."
}
