locals {
  # Derive a short base name from the resource group: strip the "rg-" prefix.
  base_name = lower(replace(var.resource_group_name, "rg-", ""))
}

# ── PostgreSQL Flexible Server — PRIMARY ───────────────────────────────────────
resource "azurerm_postgresql_flexible_server" "primary" {
  name                   = "${local.base_name}-pg-primary"
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.pg_version
  administrator_login    = var.db_username
  administrator_password = var.db_password

  # Public access mode — no delegated_subnet_id / private_dns_zone_id.
  # Access is restricted to var.my_ip via firewall rules below.

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  lifecycle {
    # Azure auto-assigns an availability zone when none is specified.
    # Ignore it to prevent Terraform from trying to change it on subsequent applies.
    ignore_changes = [zone]
  }
}

# Application database on the primary
resource "azurerm_postgresql_flexible_server_database" "app_db" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.primary.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ── PostgreSQL Flexible Server — READ REPLICA ──────────────────────────────────
resource "azurerm_postgresql_flexible_server" "replica" {
  name                = "${local.base_name}-pg-replica"
  resource_group_name = var.resource_group_name
  location            = var.location

  # create_mode = "Replica" inherits credentials from the source server.
  create_mode      = "Replica"
  source_server_id = azurerm_postgresql_flexible_server.primary.id

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  lifecycle {
    ignore_changes = [zone]
  }
}

# ── IP Firewall Rules ──────────────────────────────────────────────────────────
# Replica firewall rules are independent from the primary — they are NOT inherited.
# Both servers get the same student IP rule so reads (replica) and writes (primary)
# work directly from VS Code and psql on the student's laptop.

resource "azurerm_postgresql_flexible_server_firewall_rule" "primary_student" {
  name             = "student-laptop"
  server_id        = azurerm_postgresql_flexible_server.primary.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "replica_student" {
  name             = "student-laptop"
  server_id        = azurerm_postgresql_flexible_server.replica.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}

# Allow traffic from any Azure-hosted service (ACI, etc.).
# Azure's special sentinel: start = "0.0.0.0" / end = "0.0.0.0".
#
# IMPORTANT: depends_on replica, not just primary.
# When create_mode = "Replica" runs, Azure keeps the primary in a "busy"
# state while it initialises streaming replication.  Terraform would
# otherwise try to create these rules concurrently with the replica
# (both only need primary.id), hitting "ServerIsBusy" on the primary.
# Waiting for the replica to finish guarantees the primary is idle.
resource "azurerm_postgresql_flexible_server_firewall_rule" "primary_azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.primary.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_postgresql_flexible_server.replica]
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "replica_azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.replica.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"

  depends_on = [azurerm_postgresql_flexible_server.replica]
}
