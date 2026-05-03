output "endpoint_url" {
  value       = "https://${azurerm_linux_function_app.thumbnail.default_hostname}/api/thumbnail"
  description = "POST this URL with a JPEG/PNG body to receive a 128x128 thumbnail."
}

output "function_app_name" {
  value       = azurerm_linux_function_app.thumbnail.name
  description = "Function App name — used with 'func azure functionapp publish' to deploy code."
}
