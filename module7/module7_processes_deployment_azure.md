# Azure Implementation — Module 7: Processes and App Deployment (Quote API Pipeline)

---

## Azure service mapping

| Homework component | Azure service | SKU / tier | Rationale |
|---|---|---|---|
| Container registry | Azure Container Registry | Basic SKU | Stores the `quote-api` Docker image. Admin credentials are enabled so ACI can pull the image without a Managed Identity. Basic SKU supports one registry for a single-image lab at the lowest cost. |
| Container runtime — staging | Azure Container Instances | 0.5 vCPU / 0.5 GB, public IP | ACI is the simplest Azure container runtime — no cluster, no ingress controller. Staging uses the minimum viable resource allocation. A DNS label on the container group provides a stable FQDN for the deploy-workflow health check. |
| Container runtime — production | Azure Container Instances | 0.5 vCPU / 1 GB, public IP | Same container group pattern as staging; slightly more memory to represent the realistic difference between staging and production sizing. Deployed by the `07_deploy.yml` production job gated by manual approval. |
| CI/CD | GitHub Actions | N/A (SaaS) | The existing repository already uses GitHub Actions for all module build workflows. Three new workflow files are created from scratch in `.github/workflows/` — no additional tooling or cost. |
| Observability | Azure Application Insights | Workspace-based (classic is deprecated) | Receives request telemetry from both ACI instances via the `opencensus-ext-azure` Python SDK middleware. Transaction search and Live Metrics are the primary verification surfaces used in Exercise Task 5. |
| Log analytics | Azure Log Analytics Workspace | Pay-per-GB | Required by workspace-based Application Insights. In practice the ingestion cost for this lab is negligible (< 1 MB per session). |
| SLO alerts | Azure Monitor Metric Alert | Standard metric alert | Two alert rules on Application Insights metrics: p99 request duration and HTTP 5xx rate. Each rule references the same Action Group for email notification. Minimum evaluation granularity is 1 minute with a 5-minute window. |
| Alert notification | Azure Monitor Action Group | Email receiver | Sends an email to the student's address when an alert fires. Created as a Terraform resource; the email address is a Terraform variable. |
| Policy enforcement | Azure Policy assignment (built-in) | N/A (no cost) | The built-in policy `"Require a tag and its value on resources"` is assigned twice at resource-group scope: once for the `environment` tag and once for the `owner` tag. Compliance state is visible in the portal after a scan runs. |
| Secrets | Azure Key Vault | Standard tier | Stores the ACR admin password and the Application Insights connection string. Both secrets are injected into ACI via `secure_environment_variables` in Terraform — they never appear in workflow logs or Terraform plan output in plaintext. |

---

## Architecture diagram (text)

```
  Developer Laptop
  ┌──────────────┐
  │  git push    │
  │  git pr      │
  └──────┬───────┘
         │ push / PR
         ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │  GitHub                                                              │
  │                                                                      │
  │  PR to main ──► 07_iac_validate.yml                                  │
  │                  ├── terraform fmt --check                           │
  │                  ├── tflint                                          │
  │                  └── checkov                                         │
  │                                                                      │
  │  push to main ─► 07_app_build.yml                                    │
  │                  ├── pytest                                          │
  │                  ├── docker build                                    │
  │                  ├── trivy image (CRITICAL exit-code 1)              │
  │                  └── docker push ──────────────────────────────────┐ │
  │                                                                     │ │
  │  on: workflow_run ► 07_deploy.yml                                   │ │
  │      Job 1: terraform test                                          │ │
  │      Job 2: terraform apply (staging ACI) ──────────────────────┐  │ │
  │      Job 3: [manual approval] terraform apply (prod ACI) ─────┐ │  │ │
  └────────────────────────────────────────────────────────────────┼─┼──┼─┘
                                                                   │ │  │
                                    ┌──────────────────────────────┘ │  │
                                    │                                 │  │
                                    ▼                                 │  │
  ┌───────────────────────────────────────────┐                       │  │
  │  Azure Container Registry  (Basic SKU)    │◄──────────────────────┘  │
  │  <prefix>acr.azurecr.io                   │                          │
  │  quote-api:latest                         │◄─────────────────────────┘
  └──────────────────┬────────────────────────┘
                     │  image pull (admin credentials from Key Vault)
          ┌──────────┴───────────┐
          ▼                      ▼
  ┌────────────────┐    ┌─────────────────────┐
  │  ACI Staging   │    │  ACI Production      │
  │  quote-api-    │    │  quote-api-prod       │
  │  staging       │    │  0.5 vCPU / 1 GB     │
  │  0.5 vCPU /    │    │  <prefix>-prod.       │
  │  0.5 GB        │    │  northeurope.         │
  │  <prefix>-     │    │  azurecontainer.io    │
  │  staging.      │    │  :8000                │
  │  northeurope.  │    └──────────┬────────────┘
  │  azurecontainer│               │
  │  .io:8000      │               │ APPLICATIONINSIGHTS_CONNECTION_STRING
  └──────┬─────────┘               │ (secure env var from Key Vault)
         │                         │
         │ request telemetry       │ request telemetry
         └───────────┬─────────────┘
                     ▼
  ┌──────────────────────────────────────────┐
  │  Azure Application Insights              │
  │  (workspace-based)                       │
  │  Transaction search                      │
  │  Live Metrics                            │
  └─────────────────┬────────────────────────┘
                    │  metric feed
                    ▼
  ┌──────────────────────────────────────────┐
  │  Azure Monitor Metric Alerts             │
  │  latency-slo  (p99 > 500 ms)            │
  │  error-rate-slo (5xx rate > 1%)         │
  └─────────────────┬────────────────────────┘
                    │  fires
                    ▼
  ┌──────────────────────────────────────────┐
  │  Azure Monitor Action Group              │
  │  email: student@example.com              │
  └──────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │  Azure Key Vault  (Standard)                         │
  │  acr-admin-password  ──► ACI staging + prod (pull)  │
  │  appinsights-connection-string ──► ACI env var       │
  └──────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────┐
  │  Azure Policy (resource-group scope)                 │
  │  assignment: Require tag environment=module7         │
  │  assignment: Require tag owner=student               │
  └──────────────────────────────────────────────────────┘
```

