variable "location" {
  type        = string
  description = "Azure region for the PostgreSQL servers."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that will contain the PostgreSQL servers."
}

variable "db_name" {
  type        = string
  default     = "catalog"
  description = "Name of the application database created on the primary."
}

variable "db_username" {
  type        = string
  description = "PostgreSQL administrator login name."
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL administrator password."
}

variable "my_ip" {
  type        = string
  description = "Student laptop public IP — added to the PostgreSQL firewall so VS Code and psql can connect directly. Run: (Invoke-RestMethod https://ifconfig.me/ip).Trim()"
}

variable "sku_name" {
  type        = string
  default     = "GP_Standard_D2s_v3"
  description = "SKU for both primary and replica. Read replicas require General Purpose or Memory Optimized tier — Burstable (B_*) is NOT supported. GP_Standard_D2s_v3 (2 vCores) is the cheapest GP SKU."
}

variable "pg_version" {
  type        = string
  default     = "15"
  description = "PostgreSQL major version."
}

variable "storage_mb" {
  type        = number
  default     = 32768
  description = "Storage size in MB for each server. Minimum is 32768 (32 GB) for Flexible Server."
}
