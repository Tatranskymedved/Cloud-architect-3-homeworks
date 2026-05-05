# Azure Implementation — Module 5: Persistent Layer (Product Catalog API)

---

## Azure service mapping

| Homework component | Azure service | SKU / tier recommendation | Rationale |
|---|---|---|---|
| Redis cache | Azure Cache for Redis | Standard C1 (1 GB, replication, no SLA on Basic) | Standard tier provides a replica node and an SLA; Basic C0 has no replication and is not suitable for coursework that tests failover. C1 gives 1 GB RAM which is plenty for product JSON blobs. |
| PostgreSQL primary | Azure Database for PostgreSQL Flexible Server | General Purpose `GP_Standard_D2s_v3` (2 vCores, 8 GB) | General Purpose tier is required — read replicas are not supported on Burstable tier in current Azure API. Public access mode with IP firewall restricts connections to the student's laptop IP only. |
| PostgreSQL read replica | Azure Database for PostgreSQL Flexible Server (read replica) | Same SKU as primary (`GP_Standard_D2s_v3`) | A read replica in Flexible Server must be the same or larger SKU as the source. Same-region replica minimises replication lag for the lab. Each server gets its own IP firewall rule. |
| Object storage | Azure Blob Storage (StorageV2 general-purpose v2) | LRS redundancy | StorageV2 with LRS is the lowest-cost, most broadly compatible tier. The API generates SAS tokens for assets; SAS is native to the Azure Storage SDK. |
| Virtual network | Azure Virtual Network with subnets | N/A (free resource) | Redis and Blob Storage use Private Endpoints in a dedicated subnet. PostgreSQL uses public access mode (IP firewall) — no delegated subnet needed. |
| IP firewall — PostgreSQL | `azurerm_postgresql_flexible_server_firewall_rule` | N/A | Restricts public access to the student's laptop IP only. Both primary and replica each require their own firewall rule. No Private Endpoint — the FQDN resolves publicly, enabling direct psql / VS Code access. |
| Private Endpoint — Redis | `azurerm_private_endpoint` targeting the Redis cache | N/A | Disables public access to the Redis cluster. Requires `public_network_access_enabled = false` on the cache resource. |
| Private Endpoint — Blob Storage | `azurerm_private_endpoint` targeting the storage account (`blob` sub-resource) | N/A | The SAS token grants time-limited access; the private endpoint ensures the FastAPI container reaches Blob without traversing the public internet. |
| Container registry | Azure Container Registry | Basic SKU | Stores the catalog-api Docker image. Admin credentials are enabled so ACI can pull without a Managed Identity. Basic SKU is sufficient for a single image used in a lab. |
| Container runtime | Azure Container Instances (ACI) | 0.5 vCPU / 1 GB, public IP | ACI is the simplest Azure container runtime — no cluster, no ingress controller. A public IP with DNS label exposes port 8000 directly. Environment variables and secure environment variables are injected by Terraform, eliminating the need for Key Vault references at runtime. |
| Secrets store | Azure Key Vault | Standard tier | Stores Redis primary access key, storage account key, and ACR admin password. Accessed by the deployer via az CLI during infrastructure setup. Runtime secrets are injected directly as ACI secure environment variables. |
| DNS resolution (Private Endpoints) | Azure Private DNS Zones | N/A (free zone, small per-query cost) | Required so that the private endpoint FQDNs resolve correctly inside the VNet. Each service needs its own zone (see resource definitions below). |

---

## Architecture diagram (text)

