variable "name" {
  type        = string
  description = "Name of the container group (must be unique within the resource group)."
}

variable "location" {
  type        = string
  description = "Azure region for the container group."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group in which to create the container group."
}

variable "image" {
  type        = string
  description = "Full container image reference, e.g. myacr.azurecr.io/quote-api:latest."
}

variable "registry_username" {
  type        = string
  default     = ""
  description = "ACR admin username (the registry name). Required when ACR_PASSWORD is in secure_environment_variables."
}

variable "cpu" {
  type        = number
  default     = 0.5
  description = "Number of vCPUs allocated to the container."
}

variable "memory" {
  type        = number
  default     = 0.5
  description = "Memory in GB allocated to the container."
}

variable "port" {
  type        = number
  default     = 8000
  description = "TCP port exposed by the container."
}

variable "environment_variables" {
  type        = map(string)
  default     = {}
  description = "Non-sensitive environment variables injected into the container."
}

variable "secure_environment_variables" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "Sensitive environment variables (e.g. connection strings, passwords). Never shown in terraform plan output."
}

variable "tags" {
  type    = map(string)
  default = {}
}
