output "primary_fqdn" {
  value       = azurerm_postgresql_flexible_server.primary.fqdn
  description = "FQDN of the PostgreSQL primary server."
}

output "replica_fqdn" {
  value       = azurerm_postgresql_flexible_server.replica.fqdn
  description = "FQDN of the PostgreSQL read replica."
}

output "primary_server_id" {
  value       = azurerm_postgresql_flexible_server.primary.id
  description = "Resource ID of the primary Flexible Server."
}

output "replica_server_id" {
  value       = azurerm_postgresql_flexible_server.replica.id
  description = "Resource ID of the read replica Flexible Server."
}

output "primary_server_name" {
  value       = azurerm_postgresql_flexible_server.primary.name
  description = "Name of the primary Flexible Server (used in az postgres flexible-server commands)."
}
