variable "resource_group_name" {
  type        = string
  description = "Name of the resource group (from shared module output)."
}

variable "location" {
  type        = string
  description = "Azure region (from shared module output)."
  default     = "westeurope"
}

variable "acr_login_server" {
  type        = string
  description = "Login server of the Container Registry (from shared module output: acr_login_server)."
}

variable "managed_identity_id" {
  type        = string
  description = "Resource ID of the user-assigned managed identity (from shared module output: managed_identity_id)."
}

variable "common_tags" {
  type = map(string)
  default = {
    project     = "module2-compute"
    environment = "dev"
    managed_by  = "terraform"
  }
}
