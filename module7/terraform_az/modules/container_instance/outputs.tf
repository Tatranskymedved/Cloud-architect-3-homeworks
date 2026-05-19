output "fqdn" {
  value       = azurerm_container_group.this.fqdn
  description = "Fully qualified domain name of the container group (public)."
}

output "ip_address" {
  value       = azurerm_container_group.this.ip_address
  description = "Public IP address of the container group."
}

output "cpu" {
  value       = azurerm_container_group.this.container[0].cpu
  description = "CPU allocation — used by terraform test assertions."
}

output "memory" {
  value       = azurerm_container_group.this.container[0].memory
  description = "Memory allocation in GB — used by terraform test assertions."
}
