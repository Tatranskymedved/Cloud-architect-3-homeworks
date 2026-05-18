variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all resources."
}

variable "prefix" {
  type        = string
  default     = "retail"
  description = "Short prefix used in resource names (lowercase, no spaces, ≤ 8 chars)."
}

variable "resource_group_name" {
  type    = string
  default = "rg-module6-data"
}

variable "storage_suffix" {
  type        = string
  default     = ""
  description = "Optional extra suffix for the storage account name. Leave empty to use a random suffix."
}
