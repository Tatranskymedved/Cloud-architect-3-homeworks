output "endpoint_url" {
  value       = "https://${azurerm_container_app.thumbnail.latest_revision_fqdn}/thumbnail"
  description = "POST this URL with a JPEG/PNG body to receive a 128x128 thumbnail."
}

output "container_app_fqdn" {
  value       = azurerm_container_app.thumbnail.latest_revision_fqdn
  description = "FQDN of the latest Container App revision."
}