```
                              Internet
                                  │
          ┌───────────────────────┼───────────────────────────┐
          │ Your Laptop           │                           │
          │ psql / VS Code        │ HTTP :8000                │
          └──── SQL :5432 ────────┘    (curl / browser)       │
                     │                         │               │
                     │           ┌─────────────▼─────────────┐│
                     │           │  Azure Container Instances ││
                     │           │  catalog-api               ││
                     │           │  0.5 vCPU / 1 GB           ││
                     │           │  <prefix>.northeurope.     ││
                     │           │  azurecontainer.io:8000    ││
                     │           └──┬──────────┬──────────┬───┘│
                     │      writes  │    reads │  SAS     │     │
                     │    (POST/    │    (GET) │  tokens  │     │
                     │   PUT/DEL)   ▼          │          ▼     │
                     │  ┌─────────────────┐    │   ┌───────────────────┐
                     │  │  PostgreSQL     │    │   │  Blob Storage     │
                     │  │  Flexible Server│    │   │  StorageV2  LRS   │
                     │  │  GP_D2s_v3      │    │   │  images/{id}.jpg  │
                     │  │                 │    │   │  datasheets/      │
                     │  │  ┌───────────┐  │    │   │  {id}.pdf         │
                     └─►│  │ PRIMARY   │  │    │   │  served via       │
                        │  │ :5432     │  │    │   │  15-min SAS tokens│
                        │  │ pub. FQDN │  │    │   │  + PE (in-VNet)   │
                        │  │ firewall: │  │    │   └───────────────────┘
                        │  │ •studentIP│  │    │
                        │  │ •AzureSvcs│  │    │   ┌───────────────────┐
                        │  └─────┬─────┘  │    └──►│  Redis  Std C1    │
                        │  async │ repl.  │        │  :6380  TLS 1.2   │
                        │        ▼        │        │  password required │
                        │  ┌───────────┐  │        │  + PE (in-VNet)   │
                        │  │ REPLICA   │  │        └───────────────────┘
                        │  │ :5432     │  │
                        │  │ pub. FQDN │  │  ┌──────────────────────────┐
                        │  │ firewall: │  │  │  VNet  10.0.0.0/16       │
                        │  │ •studentIP│  │  │  subnet-endpoints        │
                        │  │ •AzureSvcs│  │  │  10.0.3.0/24             │
                        │  └───────────┘  │  │  ├── PE → Redis          │
                        └─────────────────┘  │  └── PE → Blob Storage   │
                                             └──────────────────────────┘
        ┌─────────────────────────┐   ┌──────────────────────────────────┐
        │  Container Registry     │   │  Key Vault  Standard             │
        │  Basic SKU              │   │  redis-primary-key               │
        │  catalog-api:latest     │   │  storage-account-key             │
        │  (ACI pulls on startup) │   │  acr-admin-password              │
        └─────────────────────────┘   └──────────────────────────────────┘
```

---

## Terraform file structure

```
homeworks/module5/terraform/
├── main.tf                         # root module — calls all child modules, wires outputs
├── variables.tf                    # input variables (location, prefix, admin password, etc.)
├── outputs.tf                      # exports FQDNs, storage account name, key vault URI
├── versions.tf                     # required_providers + terraform version constraint
├── terraform.tfvars.example        # non-secret example values (committed)
├── terraform.tfvars                # actual values including secrets (gitignored)
│
├── modules/
│   └── postgres_with_replica/      # reusable module (Exercise Task 7)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
└── scripts/
    └── write_load.ps1              # 200-INSERT load script for replication lag test (PowerShell)
```

---

## Terraform resource definitions

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"   # pin to 3.x; azurerm 4.x has breaking changes
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Do not purge Key Vault on destroy — avoids accidental data loss in lab
      purge_soft_delete_on_destroy = false
    }
  }
}
```

---

### `variables.tf`

```hcl
variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all resources."
}

variable "prefix" {
  type        = string
  default     = "catalog"
  description = "Short prefix used in resource names (lowercase, no spaces)."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-module5-catalog"
}

variable "pg_admin_username" {
  type    = string
  default = "pgadmin"
}

variable "pg_admin_password" {
  type        = string
  sensitive   = true
  # Dev/test default — satisfies Azure password requirements (upper + lower + digit + special).
  # Change this for any real deployment.
  default     = "PostgreSQL@Module5"
  description = "PostgreSQL administrator password."
}

variable "my_ip" {
  type        = string
  description = "Your laptop's public IP — added to the PostgreSQL firewall so VS Code and psql can connect directly. Run: (Invoke-RestMethod https://ifconfig.me/ip).Trim()"
}

variable "pg_db_name" {
  type    = string
  default = "catalog"
}
```

---

### `main.tf` (root module — annotated)

```hcl
# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ── Virtual Network ───────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# App subnet — reserved for optional container runtime (Container Apps / ACI)
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

