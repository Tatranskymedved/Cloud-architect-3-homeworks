variable "resource_group_name" {
  type    = string
  default = "rg-thumbnail-dev"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "prefix" {
  type        = string
  default     = "thumbnail"
  description = "Short prefix used to derive globally-unique ACR and Storage Account names."

  validation {
    condition     = can(regex("^[a-z0-9-]{2,10}$", var.prefix))
    error_message = "prefix must be 2-10 lowercase alphanumeric characters or hyphens."
  }
}

variable "ssh_source_cidr" {
  type        = string
  description = "Your public IP in CIDR notation, e.g. 203.0.113.10/32. Used to restrict SSH access."
  default     = "0.0.0.0/0"
}

variable "common_tags" {
  type = map(string)
  default = {
    project     = "module2-compute"
    environment = "dev"
    managed_by  = "terraform"
  }
}
