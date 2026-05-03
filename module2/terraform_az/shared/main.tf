terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3"
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

provider "random" {}

# Suffix for globally-unique resource names (ACR, Storage Account)
resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

locals {
  prefix_clean = replace(var.prefix, "-", "")
  acr_name     = "acr${local.prefix_clean}${random_string.suffix.result}"
  sa_name      = "st${local.prefix_clean}${random_string.suffix.result}"
}

# ── Resource group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
}

# ── Virtual network ───────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "vnet-thumbnail"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
  tags                = var.common_tags
}

resource "azurerm_subnet" "vm" {
  name                 = "subnet-vm"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "apps" {
  name                 = "subnet-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── Network security group (VM subnet) ───────────────────────────────────────
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-thumbnail-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.common_tags

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ── Container Registry ────────────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.common_tags
}

# ── Storage account (function host + test images) ─────────────────────────────
resource "azurerm_storage_account" "main" {
  name                            = local.sa_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  tags                            = var.common_tags
}

resource "azurerm_storage_container" "test_images" {
  name                  = "test-images"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# ── User-assigned managed identity ───────────────────────────────────────────
resource "azurerm_user_assigned_identity" "thumbnail" {
  name                = "id-thumbnail"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.common_tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.thumbnail.principal_id
}

resource "azurerm_role_assignment" "storage_reader" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.thumbnail.principal_id
}