---

## Terraform file structure

```
homeworks/module7/
├── terraform_az/
│   ├── versions.tf                      # required_providers, terraform version constraint
│   ├── variables.tf                     # all input variables with descriptions and defaults
│   ├── main.tf                          # root module: ACR, Key Vault, App Insights, ACI modules, alerts, policy
│   ├── outputs.tf                       # staging_fqdn, prod_fqdn, acr_login_server, etc.
│   ├── terraform.tfvars.example         # non-secret example values (committed to git)
│   ├── terraform.tfvars                 # actual values including secrets (gitignored)
│   └── modules/
│       └── container_instance/
│           ├── main.tf                  # azurerm_container_group resource
│           ├── variables.tf             # name, location, rg, image, cpu, memory, port, env vars
│           ├── outputs.tf               # fqdn, ip_address
│           └── container_instance.tftest.hcl   # terraform test assertions
├── src/
│   └── quote_api/
│       ├── main.py                      # FastAPI app, < 80 lines, opencensus middleware
│       ├── quotes.json                  # bundled quotes, at least 10 entries
│       ├── requirements.txt             # fastapi, uvicorn, opencensus-ext-azure, prometheus-client
│       ├── Dockerfile                   # FROM python:3.12-slim, COPY, pip install, CMD uvicorn
│       └── tests/
│           └── test_main.py             # pytest tests for all three endpoints
└── .github/
    └── workflows/
        ├── 07_iac_validate.yml          # PR gate: fmt check, tflint, checkov
        ├── 07_app_build.yml             # push to main: pytest, docker build, trivy, acr push
        └── 07_deploy.yml               # workflow_run: terraform test, staging apply, prod apply
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
      version = "~> 3.100"   # pin to 3.x; azurerm 4.x has breaking changes for ACI
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
      # Do not purge Key Vault on destroy — avoids the 90-day soft-delete name reservation
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
  default     = "quoteapi"
  description = "Short lowercase prefix used in resource names. Must be 3–8 characters, no hyphens (storage account names are derived from this)."
}

variable "resource_group_name" {
  type    = string
  default = "rg-module7-quoteapi"
}

variable "alert_email" {
  type        = string
  description = "Email address that receives Azure Monitor alert notifications."
  # Set this in terraform.tfvars — it is not a secret but is environment-specific.
}

variable "environment_tag" {
  type    = string
  default = "module7"
  description = "Value for the 'environment' tag applied to all resources."
}

variable "owner_tag" {
  type        = string
  description = "Value for the 'owner' tag applied to all resources. Typically your student username."
}
```

---

### `main.tf` (root module — annotated)

