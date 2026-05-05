variable "location" {
  type        = string
  default     = "northeurope"
  description = "Azure region for all resources. northeurope (Ireland) is the recommended default — westeurope has PostgreSQL Flexible Server quota restrictions on many dev/free subscriptions."
}

variable "prefix" {
  type        = string
  default     = "catalog"
  description = "Short prefix used in resource names (lowercase, no spaces, no hyphens for storage account)."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-module5-catalog"
  description = "Name of the Azure resource group."
}

variable "pg_admin_username" {
  type        = string
  default     = "pgadmin"
  description = "PostgreSQL administrator login name."
}

variable "pg_admin_password" {
  type      = string
  sensitive = true
  # Dev/test default — satisfies Azure password requirements (upper + lower + digit + special).
  # Change this for any real deployment.
  default     = "PostgreSQL@Module5"
  description = "PostgreSQL administrator password."
}

variable "my_ip" {
  type        = string
  default     = "85.193.35.10"
  description = "Your laptop's public IP — added to the PostgreSQL firewall so VS Code and psql can connect directly. Run: (Invoke-RestMethod https://ifconfig.me/ip).Trim()"
}

variable "pg_db_name" {
  type        = string
  default     = "catalog"
  description = "Name of the application database created on the primary."
}

variable "container_image" {
  type        = string
  default     = ""
  description = "Full image reference for the catalog-api container (e.g. catalogXXXacr.azurecr.io/catalog-api:latest). Leave empty on the first apply — ACI is created only after the image is pushed to ACR."
}
