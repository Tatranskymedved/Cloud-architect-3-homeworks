terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ── Public IP ─────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "vm" {
  name                = "pip-thumbnail-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.common_tags
}

# ── Network interface ─────────────────────────────────────────────────────────
resource "azurerm_network_interface" "vm" {
  name                = "nic-thumbnail-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.common_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_vm_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ── Virtual machine ───────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "thumbnail" {
  name                = "vm-thumbnail"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  disable_password_authentication = true

  network_interface_ids = [azurerm_network_interface.vm.id]

  os_disk {
    name                 = "osdisk-thumbnail-vm"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init installs Python/Pillow/FastAPI and starts Gunicorn as a systemd service on port 80
  custom_data = filebase64("${path.module}/cloud-init.yaml")

  tags = var.common_tags
}
