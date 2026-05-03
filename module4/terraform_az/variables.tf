variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "prefix" {
  description = "Short prefix used in all resource names. Must produce a globally unique Service Bus namespace name (<prefix>-sb-<environment>.servicebus.windows.net)."
  type        = string
  default     = "orderpipeline"
}

variable "environment" {
  description = "Environment label (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "servicebus_sku" {
  description = "Service Bus namespace SKU. Must be Standard or Premium to support dead-letter queues."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.servicebus_sku)
    error_message = "Basic SKU does not support dead-letter queues. Use Standard or Premium."
  }
}

variable "queue_max_delivery_count" {
  description = "Number of delivery attempts before the broker moves the message to the DLQ."
  type        = number
  default     = 3
}