# ── Private DNS Zones (Redis and Blob only — PostgreSQL uses public access) ───
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

# ── PostgreSQL Primary + Replica (child module) ───────────────────────────────
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

# ── Azure Cache for Redis ─────────────────────────────────────────────────────
resource "azurerm_redis_cache" "redis" {
  name                = "${var.prefix}-redis"   # must be globally unique
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  capacity = 1          # C1 = 1 GB
  family   = "C"        # C = Standard/Basic; P = Premium
  sku_name = "Standard" # Standard tier includes a standby replica

  # Enforce TLS — Redis on Azure only supports TLS 1.2+
  enable_non_ssl_port = false
  minimum_tls_version = "1.2"

  # Disable public network access — all traffic must go through the Private Endpoint
  public_network_access_enabled = false

  redis_configuration {
    # maxmemory-policy: allkeys-lru is a safe default for a cache-aside workload
    maxmemory_policy = "allkeys-lru"
  }
}

# Private Endpoint for Redis
resource "azurerm_private_endpoint" "redis" {
  name                = "${var.prefix}-redis-pe"
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
}

# ── Azure Blob Storage ────────────────────────────────────────────────────────
resource "azurerm_storage_account" "assets" {
  name                     = "${var.prefix}assets"  # 3–24 chars, lowercase alphanumeric, globally unique
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"             # homework spec: LRS
  account_kind             = "StorageV2"

  # Disable public blob access — assets are served only via SAS tokens
  allow_nested_items_to_be_public = false

  # Disable public network access to the account itself
  public_network_access_enabled = false

  # Require HTTPS (TLS) for all requests
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"
}

resource "azurerm_storage_container" "images" {
  name                  = "images"
  storage_account_name  = azurerm_storage_account.assets.name
  container_access_type = "private"   # no anonymous access; SAS tokens required
}

resource "azurerm_storage_container" "datasheets" {
  name                  = "datasheets"
  storage_account_name  = azurerm_storage_account.assets.name
  container_access_type = "private"
}

# Private Endpoint for Blob Storage
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
}

# ── Azure Key Vault ───────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = "${var.prefix}-kv"   # 3–24 chars, globally unique
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # Soft-delete is mandatory in Azure since 2021; keep purge protection off for the lab
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  # Use Azure RBAC for access control (preferred over legacy access policies)
  enable_rbac_authorization = true
}