```hcl
# ── Local values ──────────────────────────────────────────────────────────────
# Common tags applied to every resource so Azure Policy compliance passes from the first apply.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name_suffix = random_string.suffix.result
  kv_name     = "${var.prefix}-kv-${local.name_suffix}"    # Key Vault: globally unique
  acr_name    = "${var.prefix}acr${local.name_suffix}"     # ACR: globally unique, alphanumeric

  common_tags = {
    environment = var.environment_tag
    owner       = var.owner_tag
  }
}

# ── Resource Group ────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ── Azure Container Registry ──────────────────────────────────────────────────
resource "azurerm_container_registry" "acr" {
  name                = local.acr_name   # must be globally unique, alphanumeric only
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"

  # Admin credentials are required for ACI to pull without a Managed Identity.
  # The password is stored in Key Vault and injected as a secure environment variable.
  admin_enabled = true

  tags = local.common_tags
}

# ── Azure Key Vault ───────────────────────────────────────────────────────────
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                = local.kv_name   # 3–24 chars, globally unique
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  soft_delete_retention_days = 7
  purge_protection_enabled   = false   # keep off for lab — allows destroy without waiting 90 days

  # RBAC authorization is preferred over legacy access policies
  enable_rbac_authorization = true

  tags = local.common_tags
}

# Grant the Terraform deployer the ability to read and write secrets
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Store ACR admin password in Key Vault
# checkov:skip=CKV_AZURE_41: lab credential, expiry enforcement not required for coursework
resource "azurerm_key_vault_secret" "acr_password" {
  name         = "acr-admin-password"
  value        = azurerm_container_registry.acr.admin_password
  key_vault_id = azurerm_key_vault.kv.id

  tags       = local.common_tags
  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# Store Application Insights connection string in Key Vault
# checkov:skip=CKV_AZURE_41: lab credential, expiry enforcement not required for coursework
resource "azurerm_key_vault_secret" "appinsights_connection_string" {
  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.ai.connection_string
  key_vault_id = azurerm_key_vault.kv.id

  tags       = local.common_tags
  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# ── Log Analytics Workspace ───────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"   # pay-per-GB; negligible cost for lab volumes
  retention_in_days   = 30

  tags = local.common_tags
}

# ── Application Insights (workspace-based) ────────────────────────────────────
resource "azurerm_application_insights" "ai" {
  name                = "${var.prefix}-ai"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"

  tags = local.common_tags
}

# ── Container Instances — staging ─────────────────────────────────────────────
# The image reference must be set after 07_app_build.yml has pushed at least one image.
# Set container_image_staging in terraform.tfvars before the first deploy.
module "quote_api_staging" {
  source = "./modules/container_instance"

  name                = "${var.prefix}-staging"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  image               = "${azurerm_container_registry.acr.login_server}/quote-api:latest"
  cpu                 = 0.5
  memory              = 0.5
  port                = 8000

  # Non-sensitive environment variables
  environment_variables = {
    ENV = "staging"
  }

  # Secrets injected from Key Vault — never appear in terraform plan output
  secure_environment_variables = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_key_vault_secret.appinsights_connection_string.value
    ACR_PASSWORD                          = azurerm_key_vault_secret.acr_password.value
  }

  tags = local.common_tags
}

# ── Container Instances — production ─────────────────────────────────────────
module "quote_api_prod" {
  source = "./modules/container_instance"

  name                = "${var.prefix}-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  image               = "${azurerm_container_registry.acr.login_server}/quote-api:latest"
  cpu                 = 0.5
  memory              = 1.0   # slightly more memory for production
  port                = 8000

  environment_variables = {
    ENV = "production"
  }

  secure_environment_variables = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_key_vault_secret.appinsights_connection_string.value
    ACR_PASSWORD                          = azurerm_key_vault_secret.acr_password.value
  }

  tags = local.common_tags
}

# ── Azure Monitor Action Group ────────────────────────────────────────────────
resource "azurerm_monitor_action_group" "email" {
  name                = "${var.prefix}-alert-email"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "quotealert"   # max 12 characters

  email_receiver {
    name          = "student-email"
    email_address = var.alert_email
  }

  tags = local.common_tags
}

# ── Azure Monitor Metric Alert — latency SLO ─────────────────────────────────
resource "azurerm_monitor_metric_alert" "latency_slo" {
  name                = "latency-slo"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_application_insights.ai.id]
  description         = "Alert when p99 request duration exceeds 500 ms."
  severity            = 2   # Warning
  frequency           = "PT1M"    # evaluate every 1 minute (minimum for Application Insights)
  window_size         = "PT5M"    # look back 5 minutes (minimum supported window)
  enabled             = true

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/duration"
    aggregation      = "Maximum"   # p99 approximation: maximum duration in the window
    operator         = "GreaterThan"
    threshold        = 500   # milliseconds
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = local.common_tags
}

# ── Azure Monitor Metric Alert — error rate SLO ───────────────────────────────
resource "azurerm_monitor_metric_alert" "error_rate_slo" {
  name                = "error-rate-slo"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_application_insights.ai.id]
  description         = "Alert when HTTP 5xx response rate exceeds 1% of requests."
  severity            = 1   # Error (higher severity than latency)
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0   # any failed request in the 5-minute window triggers the alert
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  tags = local.common_tags
}

# ── Azure Policy Assignments ──────────────────────────────────────────────────
# The built-in policy "Require a tag and its value on resources" has a well-known definition ID.
# This ID is the same across all Azure tenants.

data "azurerm_policy_definition" "require_tag" {
  display_name = "Require a tag and its value on resources"
}

resource "azurerm_resource_group_policy_assignment" "require_environment_tag" {
  name                 = "require-environment-tag"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  display_name         = "Require environment tag"
  description          = "Ensures all resources in this resource group have an environment tag."

  parameters = jsonencode({
    tagName = {
      value = "environment"
    }
    tagValue = {
      value = var.environment_tag
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "require_owner_tag" {
  name                 = "require-owner-tag"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  display_name         = "Require owner tag"
  description          = "Ensures all resources in this resource group have an owner tag."

  parameters = jsonencode({
    tagName = {
      value = "owner"
    }
    tagValue = {
      value = var.owner_tag
    }
  })
}
```

---

### `modules/container_instance/variables.tf`

```hcl
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
  description = "Sensitive environment variables (e.g. connection strings, passwords). These are never shown in terraform plan output."
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

---

### `modules/container_instance/main.tf`

```hcl
resource "azurerm_container_group" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_address_type     = "Public"
  os_type             = "Linux"
  dns_name_label      = var.name   # provides a stable FQDN: <name>.<region>.azurecontainer.io

  # Only include registry credentials when ACR_PASSWORD is supplied.
  # Omitting this block allows terraform test (plan-only) to run without real ACR credentials.
  # checkov:skip=CKV_AZURE_44:public IP required for coursework demo
  dynamic "image_registry_credential" {
    for_each = lookup(var.secure_environment_variables, "ACR_PASSWORD", "") != "" ? [1] : []
    content {
      server   = split("/", var.image)[0]   # extract registry hostname from image reference
      username = "admin"
      password = lookup(var.secure_environment_variables, "ACR_PASSWORD", "")
    }
  }

  container {
    name   = "quote-api"
    image  = var.image
    cpu    = var.cpu
    memory = var.memory

    ports {
      port     = var.port
      protocol = "TCP"
    }

    environment_variables        = var.environment_variables
    secure_environment_variables = { for k, v in var.secure_environment_variables : k => v if k != "ACR_PASSWORD" }
  }

  tags = var.tags
}
```

---

### `modules/container_instance/outputs.tf`

```hcl
output "fqdn" {
  value       = azurerm_container_group.this.fqdn
  description = "Fully qualified domain name of the container group (public)."
}

output "ip_address" {
  value       = azurerm_container_group.this.ip_address
  description = "Public IP address of the container group."
}

output "cpu" {
  value       = azurerm_container_group.this.container[0].cpu
  description = "CPU allocation of the container — used by terraform test assertions."
}

output "memory" {
  value       = azurerm_container_group.this.container[0].memory
  description = "Memory allocation in GB — used by terraform test assertions."
}
```

---

### `modules/container_instance/container_instance.tftest.hcl`

```hcl
# terraform test file for the container_instance module.
# Run from the module directory:
#   terraform test -chdir=homeworks/module7/terraform_az/modules/container_instance/
#
# Uses command = plan (default) — no real infrastructure is created, no Azure cost incurred.

