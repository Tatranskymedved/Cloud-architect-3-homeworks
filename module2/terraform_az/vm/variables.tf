variable "resource_group_name" {
  type        = string
  description = "Name of the resource group (from shared module output)."
}

variable "location" {
  type        = string
  description = "Azure region (from shared module output)."
  default     = "westeurope"
}

variable "subnet_vm_id" {
  type        = string
  description = "ID of subnet-vm (from shared module output: subnet_vm_id)."
}

variable "vm_size" {
  type        = string
  default     = "Standard_D2s_v6"
  description = "VM size (2 vCPU, 8 GB). Standard_B-series is blocked on free trial subscriptions. Check availability with: az vm list-skus --location <region> --size Standard_D2 --output table — pick any size where Restrictions is None."
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key string (e.g. contents of ~/.ssh/id_rsa.pub)."
}

variable "common_tags" {
  type = map(string)
  default = {
    project     = "module2-compute"
    environment = "dev"
    managed_by  = "terraform"
  }
}
