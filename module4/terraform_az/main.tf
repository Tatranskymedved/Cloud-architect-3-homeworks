terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  required_version = ">= 1.5"
}

provider "azurerm" {
  features {}
  # Authentication via `az login` on a developer workstation.
  # For CI/CD use OIDC: set use_oidc = true and ARM_CLIENT_ID / ARM_SUBSCRIPTION_ID / ARM_TENANT_ID.
}

# ── Resource Group ────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = "module4-order-pipeline"
    managed_by  = "terraform"
  }
}

# ── Service Bus Namespace ─────────────────────────────────────────────────────

resource "azurerm_servicebus_namespace" "main" {
  name                = "${var.prefix}-sb-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.servicebus_sku

  # local_auth_enabled = true allows SAS-based connection strings (used in this homework).
  # Set to false in production and use managed identity instead.
  local_auth_enabled = true

  tags = azurerm_resource_group.main.tags
}

# ── Primary Orders Queue ──────────────────────────────────────────────────────

resource "azurerm_servicebus_queue" "orders" {
  name         = "orders"
  namespace_id = azurerm_servicebus_namespace.main.id

  # After max_delivery_count failed attempts the broker moves the message to the
  # built-in dead-letter sub-queue (orders/$DeadLetterQueue). No separate resource needed.
  max_delivery_count = var.queue_max_delivery_count

  dead_lettering_on_message_expiration = true
  default_message_ttl                  = "PT5M"

  # PT30S: enough headroom for Docker/Windows clock drift (~15–20 s is common).
  # DLQ test completes in ~3 × 30 s = 90 s — wait 2 min to be safe.
  lock_duration = "PT5M"

  requires_duplicate_detection = false
}

# ── Authorization Rule: Producer (Send only) ──────────────────────────────────

resource "azurerm_servicebus_queue_authorization_rule" "producer_send" {
  name     = "producer-send"
  queue_id = azurerm_servicebus_queue.orders.id

  send   = true
  listen = false
  manage = false
}

# ── Authorization Rule: Consumer + DLQ Handler (Listen only) ─────────────────

resource "azurerm_servicebus_queue_authorization_rule" "consumer_listen" {
  name     = "consumer-listen"
  queue_id = azurerm_servicebus_queue.orders.id

  send   = false
  listen = true
  manage = false
  # The Listen right also covers the orders/$DeadLetterQueue sub-queue —
  # no second authorization rule is needed for the DLQ Handler.
}