run "staging_cpu_and_memory" {
  command = plan

  variables {
    name                = "testprefix-staging"
    location            = "westeurope"
    resource_group_name = "rg-test-quoteapi"
    image               = "testprefix-acr.azurecr.io/quote-api:latest"
    cpu                 = 0.5
    memory              = 0.5
    port                = 8000
    # secure_environment_variables intentionally omitted — defaults to {}
    # image_registry_credential block is omitted when ACR_PASSWORD is absent (see dynamic block)
  }

  assert {
    condition     = output.cpu == 0.5
    error_message = "Staging cpu must be 0.5 vCPU; got ${output.cpu}"
  }

  assert {
    condition     = output.memory == 0.5
    error_message = "Staging memory must be 0.5 GB; got ${output.memory}"
  }
}
```

---

### `outputs.tf` (root module)

```hcl
output "staging_fqdn" {
  value       = module.quote_api_staging.fqdn
  description = "Public FQDN for the staging ACI (used by the deploy workflow health check)."
}

output "prod_fqdn" {
  value       = module.quote_api_prod.fqdn
  description = "Public FQDN for the production ACI."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server hostname (used by the build workflow to tag and push images)."
}

output "acr_name" {
  value       = azurerm_container_registry.acr.name
  description = "ACR resource name (used by az acr login in the build workflow)."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Key Vault URI for manual secret verification."
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Key Vault name — needed for manual secret operations."
}

output "application_insights_instrumentation_key" {
  value       = azurerm_application_insights.ai.instrumentation_key
  sensitive   = true
  description = "App Insights instrumentation key (deprecated in favour of connection_string, kept for compatibility)."
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}
```

---

## Deployment walkthrough

### 1. Authenticate to Azure

```powershell
# Option A — interactive login (laptop/workstation)
az login
az account set --subscription "<your-subscription-id>"

# Option B — service principal (used by GitHub Actions via OIDC)
$env:ARM_USE_OIDC        = "true"
$env:ARM_CLIENT_ID       = "<sp-app-id>"
$env:ARM_TENANT_ID       = "<tenant-id>"
$env:ARM_SUBSCRIPTION_ID = "<subscription-id>"
```

For GitHub Actions, the `07_deploy.yml` workflow uses OIDC workload identity. The service principal must have the `Contributor` role on the target subscription and `User Access Administrator` at resource group scope (required to create the Key Vault `azurerm_role_assignment`).

### 1b. Configure a shared Terraform state backend (required for multi-job CI/CD)

The three-job `07_deploy.yml` workflow runs `terraform apply` in both Job 2 (staging) and Job 3 (production). Without a shared remote backend, each GitHub Actions job starts with an empty local state and Job 3 will attempt to recreate resources that Job 2 already created.

**Option A — Azure Storage backend (recommended):**

Create a storage account and container for Terraform state (this is a one-time manual step done before any `terraform apply`):

```powershell
# Create a dedicated storage account for Terraform state
$TF_RG  = "rg-terraform-state"
$TF_SA  = "tfstate$(Get-Random -Maximum 99999)"
$TF_CONTAINER = "module7tfstate"

az group create --name $TF_RG --location westeurope
az storage account create --name $TF_SA --resource-group $TF_RG --sku Standard_LRS --min-tls-version TLS1_2
az storage container create --name $TF_CONTAINER --account-name $TF_SA

# Store these values — you will need them in terraform.tfvars and as GitHub Actions secrets
Write-Host "Backend storage account : $TF_SA"
Write-Host "Backend container       : $TF_CONTAINER"
Write-Host "Backend resource group  : $TF_RG"
```

Add a `backend.tf` file in `homeworks/module7/terraform_az/`:

```hcl
# backend.tf — configure remote state in Azure Storage
# Replace placeholder values with the storage account created above.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<your-tfstate-storage-account>"
    container_name       = "module7tfstate"
    key                  = "module7.tfstate"
  }
}
```

Add the backend storage account key as a GitHub Actions secret (`TF_BACKEND_ACCESS_KEY`) and reference it in the workflow:

```yaml
      - name: Terraform init
        working-directory: homeworks/module7/terraform_az
        run: terraform init -backend-config="access_key=${{ secrets.TF_BACKEND_ACCESS_KEY }}"
```

**Option B — Artifact passing (no extra infrastructure):**

If you prefer not to create a separate storage account, pass the Terraform state file between jobs using GitHub Actions artifacts. Add these steps to Job 2 (staging):

```yaml
      - name: Upload Terraform state
        uses: actions/upload-artifact@v4
        with:
          name: tfstate
          path: homeworks/module7/terraform_az/terraform.tfstate
```

And add this step to the start of Job 3 (production), before `terraform init`:

```yaml
      - name: Download Terraform state
        uses: actions/download-artifact@v4
        with:
          name: tfstate
          path: homeworks/module7/terraform_az/
```

Option A is recommended for real deployments. Option B is sufficient for this homework if you do not want to provision additional infrastructure.

### 2. Create the GitHub Actions environments

Before running `07_deploy.yml` for the first time, create the `production` environment in the repository:

1. Open repository Settings → Environments → New environment.
2. Name it `production`.
3. Add at least one reviewer (your GitHub username).
4. Save. The Job 3 manual approval gate will now pause and wait for your approval in the Actions UI.

This step must be done manually in the GitHub UI — it cannot be automated via Terraform.

### 3. Configure `terraform.tfvars`

```powershell
cd homeworks/module7/terraform_az

# Copy the example file and edit it
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

Minimum required values:

```hcl
# terraform.tfvars — gitignored
prefix              = "quoteapi"          # change if name conflicts occur
location            = "westeurope"
resource_group_name = "rg-module7-quoteapi"
alert_email         = "you@example.com"   # receives alert notifications
owner_tag           = "yourusername"       # your student username
```

### 4. Initialise and validate Terraform

```powershell
cd homeworks/module7/terraform_az

terraform init
terraform validate
# Expected: "Success! The configuration is valid."

# Optional: run tflint locally before pushing to avoid workflow failures
tflint --chdir .
```

### 5. Initial `terraform apply` (infrastructure without ACI)

The first apply creates all shared infrastructure (ACR, Key Vault, App Insights, alerts, policy). ACI container groups are excluded because the image does not exist in ACR yet.

