output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "subnet_vm_id" {
  value = azurerm_subnet.vm.id
}

output "subnet_apps_id" {
  value = azurerm_subnet.apps.id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_id" {
  value = azurerm_container_registry.main.id
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_id" {
  value = azurerm_storage_account.main.id
}

output "managed_identity_id" {
  value = azurerm_user_assigned_identity.thumbnail.id
}

output "managed_identity_principal_id" {
  value = azurerm_user_assigned_identity.thumbnail.principal_id
}
