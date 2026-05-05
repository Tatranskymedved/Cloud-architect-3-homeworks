terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }

    # Private DNS Zones sometimes outlive their VNet links during destroy,
    # causing the resource group deletion to fail with "still contains resources".
    # Setting this to false tells the provider to delete the RG directly via
    # the Azure API, which cascades the deletion to any remaining child resources.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