```powershell
terraform plan -out=tfplan
# Review the plan. Expected: ~15–18 resources.
# Verify: azurerm_container_registry.acr has admin_enabled = true
# Verify: azurerm_monitor_metric_alert.latency_slo and .error_rate_slo are present

terraform apply tfplan
# Apply time: ~5–8 minutes. Much faster than module5 (no PostgreSQL or Redis to provision).
```

### 6. Build and push the Docker image to ACR

Once the apply from step 5 completes, ACR exists and you can push the image. This step is normally performed by `07_app_build.yml`, but run it locally first to verify the image builds correctly.

```powershell
cd homeworks/module7/terraform_az

$ACR_NAME   = terraform output -raw acr_name
$ACR_SERVER = terraform output -raw acr_login_server

# Authenticate Docker to ACR
az acr login --name $ACR_NAME

# Build and push the image
cd ../src/quote_api
docker build -t quote-api .
docker tag quote-api "$ACR_SERVER/quote-api:latest"
docker push "$ACR_SERVER/quote-api:latest"

# Verify the image appears in the registry
az acr repository list --name $ACR_NAME --output table
```

### 7. Deploy staging ACI

With the image in ACR, run a second `terraform apply` to create both ACI container groups. Alternatively, target only staging first as `07_deploy.yml` Job 2 does:

```powershell
cd homeworks/module7/terraform_az

# Deploy staging only (mirrors what 07_deploy.yml Job 2 does)
terraform apply -target=module.quote_api_staging -auto-approve
# Apply time: ~1–2 minutes.

# Get staging FQDN
$STAGING = terraform output -raw staging_fqdn
Write-Host "Staging URL: http://${STAGING}:8000"

# Wait ~30 seconds for the container to start, then verify
Invoke-RestMethod "http://${STAGING}:8000/"
# Expected: {"status": "ok", "version": "1.0.0"}
```

### 8. Deploy production ACI (with manual approval simulation)

In the pipeline, Job 3 requires manual approval. Locally, apply the full configuration:

```powershell
cd homeworks/module7/terraform_az

terraform apply -auto-approve
# Creates the production ACI container group in addition to staging.

$PROD = terraform output -raw prod_fqdn
Invoke-RestMethod "http://${PROD}:8000/"
# Expected: {"status": "ok", "version": "1.0.0"}
```

### 9. Verify Application Insights telemetry

```powershell
$STAGING = terraform output -raw staging_fqdn

# Generate 20 requests against the staging quotes endpoint
1..20 | ForEach-Object {
    Invoke-RestMethod "http://${STAGING}:8000/quotes" | ConvertTo-Json
    Start-Sleep -Milliseconds 200
}
Write-Host "20 requests sent. Open Application Insights → Transaction search in the Azure portal."
```

In the Azure portal:
1. Navigate to the Application Insights resource (`<prefix>-ai`).
2. Click **Transaction search** in the left menu.
3. Set the time range to **Last 30 minutes**.
4. Click **Search**. You should see 20 request telemetry items for `GET /quotes` with status `200`.

If no items appear after 5 minutes, check that `APPLICATIONINSIGHTS_CONNECTION_STRING` is set in the container by running:

```powershell
$RG = terraform output -raw resource_group_name
az container show --resource-group $RG --name quoteapi-staging --query "containers[0].environmentVariables"
# The secure variable value will appear as null — that is expected.
# Confirm the key name "APPLICATIONINSIGHTS_CONNECTION_STRING" is present.
```

### 10. Destroy all resources

```powershell
cd homeworks/module7/terraform_az

terraform destroy -auto-approve
# Destroy time: ~3–5 minutes.
# All resources are removed including Key Vault (soft-deleted, not purged),
# Application Insights, Log Analytics workspace, both ACI container groups,
# and both Azure Policy assignments.
```

After destroy, verify the resource group is gone:

```powershell
az group show --name (terraform output -raw resource_group_name) 2>&1
# Expected: "ResourceGroupNotFound" error
```

---

## Testing strategy

### Acceptance criterion 1 — IaC validation pipeline gates bad formatting

**Verify `terraform fmt --check` failure:**

1. Open `homeworks/module7/terraform_az/main.tf` and remove the blank line between two resource blocks (e.g., between `azurerm_resource_group.rg` and `azurerm_container_registry.acr`).
2. Commit and push to a new branch: `git checkout -b test/fmt-error && git add -A && git commit -m "test: deliberate fmt error" && git push origin test/fmt-error`.
3. Open a pull request. Navigate to the Actions tab and confirm the `07_iac_validate` workflow run fails on the `terraform fmt --check` step with output similar to:
   ```
   main.tf
   Error: Files are not properly formatted.
   Run 'terraform fmt' to fix the formatting.
   ```
4. Fix the formatting locally with `terraform fmt .`, push the fix, and confirm the workflow turns green.

**Verify `checkov` output is visible:**

The `checkov` step runs even when no issues are found. Confirm the step log in GitHub Actions shows a summary table like:
```
Passed checks: 12, Failed checks: 0, Skipped checks: 2
```
Any `# checkov:skip=` inline suppressions in the HCL files must appear in the skipped count.

### Acceptance criterion 2 — Build pipeline passes zero CRITICAL CVEs

**Run Trivy locally:**

```powershell
docker build -t quote-api homeworks/module7/src/quote_api/
trivy image --exit-code 1 --severity CRITICAL quote-api
```

If Trivy reports CRITICAL CVEs against `python:3.12-slim`:

Option A — upgrade the base image tag in the `Dockerfile`:
```dockerfile
FROM python:3.12-slim-bookworm   # use the latest patch release
```

Option B — suppress known acceptable CVEs with `.trivyignore`:
```
# .trivyignore — placed in the Dockerfile directory
# CVE-2024-XXXXX: false positive in libexpat — not reachable in this application
CVE-2024-XXXXX
```

