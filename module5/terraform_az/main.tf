# ── Resource Group ─────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = "dev"
    project     = "module5-persistent-layer"
    managed_by  = "terraform"
  }
}

# ── Virtual Network ────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = azurerm_resource_group.rg.tags
}

# App subnet — reserved for optional container runtime (App Service / Container Apps)
resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Subnet for Private Endpoints (Redis, Blob Storage)
resource "azurerm_subnet" "endpoints" {
  name                 = "subnet-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

# ── Private DNS Zones (Redis and Blob only — PostgreSQL uses public access) ────
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "redis-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

# ── PostgreSQL Primary + Replica (child module) ────────────────────────────────
# Public access mode: no delegated subnet or private DNS zone needed.
# Access is restricted to var.my_ip via firewall rules inside the module.
module "postgres" {
  source = "./modules/postgres_with_replica"

  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  db_name             = var.pg_db_name
  db_username         = var.pg_admin_username
  db_password         = var.pg_admin_password
  my_ip               = var.my_ip
}

# ── Azure Cache for Redis ──────────────────────────────────────────────────────
resource "azurerm_redis_cache" "redis" {
  name                = "${var.prefix}-redis-${random_string.storage_suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  capacity = 1
  family   = "C"
  sku_name = "Standard"

  minimum_tls_version = "1.2"
  # Public access enabled so the FastAPI container running locally can reach Redis.
  # Security is enforced by password auth + TLS 1.2 — no anonymous access.
  # The Private Endpoint still exists and provides private-only routing from within the VNet.
  public_network_access_enabled = true

  redis_configuration {
    maxmemory_policy = "allkeys-lru"
  }

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.prefix}-redis-${random_string.storage_suffix.result}-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.endpoints.id

  private_service_connection {
    name                           = "redis-psc"
    private_connection_resource_id = azurerm_redis_cache.redis.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.redis]
}

# ── Azure Blob Storage ─────────────────────────────────────────────────────────
resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "assets" {
  # Storage account names must be globally unique, 3–24 lowercase alphanumeric characters.
  name                     = "${var.prefix}${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  allow_nested_items_to_be_public = false
  # public_network_access_enabled is left at its default (true) so that Terraform
  # can reach the storage data-plane to create containers when running outside the
  # VNet.  The private endpoint still provides private-only routing for the FastAPI
  # app.  Security is enforced by authentication (no anonymous blobs, HTTPS-only,
  # TLS 1.2) rather than by blocking public network access at the account level.
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"
  # Explicitly keep shared key access enabled — main.py calls generate_blob_sas()
  # with account_key, which requires shared-key auth to be on.
  shared_access_key_enabled = true

  tags = azurerm_resource_group.rg.tags
}

# The azurerm provider uses Azure AD auth (not shared key) for storage
# data-plane calls by default in v3.x.  Grant the Terraform runner the
# minimum role required to create/read containers.
resource "azurerm_role_assignment" "deployer_storage_contributor" {
  scope                = azurerm_storage_account.assets.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "images" {
  name                  = "images"
  storage_account_name  = azurerm_storage_account.assets.name
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.deployer_storage_contributor]
}

resource "azurerm_storage_container" "datasheets" {
  name                  = "datasheets"
  storage_account_name  = azurerm_storage_account.assets.name
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.deployer_storage_contributor]
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.prefix}-blob-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.endpoints.id

  private_service_connection {
    name                           = "blob-psc"
    private_connection_resource_id = azurerm_storage_account.assets.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.blob]
}

# ── Azure Key Vault ────────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = "${var.prefix}-kv-${random_string.storage_suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  enable_rbac_authorization  = true

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "pg-admin-password"
  value        = var.pg_admin_password
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "redis_key" {
  name         = "redis-primary-key"
  value        = azurerm_redis_cache.redis.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "storage_key" {
  name         = "storage-account-key"
  value        = azurerm_storage_account.assets.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# ── Azure Container Registry ───────────────────────────────────────────────────
# Stores the catalog-api Docker image. Admin credentials are used by ACI to pull.
resource "azurerm_container_registry" "acr" {
  # ACR names: 5–50 lowercase alphanumeric, globally unique.
  name                = "${replace(var.prefix, "-", "")}${random_string.storage_suffix.result}acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true # required for ACI to pull using username/password

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_key_vault_secret" "acr_password" {
  name         = "acr-admin-password"
  value        = azurerm_container_registry.acr.admin_password
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# ── Azure Container Instances ──────────────────────────────────────────────────
# Deployed only once var.container_image is set (after image is pushed to ACR).
# Set container_image in terraform.tfvars after running: docker push <acr>/catalog-api:latest
resource "azurerm_container_group" "api" {
  count = var.container_image != "" ? 1 : 0

  name                = "${var.prefix}-api"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_address_type     = "Public"
  # FQDN: <dns_name_label>.<location>.azurecontainer.io
  dns_name_label = "${var.prefix}-api-${random_string.storage_suffix.result}"
  os_type        = "Linux"

  image_registry_credential {
    server   = azurerm_container_registry.acr.login_server
    username = azurerm_container_registry.acr.admin_username
    password = azurerm_container_registry.acr.admin_password
  }

  container {
    name   = "catalog-api"
    image  = var.container_image
    cpu    = "0.5"
    memory = "1.0"

    ports {
      port     = 8000
      protocol = "TCP"
    }

    environment_variables = {
      PG_PRIMARY_HOST       = module.postgres.primary_fqdn
      PG_REPLICA_HOST       = module.postgres.replica_fqdn
      PG_USER               = var.pg_admin_username
      PG_DB                 = var.pg_db_name
      PG_SSLMODE            = "require"
      PG_PORT               = "5432"
      REDIS_HOST            = azurerm_redis_cache.redis.hostname
      REDIS_PORT            = "6380"
      REDIS_TLS             = "true"
      AZURE_STORAGE_ACCOUNT = azurerm_storage_account.assets.name
    }

    secure_environment_variables = {
      PG_PASSWORD       = var.pg_admin_password
      REDIS_PASSWORD    = azurerm_redis_cache.redis.primary_access_key
      AZURE_STORAGE_KEY = azurerm_storage_account.assets.primary_access_key
    }
  }

  tags = azurerm_resource_group.rg.tags
}
