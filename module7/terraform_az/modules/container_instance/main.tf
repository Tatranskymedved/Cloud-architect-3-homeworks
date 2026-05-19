resource "azurerm_container_group" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  # checkov:skip=CKV_AZURE_44:public IP required for coursework; no VNet integration on ACI Basic
  ip_address_type     = "Public"
  os_type             = "Linux"
  dns_name_label      = var.name

  dynamic "image_registry_credential" {
    for_each = lookup(var.secure_environment_variables, "ACR_PASSWORD", "") != "" ? [1] : []
    content {
      server   = split("/", var.image)[0]
      username = var.registry_username
      password = lookup(var.secure_environment_variables, "ACR_PASSWORD", "")
    }
  }

  container {
    name   = "quote-api"
    image  = var.image
    cpu    = var.cpu
    memory = var.memory

    ports {
      port     = var.port
      protocol = "TCP"
    }

    environment_variables = var.environment_variables
    # Exclude ACR_PASSWORD from the running container's env — it is only needed for image pull.
    secure_environment_variables = { for k, v in var.secure_environment_variables : k => v if k != "ACR_PASSWORD" }
  }

  tags = var.tags
}