After suppression, confirm:
```powershell
trivy image --exit-code 1 --severity CRITICAL --ignorefile .trivyignore quote-api
# Expected: exit code 0, no CRITICAL vulnerabilities reported
```

**Verify image appears in ACR:**

```powershell
$ACR_NAME = terraform output -raw acr_name
az acr repository show-tags --name $ACR_NAME --repository quote-api --output table
# Expected: "latest" tag with a recent LastUpdateTime
```

### Acceptance criterion 3 — `terraform test` passes for the module

**Run locally:**

```powershell
# Run terraform test from the module directory (not the root terraform_az directory)
terraform test -chdir=homeworks/module7/terraform_az/modules/container_instance/
# Expected output:
# run "staging_cpu_and_memory"... pass
# Success! 1 passed, 0 failed.
```

**Verify in GitHub Actions:**

After the deploy workflow runs, open `07_deploy.yml` → Job 1 (`terraform-test`) → step logs. Confirm the line `1 passed, 0 failed.` or equivalent is visible.

### Acceptance criterion 4 — Staging FQDN is reachable after deploy

**Verify health check:**

```powershell
$STAGING = terraform output -raw staging_fqdn
$response = Invoke-RestMethod "http://${STAGING}:8000/"
$response | ConvertTo-Json
# Expected:
# {
#   "status": "ok",
#   "version": "1.0.0"
# }

# Also verify the quotes endpoint returns a quote
$quote = Invoke-RestMethod "http://${STAGING}:8000/quotes"
$quote | ConvertTo-Json
# Expected: {"id": <number>, "text": "...", "author": "..."}

# Verify the metrics endpoint returns Prometheus format text
Invoke-WebRequest "http://${STAGING}:8000/metrics" | Select-Object -ExpandProperty Content
# Expected: lines starting with "# HELP", "# TYPE", "quote_api_requests_total"
```

### Acceptance criterion 5 — Application Insights traces appear within 5 minutes

```powershell
$STAGING = terraform output -raw staging_fqdn

# Generate 20 requests
1..20 | ForEach-Object {
    Invoke-RestMethod "http://${STAGING}:8000/quotes" | Out-Null
    Write-Host "Request $_/20 sent"
}

# Check Application Insights via Azure CLI (alternative to portal)
$RG     = terraform output -raw resource_group_name
$AI_APP = "${env:prefix}-ai"   # or read from terraform output

# Query recent requests via az monitor app-insights (requires the extension)
az extension add --name application-insights --only-show-errors
az monitor app-insights metrics show `
    --app $AI_APP `
    --resource-group $RG `
    --metrics "requests/count" `
    --start-time (Get-Date).AddMinutes(-10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") `
    --interval PT1M
# Expected: "value" > 0 in the most recent time bucket
```

### Acceptance criterion 6 — Latency alert fires during sleep injection

**Inject artificial latency:**

1. Add `import time` at the top of `main.py` and `time.sleep(0.7)` as the first line of the `/quotes` handler.
2. Rebuild: `docker build -t quote-api . && docker tag quote-api "$ACR_SERVER/quote-api:latest" && docker push "$ACR_SERVER/quote-api:latest"`.
3. Redeploy staging: `terraform apply -target=module.quote_api_staging -auto-approve`.
4. Generate load:

```powershell
$STAGING = terraform output -raw staging_fqdn

1..50 | ForEach-Object {
    Invoke-RestMethod "http://${STAGING}:8000/quotes" | Out-Null
    Write-Host "Request $_/50 sent (each takes ~0.7 s)"
}
Write-Host "Load generation complete. Wait up to 10 minutes for alert to fire."
```

5. In the Azure portal, navigate to Monitor → Alerts. Confirm the `latency-slo` alert shows `Fired` state within 10 minutes.

**Verify via CLI:**

```powershell
$RG = terraform output -raw resource_group_name
az monitor metrics alert show --name "latency-slo" --resource-group $RG --query "enabled"
# Expected: true

# List active alert instances (after firing)
az monitor alert list --resource-group $RG --output table
```

**Verify Terraform state:**

```powershell
cd homeworks/module7/terraform_az
terraform state list | Select-String "monitor_metric_alert"
# Expected:
# azurerm_monitor_metric_alert.latency_slo
# azurerm_monitor_metric_alert.error_rate_slo
```

6. After the test, remove the `time.sleep` call, rebuild, and redeploy to restore normal behavior.

### Acceptance criterion 7 — Azure Policy shows 0 non-compliant resources

**Trigger an on-demand compliance scan:**

```powershell
$RG = terraform output -raw resource_group_name
az policy state trigger-scan --resource-group $RG
# This command returns immediately; the scan runs asynchronously.
# Wait ~5 minutes, then check compliance.

az policy state list --resource-group $RG --filter "complianceState eq 'NonCompliant'" --output table
# Expected: empty table (no non-compliant resources)
```

**Verify in the portal:**

Navigate to Azure portal → Policy → Compliance → filter by the `rg-module7-quoteapi` scope. Both assignment rows (`require-environment-tag` and `require-owner-tag`) should show `Compliant` with 0 non-compliant resources.

---

## GitHub Actions workflow snippets

The following snippets show the complete workflow files students must create from scratch.

### `07_iac_validate.yml`

```yaml
name: 07 IaC Validate

on:
  pull_request:
    paths:
      - "homeworks/module7/**"

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.6.0"

      - name: Terraform init (needed for fmt check to resolve modules)
        working-directory: homeworks/module7/terraform_az
        run: terraform init -backend=false

      - name: Terraform fmt check
        working-directory: homeworks/module7/terraform_az
        run: terraform fmt --check --recursive

      - name: Setup TFLint
        uses: terraform-linters/setup-tflint@v4

      - name: TFLint
        working-directory: homeworks/module7/terraform_az
        run: |
          tflint --init
          tflint --chdir .

      - name: Checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: homeworks/module7/terraform_az
          framework: terraform
          # Do not fail the workflow on checkov findings — findings are informational
          # for this homework; only the fmt check is a hard gate.
          soft_fail: false