# Store the PostgreSQL admin password in Key Vault
resource "azurerm_key_vault_secret" "pg_password" {
  name         = "pg-admin-password"
  value        = var.pg_admin_password
  key_vault_id = azurerm_key_vault.kv.id

  # The Terraform deployer needs Key Vault Secrets Officer role to write this secret.
  # Grant that role via azurerm_role_assignment (see Security notes section).
  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# Store the Redis primary access key
resource "azurerm_key_vault_secret" "redis_key" {
  name         = "redis-primary-key"
  value        = azurerm_redis_cache.redis.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# ── RBAC: Terraform deployer can write secrets ────────────────────────────────
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
```

---

### `modules/postgres_with_replica/variables.tf`

```hcl
variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "db_name" {
  type    = string
  default = "catalog"
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "my_ip" {
  type        = string
  description = "Student laptop public IP — added to the PostgreSQL firewall so VS Code and psql can connect directly. Run: (Invoke-RestMethod https://ifconfig.me/ip).Trim()"
}

variable "sku_name" {
  type        = string
  default     = "GP_Standard_D2s_v3"
  description = "SKU for both primary and replica. General Purpose tier is required for read replicas (Burstable tier is not supported)."
}

variable "pg_version" {
  type    = string
  default = "15"
}

variable "storage_mb" {
  type    = number
  default = 32768   # 32 GB minimum for Flexible Server
}
```

---

### `modules/postgres_with_replica/main.tf`

```hcl
# ── PostgreSQL Flexible Server — PRIMARY ──────────────────────────────────────
resource "azurerm_postgresql_flexible_server" "primary" {
  name                   = "${lower(replace(var.resource_group_name, "rg-", ""))}-pg-primary"
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.pg_version
  administrator_login    = var.db_username
  administrator_password = var.db_password

  # Public access mode — no delegated_subnet_id or private_dns_zone_id.
  # The server gets a public FQDN; access is restricted by the firewall rule below.

  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false   # lab: LRS backups only
}

# Firewall rule: allow only the student's laptop IP to connect to the primary
resource "azurerm_postgresql_flexible_server_firewall_rule" "primary_student" {
  name             = "student-laptop"
  server_id        = azurerm_postgresql_flexible_server.primary.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}

# Create the application database on the primary
resource "azurerm_postgresql_flexible_server_database" "app_db" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.primary.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ── PostgreSQL Flexible Server — READ REPLICA ─────────────────────────────────
resource "azurerm_postgresql_flexible_server" "replica" {
  name                = "${lower(replace(var.resource_group_name, "rg-", ""))}-pg-replica"
  resource_group_name = var.resource_group_name
  location            = var.location   # same-region replica

  # Replica mode: "Replica" skips admin credentials — they are inherited from source
  create_mode      = "Replica"
  source_server_id = azurerm_postgresql_flexible_server.primary.id

  # SKU must match or exceed the primary
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # Replication is asynchronous by default on Flexible Server
}

# Replica does NOT inherit firewall rules from the primary — add its own rule
resource "azurerm_postgresql_flexible_server_firewall_rule" "replica_student" {
  name             = "student-laptop"
  server_id        = azurerm_postgresql_flexible_server.replica.id
  start_ip_address = var.my_ip
  end_ip_address   = var.my_ip
}
```

---

### `modules/postgres_with_replica/outputs.tf`

```hcl
output "primary_fqdn" {
  value       = azurerm_postgresql_flexible_server.primary.fqdn
  description = "FQDN of the PostgreSQL primary server (public access, IP firewall protected)."
}

output "replica_fqdn" {
  value       = azurerm_postgresql_flexible_server.replica.fqdn
  description = "FQDN of the PostgreSQL read replica (public access, IP firewall protected)."
}

output "primary_server_id" {
  value = azurerm_postgresql_flexible_server.primary.id
}
```

---

### `outputs.tf` (root module)

```hcl
output "postgres_primary_fqdn" {
  value = module.postgres.primary_fqdn
}

output "postgres_replica_fqdn" {
  value = module.postgres.replica_fqdn
}

output "redis_hostname" {
  value = azurerm_redis_cache.redis.hostname
}

output "storage_account_name" {
  value = azurerm_storage_account.assets.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}
```

---

## Deployment walkthrough

### 1. Authenticate to Azure

```powershell
# Option A — interactive login (laptop/workstation)
az login
az account set --subscription "<your-subscription-id>"

# Option B — service principal (CI or shared lab environment)
$env:ARM_CLIENT_ID       = "<sp-app-id>"
$env:ARM_CLIENT_SECRET   = "<sp-secret>"
$env:ARM_TENANT_ID       = "<tenant-id>"
$env:ARM_SUBSCRIPTION_ID = "<subscription-id>"
```

### 2. Set your laptop IP for the PostgreSQL firewall

```powershell
# Get your current public IP and set it in terraform.tfvars
$MY_IP = (Invoke-RestMethod https://ifconfig.me/ip).Trim()
Write-Host "Set this in terraform.tfvars:  my_ip = `"$MY_IP`""
# Then edit terraform.tfvars and replace my_ip = "1.2.3.4" with the printed value
```

> **Note:** `pg_admin_password = "PostgreSQL@Module5"` is pre-set in `terraform.tfvars.example`
> for dev convenience — no need to generate or store a separate password file.

### 3. Initialise and validate

```powershell
cd homeworks/module5/terraform_az
terraform init
terraform validate
```

### 4. Plan and review

```powershell
terraform plan -out=tfplan
# Inspect the plan. Expected resource count: ~20–25 resources.
# Key things to verify in the plan:
#   - azurerm_postgresql_flexible_server.replica has create_mode = "Replica"
#   - azurerm_redis_cache has public_network_access_enabled = false
#   - azurerm_storage_account has public_network_access_enabled = false
```

### 5. Apply (Terminal 1) — and build the image in parallel (Terminal 2)

The first apply creates all infrastructure **except** ACI (which needs the image to exist in ACR first).
PostgreSQL + Redis take 25–35 minutes — use that time to build the Docker image in a second terminal.

**Terminal 1:**
```powershell
terraform apply tfplan
# PostgreSQL Flexible Server provisioning takes ~10 minutes.
# Redis Standard tier takes ~15–20 minutes.
# Total apply time: ~25–35 minutes.
```

**Terminal 2 — while Terminal 1 is running:**
```powershell
cd homeworks/module5/src
docker build -t catalog-api .
# Build takes ~1–2 minutes. It will be ready well before terraform apply finishes.
```

> ⚠️ **SESSION TIME NOTE:** This module cannot be completed in a 10-minute session. Plan for a **minimum 45–60 minute session**: ~25–35 min to provision, ~10–15 min to run the tests, and ~10–15 min for `terraform destroy`. Do not start this homework under time pressure.
>
> **Cost-saving alternative for Redis:** If provisioning speed is a priority, switching from `sku_name = "Standard"` to `sku_name = "Basic"` (C0, ~$16/month vs ~$55/month) cuts Redis provisioning to ~5–7 minutes and reduces cost by ~70%. The trade-off is no SLA and no Redis-level standby replica. This is acceptable for this homework because the failover exercise targets PostgreSQL, not Redis. To switch, change `sku_name = "Standard"` to `sku_name = "Basic"` in the `azurerm_redis_cache` resource — no other attributes need to change.

### 6. Push image to ACR and deploy ACI (single apply)

Once `terraform apply` from step 5 completes, ACR exists and you can push the pre-built image.
Set `container_image` in `terraform.tfvars` before the second apply so ACI is created in one shot.

```powershell
cd homeworks/module5/terraform_az

$ACR_NAME   = terraform output -raw acr_name
$ACR_SERVER = terraform output -raw acr_login_server

# Authenticate Docker to ACR
az acr login --name $ACR_NAME

# Tag and push the image built in step 5
docker tag catalog-api "$ACR_SERVER/catalog-api:latest"
docker push "$ACR_SERVER/catalog-api:latest"

# Set the image reference so ACI is included in the next apply
Add-Content terraform.tfvars "`ncontainer_image = `"$ACR_SERVER/catalog-api:latest`""

# Second apply — only creates the ACI container group (~2 minutes)
terraform apply -auto-approve

# Get the public API URL
terraform output -raw api_url
# e.g. http://catalog-api-lz3yus.northeurope.azurecontainer.io:8000
```

Wait for the container to start (~30–60 seconds) and verify it is healthy:

```powershell
# Stream startup logs — wait until you see "Application startup complete."
$RG = terraform output -raw resource_group_name
az container logs --resource-group $RG --name catalog-api --follow
```

> The app runs `_ensure_schema()` at startup which issues `CREATE TABLE IF NOT EXISTS products ...`.
> **The table does not exist until the container has started at least once.** Seed data (step 7)
> must be inserted only after the app logs `Schema ready`.

### 7. Verify access model

```powershell
# All terraform output commands must be run from homeworks/module5/terraform_az/

# PostgreSQL — publicly reachable (IP-restricted to your laptop + Azure services):
Test-NetConnection -ComputerName (terraform output -raw postgres_primary_fqdn) -Port 5432
# Expected: TcpTestSucceeded : True

# Redis — publicly reachable (TLS + password required, no anonymous access):
Test-NetConnection -ComputerName (terraform output -raw redis_hostname) -Port 6380
# Expected: TcpTestSucceeded : True

# API health check:
$API = terraform output -raw api_url
Invoke-WebRequest "$API/healthz"
# Expected: {"status":"ok"}

# Connect to PostgreSQL directly from your laptop:
$env:PGPASSWORD = "PostgreSQL@Module5"
$PRIMARY = terraform output -raw postgres_primary_fqdn
psql "host=$PRIMARY port=5432 user=pgadmin dbname=catalog sslmode=require" -c "\l"
```

### 8. Seed initial data

Once the app is running and `Schema ready` appears in the logs, insert a sample product row:

```powershell
cd homeworks/module5/terraform_az
$env:PGPASSWORD = "PostgreSQL@Module5"
$PRIMARY = terraform output -raw postgres_primary_fqdn

psql "host=$PRIMARY port=5432 user=pgadmin dbname=catalog sslmode=require" `
    -c "INSERT INTO products (name, description, price, stock_level) VALUES ('Widget Pro', 'A high-quality widget', 29.99, 100);"
```

### 9. Upload sample assets

```powershell
$SA = terraform output -raw storage_account_name

az storage blob upload `
    --account-name $SA `
    --container-name images `
    --name "1.jpg" `
    --file ".\sample_image.jpg" `
    --auth-mode login

az storage blob upload `
    --account-name $SA `
    --container-name datasheets `
    --name "1.pdf" `
    --file ".\sample_datasheet.pdf" `
    --auth-mode login
```

> **Note:** `--auth-mode login` uses your `az login` identity. The Terraform deployment grants your identity `Storage Blob Data Contributor` on this account, so no additional role assignment is needed.

### 10. Test cache-aside behavior

```powershell
$API = terraform output -raw api_url

# First call — expect X-Cache: MISS
$r1 = Invoke-WebRequest "$API/products/1"
$r1.Headers["X-Cache"]   # prints: MISS

# Second call within 60 seconds — expect X-Cache: HIT
$r2 = Invoke-WebRequest "$API/products/1"
$r2.Headers["X-Cache"]   # prints: HIT
```

---

## Testing strategy

### Cache-aside verification (`X-Cache` header)

1. Flush Redis to start from a clean state:
   ```powershell
   redis-cli -h <redis_hostname> -p 6380 --tls -a <redis_primary_key> FLUSHALL
   ```
2. Issue `GET /products/1`. Verify response header `X-Cache: MISS` and confirm the product data is correct.
3. Issue `GET /products/1` again within 60 seconds. Verify response header `X-Cache: HIT`. Response time should be noticeably lower (Redis round-trip vs. PostgreSQL round-trip).
4. Wait 61 seconds and issue `GET /products/1` again. Verify `X-Cache: MISS` (TTL expired).

### Read/write routing verification

1. Enable query logging on both the primary and replica by setting `log_statement = 'all'` via:
   ```sql
   ALTER SYSTEM SET log_statement = 'all';
   SELECT pg_reload_conf();
   ```
   Alternatively, inspect server logs in the Azure portal under **Monitoring > Logs** for the Flexible Server resource.
2. Flush Redis with `FLUSHALL`.
3. Issue five `POST /products` requests. Inspect FastAPI container logs — all lines should show the **primary** FQDN.
4. Issue five `GET /products/{id}` requests. Inspect container logs — all lines should show the **replica** FQDN. No SELECT statements should appear in the primary's query log.

### Replication lag measurement

Run the write load script while querying `pg_stat_replication` on the primary:

```powershell
# Terminal 1 — insert write load directly via psql
$env:PGPASSWORD = "PostgreSQL@Module5"
$PRIMARY = terraform output -raw postgres_primary_fqdn

1..200 | ForEach-Object {
    $price = [math]::Round((Get-Random -Min 1 -Max 999)/10.0, 2)
    psql "host=$PRIMARY port=5432 user=pgadmin dbname=catalog sslmode=require" `
        -c "INSERT INTO products (name,description,price,stock_level) VALUES ('Load $_','lag test',$price,10);"
    if ($_ % 20 -eq 0) { Write-Host "Inserted $_ / 200" }
}

# Terminal 2 — poll replication lag every 10 seconds while Terminal 1 runs
$env:PGPASSWORD = "PostgreSQL@Module5"
$PRIMARY = terraform output -raw postgres_primary_fqdn
while ($true) {
    psql "host=$PRIMARY port=5432 user=pgadmin dbname=catalog sslmode=require" `
        -c "SELECT client_addr, state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
    Start-Sleep -Seconds 10
}
```

Record the peak `replay_lag` value. A non-zero value during active write load confirms that asynchronous replication lag is measurable and observable.

### Failover simulation and recovery time measurement

```powershell
$RG           = terraform output -raw resource_group_name
$REPLICA_NAME = (terraform output -raw postgres_primary_server_name) -replace 'primary','replica'
$API          = terraform output -raw api_url

Get-Date

# Promote the replica to a standalone server (breaks replication — irreversible)
az postgres flexible-server replica promote `
    --resource-group $RG `
    --name $REPLICA_NAME `
    --promote-mode standalone `
    --promote-option forced

while ($true) {
    try {
        $status = (Invoke-WebRequest "$API/products/1" -ErrorAction Stop).StatusCode
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if (-not $status) { $status = "error" }
    }
    Write-Host "$(Get-Date -Format 'HH:mm:ss'): HTTP $status"
    if ($status -eq 200) { Write-Host "Recovered at $(Get-Date)"; break }
    Start-Sleep -Seconds 2
}
```

**Expected behavior:**
- After `promote --promote-mode standalone` is issued, the replica becomes an independent standalone server. The FastAPI service's primary connection will fail while the promotion completes (typically 1–5 minutes).
- The FastAPI service implements tenacity retry logic (max 5 retries, exponential backoff, 2 s base) and reconnects automatically without a manual restart.
- `promote --promote-mode standalone` is a one-way operation — the promoted server becomes independent and cannot be re-attached as a replica. After this exercise, `terraform destroy` will clean up both servers.

### SAS token expiry verification

```python
# Python snippet — generate a SAS token with 15-minute expiry using the Azure SDK
from datetime import datetime, timedelta, timezone
from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions

account_name = "<storage_account_name>"
account_key  = "<storage_account_key>"

sas_token = generate_blob_sas(
    account_name=account_name,
    container_name="images",
    blob_name="1.jpg",
    account_key=account_key,
    permission=BlobSasPermissions(read=True),
    expiry=datetime.now(timezone.utc) + timedelta(minutes=15)
)

url = f"https://{account_name}.blob.core.windows.net/images/1.jpg?{sas_token}"
print(url)
```

Verification steps:
1. Fetch the URL in a browser immediately — expect HTTP 200 and the image.
2. Wait 16 minutes (or set the expiry to 1 minute for a faster test cycle).
3. Fetch the URL again — expect HTTP 403 `AuthenticationFailed` with an `AuthenticationErrorDetail` indicating the SAS token has expired.

> **Note:** The storage account allows public network access (no `public_network_access_enabled = false`), so SAS URLs generated by the API are reachable directly in a browser from the student's laptop. Security is enforced by authentication (HTTPS-only, no anonymous access) and by the time-limited SAS token itself.

---

## Security and architecture notes

### Private Endpoints and network isolation

- **PostgreSQL Flexible Server** uses **public access mode** with an IP firewall rule. The FQDN resolves publicly, enabling direct psql and VS Code connectivity from the student's laptop. Only the IP address specified in `var.my_ip` is permitted — all other source IPs are rejected. SSL is enforced (`sslmode=require`). If the student's IP changes (different network, VPN toggle), update `my_ip` in `terraform.tfvars` and run `terraform apply -target=module.postgres` (~10 seconds).
- **Azure Cache for Redis** (Standard tier) has `public_network_access_enabled = true` so that the ACI container (which runs outside the VNet) can reach it over TLS port 6380 with a password. A Private Endpoint is also provisioned in the same subnet as Blob Storage, providing private routing for any workload running inside the VNet. Security is enforced by TLS 1.2 and the primary access key — no anonymous access is possible.
- **Azure Blob Storage** uses a Private Endpoint for the `blob` sub-resource. `public_network_access_enabled = false` prevents all access outside the VNet. SAS tokens are scoped to individual blobs with a short-lived expiry window; they do not expose the account key.

### Managed Identity and secret handling

- The FastAPI container (on Container Apps or App Service) is assigned a **system-assigned Managed Identity**.
- The Managed Identity is granted `Key Vault Secrets User` RBAC role on the Key Vault, allowing it to read secrets at runtime.
- **No static credentials appear in Terraform state** for application access: the PostgreSQL password and Redis key are stored in Key Vault and retrieved by the application at startup.
- The Terraform deployer's service principal is granted `Key Vault Secrets Officer` only during provisioning. This is a separate concern from the application identity.

### TLS enforcement

- PostgreSQL Flexible Server enforces SSL by default (`ssl_enforcement_enabled` is not a separate toggle in Flexible Server — SSL is always on). Use `sslmode=require` in the connection string.
- Redis: `enable_non_ssl_port = false` and port 6380 (TLS) is used. Port 6379 (plaintext) is disabled.
- Blob Storage: `https_traffic_only_enabled = true` rejects HTTP requests.

### Azure Well-Architected Framework alignment

| Pillar | Decision |
|---|---|
| **Security** | Redis and Blob Storage are network-isolated via Private Endpoints. PostgreSQL uses public access with IP firewall + SSL (acceptable for a dev lab where VNet reach is not guaranteed). Managed Identity eliminates static credentials for Key Vault access. SAS tokens scope blob access to read-only, short-lived windows. |
| **Reliability** | Redis Standard tier includes a standby replica. PostgreSQL read replica can be promoted on primary failure. Retry logic with exponential backoff handles transient connection errors. |
| **Cost Optimization** | GP_Standard_D2s_v3 for PostgreSQL is the minimum SKU that supports read replicas (~€0.19/hr per server). Redis Standard C1 (1 GB) is the smallest SKU that provides replication. LRS blob storage avoids GRS cost for ephemeral lab data. All resources should be torn down with `terraform destroy` after the lab. |
| **Operational Excellence** | All infrastructure is defined in Terraform; no manual portal steps are required for initial provisioning. `pg_stat_replication` provides observable replication lag without additional tooling. |
| **Performance Efficiency** | Cache-aside pattern with 60-second TTL eliminates repeated PostgreSQL round-trips for hot products. Read replica offloads SELECT traffic from the primary. |

---

## Known limitations and operational notes

1. **Dynamic IP edge case** — If the student's public IP changes (different network, VPN toggle, ISP lease renewal) while resources are running, PostgreSQL connections will fail with a timeout. Fix: update `my_ip` in `terraform.tfvars` and run `terraform apply -target=module.postgres` — this re-creates only the firewall rules (~10 seconds, no server restart).

2. **Failover and read-replica continuity** — This setup uses a **read replica without HA** (not an HA standby). Promoting the replica via `az postgres flexible-server replica promote --promote-mode standalone` is a one-way, irreversible operation — the promoted server becomes independent and replication cannot be re-established without creating a new replica. After the failover exercise, `terraform destroy` cleans up both servers.

3. **ACI cold-start** — Azure Container Instances takes ~30–60 seconds to pull the image from ACR and start the application. The `/healthz` endpoint will return connection errors until the FastAPI app logs `Application startup complete.`. Stream startup logs with `az container logs --follow` to know when the container is ready before seeding data or running tests.

4. **Redis Private Endpoint and `subresource_names`** — The `subresource_names = ["redisCache"]` value (camelCase) is correct for the Azure Cache for Redis private endpoint as of `azurerm ~> 3.x`. If you see a validation error on `terraform plan`, verify the correct sub-resource name with `az network private-link-resource list --name <redis-name> --resource-group <rg> --type Microsoft.Cache/Redis`.

5. **Storage account name uniqueness** — The name is generated with a random 6-character suffix (`${var.prefix}${random_string.storage_suffix.result}`) to ensure global uniqueness. The `storage_account_name` Terraform output gives the exact name to use in `.env` and CLI commands.

6. **`pg_stat_replication` visibility** — The `pg_stat_replication` view is only visible on the primary server to superusers or members of the `pg_monitor` role. The `pgadmin` administrator login created by Flexible Server has superuser-equivalent privileges, so this works out of the box. Students connecting to the *replica* will see an empty result (replicas do not expose this view for their own downstream; only the primary tracks its replicas).

7. **Terraform state contains the PostgreSQL password** — Even when `sensitive = true` is set, `var.pg_admin_password` is stored in the Terraform state file. The hardcoded dev password (`PostgreSQL@Module5`) is intentional for this lab. For production, use `random_password` and store only in Key Vault without ever setting it in `terraform.tfvars`.
