variable "resource_group_name" {
  type        = string
  description = "Name of the resource group (from shared module output)."
}

variable "location" {
  type        = string
  description = "Azure region (from shared module output)."
  default     = "westeurope"
}

variable "function_app_name" {
  type        = string
  description = "Globally-unique Function App name, e.g. func-thumbnail-<your-suffix>."
}

variable "storage_account_name" {
  type        = string
  description = "Storage account name for the Function host (from shared module output: storage_account_name)."
}

variable "storage_account_id" {
  type        = string
  description = "Storage account resource ID (from shared module output: storage_account_id). Used for role assignments."
}

variable "storage_account_connection_string" {
  type        = string
  sensitive   = true
  description = "Storage account connection string — required by func CLI to upload the deployment package."
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