```

### `07_app_build.yml`

```yaml
name: 07 App Build

on:
  push:
    branches:
      - main
    paths:
      - "homeworks/module7/src/**"

permissions:
  contents: read
  id-token: write   # required for OIDC authentication to Azure

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies for tests
        working-directory: homeworks/module7/src/quote_api
        run: pip install -r requirements.txt

      - name: Run pytest
        working-directory: homeworks/module7/src/quote_api
        run: pytest tests/ -v

      - name: Build Docker image
        working-directory: homeworks/module7/src/quote_api
        run: docker build -t quote-api .

      - name: Run Trivy vulnerability scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: "quote-api"
          exit-code: "1"
          severity: "CRITICAL"
          trivyignores: "homeworks/module7/src/quote_api/.trivyignore"

      - name: Log in to Azure (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Push image to ACR
        run: |
          ACR_NAME="${{ vars.ACR_NAME }}"
          ACR_SERVER="${ACR_NAME}.azurecr.io"
          az acr login --name "$ACR_NAME"
          docker tag quote-api "${ACR_SERVER}/quote-api:latest"
          docker push "${ACR_SERVER}/quote-api:latest"
```

### `07_deploy.yml`

```yaml
name: 07 Deploy

on:
  workflow_run:
    workflows: ["07 App Build"]
    types:
      - completed

permissions:
  contents: read
  id-token: write

jobs:
  terraform-test:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.6.0"

      - name: Log in to Azure (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Terraform init
        working-directory: homeworks/module7/terraform_az
        run: terraform init

      - name: Terraform test
        working-directory: homeworks/module7/terraform_az/modules/container_instance
        env:
          ARM_USE_OIDC: "true"
          ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
        run: |
          terraform init -backend=false
          terraform test

  staging:
    needs: terraform-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.6.0"

      - name: Log in to Azure (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Terraform init
        working-directory: homeworks/module7/terraform_az
        run: terraform init

      - name: Terraform apply — staging
        working-directory: homeworks/module7/terraform_az
        env:
          ARM_USE_OIDC: "true"
          ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          TF_VAR_alert_email: ${{ vars.ALERT_EMAIL }}
          TF_VAR_owner_tag: ${{ vars.OWNER_TAG }}
        run: |
          terraform apply -target=module.quote_api_staging -auto-approve
          echo "STAGING_FQDN=$(terraform output -raw staging_fqdn)" >> $GITHUB_ENV

      - name: Health check — staging
        run: |
          for i in {1..10}; do
            status=$(curl -s -o /dev/null -w "%{http_code}" "http://${{ env.STAGING_FQDN }}:8000/")
            if [ "$status" = "200" ]; then
              echo "Staging health check passed (HTTP 200)"
              exit 0
            fi
            echo "Attempt $i: HTTP $status — waiting 15 seconds..."
            sleep 15
          done
          echo "Staging health check failed after 10 attempts"
          exit 1

  production:
    needs: staging
    runs-on: ubuntu-latest
    environment: production   # manual approval gate configured in repo Settings → Environments
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.6.0"

      - name: Log in to Azure (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Terraform init
        working-directory: homeworks/module7/terraform_az
        run: terraform init

      - name: Terraform apply — production
        working-directory: homeworks/module7/terraform_az
        env:
          ARM_USE_OIDC: "true"
          ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
          ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          TF_VAR_alert_email: ${{ vars.ALERT_EMAIL }}
          TF_VAR_owner_tag: ${{ vars.OWNER_TAG }}
        run: terraform apply -auto-approve
```

---

## Security and architecture notes

### Azure Well-Architected Framework alignment

| Pillar | Decision |
|---|---|
| **Security** | ACR admin credentials and Application Insights connection string are stored in Key Vault and injected as `secure_environment_variables` — they never appear in `terraform plan` output, GitHub Actions logs, or the Azure portal ACI environment variable list. The Key Vault RBAC model (Secrets Officer for the deployer, no application Managed Identity needed because ACI injects secrets at apply time) avoids long-lived credentials. Azure Policy enforces mandatory tagging at the resource-group scope so all resources have an audit trail back to the owner. `checkov` IaC scanning on every PR prevents common misconfigurations from being merged. |
| **Reliability** | ACI does not support zero-downtime rolling updates — a new container image requires the container group to be deleted and recreated, causing ~30 seconds of downtime. This is acceptable for this lab because both staging and production are independent container groups and the swap is sequential. The manual approval gate in the production job prevents an untested image from reaching production. Azure Monitor metric alerts provide early warning before users notice SLO breaches. |
| **Cost Optimization** | Basic ACR SKU (~€0.17/day) is sufficient for a single image. ACI charges per second of vCPU and memory usage — 0.5 vCPU / 0.5 GB staging costs approximately €0.03/hour. Key Vault Standard tier costs €0.004 per 10,000 secret operations. Log Analytics ingestion for this lab generates < 1 MB/day. Tear down with `terraform destroy` after the session to avoid idle charges. |
| **Operational Excellence** | All infrastructure is defined in Terraform — no manual portal steps are required after the initial `GitHub Environments` configuration. Three distinct pipeline workflows enforce a clean separation of concerns: validation, build, deploy. `terraform test` provides a regression safety net for the module interface. Azure Policy compliance gives a continuous audit of tag hygiene without manual review. |
| **Performance Efficiency** | The Prometheus `/metrics` endpoint provides request count telemetry without Application Insights overhead. Application Insights sampling is disabled for this lab (all requests are tracked) because the traffic volume is low. The `opencensus-ext-azure` middleware adds negligible latency overhead (~1–2 ms) compared to the artificial `time.sleep(0.7)` used in the alert test. |

### IaC security scanning: `checkov` inline suppression pattern

`checkov` produces findings for configurations that are intentional in a coursework context. Suppress them with an inline comment immediately above the offending attribute:

```hcl
resource "azurerm_container_group" "this" {
  ip_address_type = "Public"
  # checkov:skip=CKV_AZURE_44:public IP is required for the lab — no VNet integration available on ACI Basic

  image_registry_credential {
    # checkov:skip=CKV_AZURE_131:ACI admin credentials are stored in Key Vault, not hardcoded
    password = var.acr_password
  }
}
```

The `# checkov:skip=<ID>:<reason>` format is required — `checkov` will reject suppressions without a reason string.

### Key Vault secret lifecycle

The `azurerm_key_vault_secret` resources for `acr-admin-password` and `appinsights-connection-string` depend on `azurerm_role_assignment.deployer_kv_officer` via `depends_on`. Without this dependency, Terraform may attempt to write the secrets before the RBAC assignment has propagated (Azure RBAC changes take up to ~2 minutes to propagate), causing a `403 Forbidden` error. If this error appears during the first `terraform apply`, re-run `terraform apply` — the role assignment will have propagated by then.

### ACR image pull credentials in ACI

ACI uses the `image_registry_credential` block to pull from private registries. The `admin_enabled = true` setting on ACR generates a static admin username/password pair. This password is stored in Key Vault and passed to the module via `secure_environment_variables`. Inside the module, the `ACR_PASSWORD` key is extracted from `secure_environment_variables` for use in `image_registry_credential.password` and excluded from the container's own environment variables (it has no runtime use for the application).

A cleaner production approach would use a Managed Identity assigned to ACI and grant it `AcrPull` on the registry, but ACI's Managed Identity support requires the `System Assigned` identity and an `azurerm_role_assignment` — this adds two more resources and complicates the module interface. For the purposes of this homework, admin credentials stored in Key Vault are acceptable.

---

## Known limitations and operational notes

1. **ACI does not support zero-downtime rolling updates.** A `terraform apply` that changes the container image forces the container group to be deleted and recreated. During the recreation, the FQDN is unreachable for approximately 30 seconds. Students should account for this gap in the staging health-check loop in `07_deploy.yml` — the `for i in {1..10}` retry loop with a 15-second sleep handles this window. In production environments, use Azure Container Apps or AKS for zero-downtime rolling updates.

2. **Azure Monitor metric alert evaluation delay.** Alert rules with `frequency = "PT1M"` and `window_size = "PT5M"` do not fire instantly. After the `time.sleep(0.7)` injection and load generation, students must wait up to 10 minutes for the alert to transition to `Fired`. The alert aggregation window must accumulate enough high-latency data points before the threshold is breached. If the alert does not fire after 10 minutes, verify that the ACI container group was redeployed with the sleep code by checking container logs: `az container logs --resource-group <rg> --name quoteapi-staging`.

3. **Azure Policy compliance evaluation delay.** Azure Policy compliance assessments run on a background schedule that can be delayed by up to 30 minutes after `terraform apply`. If the portal still shows non-compliant resources after adding tags and re-applying, trigger an on-demand scan: `az policy state trigger-scan --resource-group <rg-name>`. This command queues an immediate evaluation. Allow ~5 minutes after the command returns for results to appear in the portal.

4. **`checkov` false positives for ACI public IP.** `checkov` rule `CKV_AZURE_44` flags any `azurerm_container_group` with `ip_address_type = "Public"`. This is a false positive for this homework — a public IP is required because the ACI instance has no VNet integration. Suppress with `# checkov:skip=CKV_AZURE_44:public IP required for coursework; no VNet integration on ACI Basic`. The suppression must be placed on the line immediately above `ip_address_type = "Public"` in the module's `main.tf`, not in the root module.

5. **Trivy MEDIUM/HIGH CVEs in `python:3.12-slim`.** Trivy will typically report several MEDIUM and HIGH CVEs in the base image relating to `libexpat`, `zlib`, or `libssl`. These do not cause the pipeline to fail — only CRITICAL findings trigger `--exit-code 1`. Students are not required to suppress or fix MEDIUM/HIGH findings for this homework. If CRITICAL findings appear, either switch to `python:3.12-slim-bookworm` (the Debian Bookworm variant is usually more up to date on security patches) or add a `.trivyignore` file with the CVE ID and a one-line comment explaining why it is acceptable in this context.

6. **`production` GitHub environment must be configured before `07_deploy.yml` works.** The `environment: production` key in Job 3 of `07_deploy.yml` causes the job to pause and wait for approval from a configured reviewer. If the `production` environment does not exist in the repository's Settings → Environments, the job will fail immediately with "Environment not found." This manual configuration step cannot be scripted via GitHub Actions or Terraform and must be done by the student in the GitHub UI before the first deploy workflow run.

7. **`terraform test` is plan-only and does not create real resources.** The `container_instance.tftest.hcl` file uses `command = plan` (the default). This means `terraform test` validates the Terraform plan against the module configuration but does not create an actual ACI container group. The `output.cpu` and `output.memory` assertions check planned values from the `azurerm_container_group` resource, not deployed values. If students want integration tests that verify the actual deployed resource (e.g., that the FQDN is reachable), they must use `command = apply` in the test block, which creates and then destroys real Azure resources and incurs approximately €0.01 in compute cost per test run.

8. **Key Vault soft-delete name reservation.** Azure Key Vault has soft-delete enabled by default with a 7-day retention period (`soft_delete_retention_days = 7`). After `terraform destroy`, the Key Vault enters a soft-deleted state. If you re-run `terraform apply` within 7 days using the same `prefix`, the Key Vault creation will fail with "A vault with this name already exists in a deleted state." To recover: run `az keyvault recover --name <prefix>-kv` (restores the vault) or change the `prefix` variable in `terraform.tfvars`. Alternatively, purge the soft-deleted vault immediately after destroy with `az keyvault purge --name <prefix>-kv --location <location>` — but only do this if you are certain you do not need the secrets it contained.
