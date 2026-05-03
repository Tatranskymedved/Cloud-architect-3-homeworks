output "vm_public_ip" {
  value       = azurerm_public_ip.vm.ip_address
  description = "Public IP address of the VM."
}

output "endpoint_url" {
  value       = "http://${azurerm_public_ip.vm.ip_address}/thumbnail"
  description = "POST this URL with a JPEG/PNG body to receive a 128x128 thumbnail."
}

output "ssh_command" {
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.vm.ip_address}"
  description = "SSH command to connect to the VM."
}
