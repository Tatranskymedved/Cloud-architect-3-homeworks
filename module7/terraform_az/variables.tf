variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all resources."
}

variable "prefix" {
  type        = string
  default     = "quoteapi"
  description = "Short lowercase prefix used in resource names. Must be 3-8 alphanumeric characters (no hyphens — storage account names are derived from this)."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-module7-quoteapi"
  description = "Name of the Azure resource group to create."
}

variable "alert_email" {
  type        = string
  description = "Email address that receives Azure Monitor alert notifications. Set in terraform.tfvars."
}

variable "environment_tag" {
  type        = string
  default     = "module7"
  description = "Value for the 'environment' tag applied to all resources."
}

variable "owner_tag" {
  type        = string
  description = "Value for the 'owner' tag applied to all resources. Typically your student username."
}

variable "container_image" {
  type        = string
  default     = ""
  description = "Full image reference for the quote-api container, e.g. quoteapiacr123.azurecr.io/quote-api:latest. Leave empty on the first apply (before image is pushed); set after docker push."
}
