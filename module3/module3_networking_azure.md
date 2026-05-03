# Azure Implementation — Module 3: Networking (Versioned API with Traffic Splitting)

---

## Azure service mapping

| Homework component | Azure service | SKU / tier | Rationale |
|---|---|---|---|
| Virtual network | Azure Virtual Network (`azurerm_virtual_network`) | — (no SKU; billed by peering/VPN, not vnet itself) | Native VNet, free to create |
| Public subnet (load balancer) | Azure Subnet (`azurerm_subnet`) — dedicated to Application Gateway | — | Application Gateway v2 requires a dedicated subnet; no other resources may share it |
| Private subnet (backends) | Azure Subnet (`azurerm_subnet`) | — | Standard subnet; NSG enforces isolation |
| Network Security Group | `azurerm_network_security_group` + `azurerm_subnet_network_security_group_association` | — | Stateful L4 firewall attached at subnet scope |
| L7 load balancer | Azure Application Gateway v2 (`azurerm_application_gateway`) | `Standard_v2` | Supports path-based routing, weighted backends, TLS offload, WAF-ready; v1 is deprecated |
| Public IP for load balancer | `azurerm_public_ip` | `Standard` SKU, `Static` allocation | Standard SKU required by Application Gateway v2; Static allocation required for DNS stability |
| TLS certificate | Self-signed PFX embedded in `azurerm_application_gateway` `ssl_certificate` block | — | Acceptable for the exercise; avoids Key Vault dependency |
| HTTPS listener (port 443) | `frontend_port` + `http_listener` blocks inside `azurerm_application_gateway` | — | Single multi-site or basic listener |
| Backend pool v1 | `backend_address_pool` block inside `azurerm_application_gateway` | — | Targets private IP of ACI container group v1 |
| Backend pool v2 | `backend_address_pool` block inside `azurerm_application_gateway` | — | Targets private IP of ACI container group v2 |
| Path-based routing `/v1/items*` → pool-v1, `/v2/items*` → pool-v2 | `url_path_map` + `path_rule` blocks | — | Native Application Gateway URL path map |
| Weighted canary split on `/items` (90 / 10) | `rewrite_rule_set` is NOT the right mechanism; use a **second `url_path_map` path rule** with two `backend_address_pool` references via weighted round-robin — see note below | — | See architectural note in "Known limitations" |
| Backend compute v1 | Azure Container Instances (`azurerm_container_group`) | — | Serverless containers; no public IP; placed in delegated VNet subnet |
| Backend compute v2 | Azure Container Instances (`azurerm_container_group`) | — | Same as v1 |
| DNS A record | `azurerm_dns_a_record` inside an `azurerm_dns_zone` | — | Azure Public DNS zone; maps hostname to load balancer public IP |
| Private Endpoint (stretch) | `azurerm_private_endpoint` + `azurerm_private_dns_zone` + `azurerm_private_dns_zone_virtual_network_link` | — | Attaches Storage Account private endpoint into `subnet-backend` |
| Storage Account (stretch) | `azurerm_storage_account` | `Standard_LRS` | Cheapest option for the exercise; public access disabled |

> ⚠️ NEEDS USER INPUT: Container images are stored in **Azure Container Registry (ACR)**. Create an ACR instance, build and push `lesson03-api-v1` and `lesson03-api-v2`, then update `api_image_v1` and `api_image_v2` in `terraform.tfvars` with the full ACR image URIs (e.g. `<registry>.azurecr.io/lesson03-api-v1:latest`). Enable anonymous pull on the ACR instance so ACI can pull without credentials, or add an `image_registry_credential` block to each `azurerm_container_group`.

> ⚠️ NEEDS USER INPUT: Azure Container Instances VNet integration requires delegating `subnet-backend` to `Microsoft.ContainerInstance/containerGroups`. This means ACI is the **only** resource type that can be placed in that subnet. If you need other resource types (e.g., VMs) in the same subnet, use separate subnets or switch to Azure Container Apps / AKS.

---

## Architecture diagram (text)

```
Internet
    │
    │  HTTPS :443
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  Resource Group: rg-module3-networking                           │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  VNet: 10.10.0.0/16                                     │    │
│  │                                                         │    │
│  │  ┌───────────────────────────────────────────────────┐  │    │
│  │  │  subnet-lb  10.10.1.0/24                          │  │    │
│  │  │  (delegated to Application Gateway — no NSG       │  │    │
│  │  │   except required AGW NSG rules)                  │  │    │
│  │  │                                                   │  │    │
│  │  │  ┌─────────────────────────────────────────────┐  │  │    │
│  │  │  │  Application Gateway v2  (Standard_v2)      │  │  │    │
│  │  │  │  Public IP (Standard Static)                │  │  │    │
│  │  │  │                                             │  │  │    │
│  │  │  │  Listener :443 (HTTPS, self-signed TLS)     │  │  │    │
│  │  │  │    │                                        │  │  │    │
│  │  │  │    ├─ url_path_map                          │  │  │    │
│  │  │  │    │    ├─ /v1/items*  → backend-pool-v1    │  │  │    │
│  │  │  │    │    ├─ /v2/items*  → backend-pool-v2    │  │  │    │
│  │  │  │    │    └─ /items*     → weighted rule      │  │  │    │
│  │  │  │    │         90% → backend-pool-v1          │  │  │    │
│  │  │  │    │         10% → backend-pool-v2          │  │  │    │
│  │  │  │    │                                        │  │  │    │
│  │  │  │  backend HTTP settings: HTTP :8080          │  │  │    │
│  │  │  └─────────────────────────────────────────────┘  │  │    │
│  │  └───────────────────────────────────────────────────┘  │    │
│  │                                                         │    │
│  │  ┌───────────────────────────────────────────────────┐  │    │
│  │  │  subnet-backend  10.10.2.0/24                     │  │    │
│  │  │  NSG: allow TCP 8080 from 10.10.1.0/24 only      │  │    │
│  │  │  Delegated to: Microsoft.ContainerInstance/       │  │    │
│  │  │                containerGroups                    │  │    │
│  │  │                                                   │  │    │
│  │  │  ┌─────────────┐    ┌─────────────┐              │  │    │
│  │  │  │  ACI v1     │    │  ACI v2     │              │  │    │
│  │  │  │  10.10.2.4  │    │  10.10.2.5  │              │  │    │
│  │  │  │  :8080 HTTP │    │  :8080 HTTP │              │  │    │
│  │  │  │  (no pub IP)│    │  (no pub IP)│              │  │    │
│  │  │  └─────────────┘    └─────────────┘              │  │    │
│  │  │                                                   │  │    │
│  │  │  (Stretch) ┌──────────────────────────────────┐  │  │    │
│  │  │            │ Private Endpoint                 │  │  │    │
│  │  │            │ → Storage Account (no public     │  │  │    │
│  │  │            │   access)                        │  │  │    │
│  │  │            └──────────────────────────────────┘  │  │    │
│  │  └───────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  Azure DNS Zone: module3.example.local                           │
│    A record: api → <AppGW public IP>                             │
└──────────────────────────────────────────────────────────────────┘
```

---

## Terraform file structure

```
homeworks/module3/terraform/
├── main.tf              # Provider config, resource group, all primary resources
├── network.tf           # VNet, subnets, NSG, NSG association
├── appgateway.tf        # Application Gateway, Public IP, self-signed cert generation
├── backends.tf          # azurerm_container_group for v1 and v2
├── dns.tf               # DNS zone and A record
├── private_endpoint.tf  # (Stretch) Storage Account, Private Endpoint, Private DNS Zone
├── variables.tf         # Input variable declarations
├── outputs.tf           # Output values (public IP, DNS name, etc.)
└── terraform.tfvars     # Concrete values for variables (gitignored if secrets present)
```

---

## Terraform resource definitions

### `main.tf` — provider and resource group

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100" # or "~> 4.0" if using the v4 provider; attribute names differ slightly
    }
    # tls provider used to generate a self-signed cert for the exercise
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  # Authentication: use environment variables ARM_CLIENT_ID, ARM_CLIENT_SECRET,
  # ARM_TENANT_ID, ARM_SUBSCRIPTION_ID  — or ARM_USE_OIDC = true for workload identity.
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}
```

### `variables.tf`

```hcl
variable "resource_group_name" {
  type        = string
  default     = "rg-module3-networking"
  description = "Name of the Azure resource group."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region for all resources. westeurope (Netherlands/Amsterdam) is the default EU West region, closest to Czech Republic. northeurope (Ireland/Dublin) is an acceptable alternative."
}

variable "api_image_v1" {
  type        = string
  description = "Container image for API v1. Example: <registry>.azurecr.io/lesson03-api-v1:latest"
}

variable "api_image_v2" {
  type        = string
  description = "Container image for API v2. Example: <registry>.azurecr.io/lesson03-api-v2:latest"
}

variable "dns_zone_name" {
  type        = string
  default     = "module3.example.local"
  description = "Azure DNS zone name. Must be unique within the subscription."
}
```

### `terraform.tfvars`

```hcl
resource_group_name = "rg-module3-networking"
location            = "westeurope"
api_image_v1        = "<registry>.azurecr.io/lesson03-api-v1:latest"   # replace <registry>
api_image_v2        = "<registry>.azurecr.io/lesson03-api-v2:latest"   # replace <registry>
dns_zone_name       = "module3.example.local"
```

### `network.tf` — VNet, subnets, NSG

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-module3"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.10.0.0/16"]
}

# ── subnet-lb: Application Gateway lives here ──────────────────────────────────
# Application Gateway v2 requires a DEDICATED subnet. No other resource types
# may be placed in it. Minimum recommended size is /24; /26 is the minimum.
resource "azurerm_subnet" "lb" {
  name                 = "subnet-lb"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.1.0/24"]
}

# ── subnet-backend: ACI containers live here ───────────────────────────────────
# Must be delegated to Microsoft.ContainerInstance/containerGroups for ACI VNet
# integration. This prevents any other resource type from being placed here.
resource "azurerm_subnet" "backend" {
  name                 = "subnet-backend"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.2.0/24"]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ── NSG for subnet-backend ─────────────────────────────────────────────────────
resource "azurerm_network_security_group" "backend" {
  name                = "nsg-backend"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Allow inbound TCP 8080 from the Application Gateway subnet only
  security_rule {
    name                       = "allow-appgw-8080"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.10.1.0/24"
    destination_address_prefix = "*"
  }

  # Deny all other inbound internet traffic explicitly
  # (Azure default rules already deny VNet-to-Internet inbound at priority 65500,
  #  but being explicit is good practice)
  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.backend.id
}
```

> ⚠️ NEEDS USER INPUT: Azure Application Gateway v2 itself also requires specific NSG rules on `subnet-lb` to function correctly: inbound TCP 65503–65534 from the `GatewayManager` service tag (for health probes), and inbound from the `AzureLoadBalancer` service tag. If you attach an NSG to `subnet-lb`, add these rules or Application Gateway deployment will fail. The simplest approach for the exercise is to leave `subnet-lb` without an NSG unless you explicitly need to restrict it.

### `appgateway.tf` — Public IP, self-signed TLS cert, Application Gateway

```hcl
# ── Public IP ──────────────────────────────────────────────────────────────────
# Standard SKU + Static allocation are mandatory for Application Gateway v2.
resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-module3"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  allocation_method   = "Static"
}

# ── Self-signed TLS certificate (exercise only — not for production) ───────────
resource "tls_private_key" "appgw" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "appgw" {
  private_key_pem = tls_private_key.appgw.private_key_pem

  subject {
    common_name  = "api.module3.example.local"
    organization = "Module3 Exercise"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Application Gateway needs a PKCS#12 (PFX) bundle. The pkcs12 provider can
# create one, but the simplest approach is to use the tls_private_key and
# tls_self_signed_cert outputs directly with the azurerm provider's
# ssl_certificate block, which accepts PEM-encoded data encoded as base64.
# However, azurerm_application_gateway ssl_certificate requires a PFX file
# (data attribute = base64-encoded PFX, password attribute = PFX password).
# We use the `pkcs12` Terraform provider to build the PFX.

# ── OPTION A (simpler): pre-generate a PFX file outside Terraform and pass it ──
# as a variable. This avoids adding a third provider.
# ── OPTION B (fully automated): use the `pkcs12provider` community provider ────
# to convert PEM → PFX inside Terraform.

# The block below shows Option A. Replace `var.tls_pfx_base64` and
# `var.tls_pfx_password` with your values (store in terraform.tfvars, never git).

# > ⚠️ NEEDS USER INPUT: Choose Option A or Option B. For Option A, generate the
# PFX with:
#   openssl pkcs12 -export \
#     -inkey key.pem -in cert.pem \
#     -out appgw.pfx -passout pass:changeme
#   base64 -w 0 appgw.pfx > appgw.pfx.b64
# Then set tls_pfx_base64 and tls_pfx_password in terraform.tfvars.

variable "tls_pfx_base64" {
  type        = string
  sensitive   = true
  description = "Base64-encoded PFX certificate bundle for Application Gateway TLS."
}

variable "tls_pfx_password" {
  type        = string
  sensitive   = true
  default     = "changeme"
  description = "Password protecting the PFX bundle."
}

# ── Application Gateway v2 ─────────────────────────────────────────────────────
locals {
  # Logical names for Application Gateway sub-resources. Using locals avoids
  # repeating strings across the many nested blocks.
  frontend_ip_config_name  = "appgw-frontend-ip"
  frontend_port_name_https = "appgw-port-443"
  frontend_port_name_http  = "appgw-port-80"
  listener_name_https      = "listener-https"
  backend_pool_v1_name     = "backend-pool-v1"
  backend_pool_v2_name     = "backend-pool-v2"
  http_settings_name       = "backend-http-settings"
  url_path_map_name        = "url-path-map"
  routing_rule_name        = "routing-rule-https"
  ssl_cert_name            = "appgw-selfsigned-cert"
}

resource "azurerm_application_gateway" "main" {
  name                = "appgw-module3"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1 # Manual scaling; set to 2+ for production
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.lb.id
  }

  # ── Frontend ──────────────────────────────────────────────────────────────────
  frontend_ip_configuration {
    name                 = local.frontend_ip_config_name
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.frontend_port_name_https
    port = 443
  }

  # ── TLS Certificate ───────────────────────────────────────────────────────────
  ssl_certificate {
    name     = local.ssl_cert_name
    data     = var.tls_pfx_base64   # base64-encoded PFX
    password = var.tls_pfx_password
  }

  # ── HTTPS Listener ────────────────────────────────────────────────────────────
  http_listener {
    name                           = local.listener_name_https
    frontend_ip_configuration_name = local.frontend_ip_config_name
    frontend_port_name             = local.frontend_port_name_https
    protocol                       = "Https"
    ssl_certificate_name           = local.ssl_cert_name
  }

  # ── Backend Pools ─────────────────────────────────────────────────────────────
  backend_address_pool {
    name         = local.backend_pool_v1_name
    # IP addresses are resolved after ACI containers are created.
    # Terraform dependency ordering (depends_on) ensures containers exist first.
    ip_addresses = [azurerm_container_group.api_v1.ip_address]
  }

  backend_address_pool {
    name         = local.backend_pool_v2_name
    ip_addresses = [azurerm_container_group.api_v2.ip_address]
  }

  # ── Backend HTTP Settings (TLS offload: AppGW speaks HTTP to backends) ────────
  backend_http_settings {
    name                  = local.http_settings_name
    cookie_based_affinity = "Disabled"
    protocol              = "Http"   # Plain HTTP — TLS terminated at the gateway
    port                  = 8080
    request_timeout       = 30
  }

  # ── URL Path Map ──────────────────────────────────────────────────────────────
  # The default path map rule handles traffic not matched by any path_rule.
  # We point it at pool-v1 (the stable version) as the safe default.
  url_path_map {
    name                               = local.url_path_map_name
    default_backend_address_pool_name  = local.backend_pool_v1_name
    default_backend_http_settings_name = local.http_settings_name

    # Explicit /v1/items* path → pool-v1
    path_rule {
      name                       = "rule-v1"
      paths                      = ["/v1/items*"]
      backend_address_pool_name  = local.backend_pool_v1_name
      backend_http_settings_name = local.http_settings_name
    }

    # Explicit /v2/items* path → pool-v2
    path_rule {
      name                       = "rule-v2"
      paths                      = ["/v2/items*"]
      backend_address_pool_name  = local.backend_pool_v2_name
      backend_http_settings_name = local.http_settings_name
    }

    # /items* canary rule — weighted split to two pools.
    # NOTE: Standard Application Gateway v2 does NOT natively support
    # weighted routing between two backend pools inside a single path_rule.
    # See "Known Limitations" section for details and the recommended workaround.
    # The block below is a PLACEHOLDER — it routes 100% to pool-v1 until
    # the weighted mechanism is implemented as described in the notes.
    path_rule {
      name                       = "rule-canary"
      paths                      = ["/items*"]
      backend_address_pool_name  = local.backend_pool_v1_name
      backend_http_settings_name = local.http_settings_name
    }
  }

  # ── Routing Rule ──────────────────────────────────────────────────────────────
  request_routing_rule {
    name               = local.routing_rule_name
    rule_type          = "PathBasedRouting"
    http_listener_name = local.listener_name_https
    url_path_map_name  = local.url_path_map_name
    priority           = 100 # Required for Standard_v2; must be unique per gateway
  }
}
```

> ❓ OPEN QUESTION: Azure Application Gateway v2 (Standard_v2 tier) does **not** support weighted backend routing between two different backend pools in a single routing rule natively the way AWS ALB does. The weighted forward action is an ALB-specific feature. On Azure, the correct approach for a 90/10 canary split is one of:
> 1. **Azure Front Door** — supports weighted origin groups natively (weights 1–1000 per origin). This is the recommended Azure service for weighted traffic distribution, but it is a global CDN/load balancer, not a VNet-internal gateway.
> 2. **Application Gateway + custom header / cookie stickiness + client-side routing** — not a gateway-level weight.
> 3. **Two separate `azurerm_application_gateway` backend address pools and a rewrite rule that probabilistically rewrites the URL** — complex and unsupported.
> 4. **Azure Container Apps** with traffic splitting (ingress weights) — if backends are Container Apps instead of ACI, the platform handles weights natively without Application Gateway.
>
> **Recommended resolution for this homework:** Use **Azure Container Apps** (replacing ACI) with `azurerm_container_app` and configure ingress `traffic_weight` blocks for the canary split. The Container Apps environment provides its own managed ingress (Envoy-based) that supports weighted routing. Alternatively, deploy Azure Front Door in front of Application Gateway. Ask the instructor which approach to implement.

### `backends.tf` — Azure Container Instances

```hcl
# ── API v1 Container Group ─────────────────────────────────────────────────────
resource "azurerm_container_group" "api_v1" {
  name                = "aci-api-v1"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_address_type     = "Private"  # No public IP — only reachable within the VNet
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.backend.id]

  container {
    name   = "api-v1"
    image  = var.api_image_v1
    cpu    = "0.5"
    memory = "0.5"

    ports {
      port     = 8080
      protocol = "TCP"
    }
  }

  # restart_policy controls what happens if the container exits.
  # "Always" is appropriate for a long-running service.
  restart_policy = "Always"
}

# ── API v2 Container Group ─────────────────────────────────────────────────────
resource "azurerm_container_group" "api_v2" {
  name                = "aci-api-v2"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_address_type     = "Private"
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.backend.id]

  container {
    name   = "api-v2"
    image  = var.api_image_v2
    cpu    = "0.5"
    memory = "0.5"

    ports {
      port     = 8080
      protocol = "TCP"
    }
  }

  restart_policy = "Always"
}
```

> ⚠️ NEEDS USER INPUT: `azurerm_container_group` with `ip_address_type = "Private"` and `subnet_ids` requires that the subnet be delegated to `Microsoft.ContainerInstance/containerGroups` (already done in `network.tf`). ACR images are private by default — either enable anonymous pull (`az acr update --name <registry> --anonymous-pull-enabled true`) or add an `image_registry_credential` block to each container group with `server = "<registry>.azurecr.io"`, `username`, and `password` from the ACR admin account (`az acr credential show --name <registry>`).

### `dns.tf` — Azure DNS zone and A record

```hcl
resource "azurerm_dns_zone" "main" {
  name                = var.dns_zone_name  # e.g., "module3.example.local"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_dns_a_record" "api" {
  name                = "api"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60 # Short TTL for easy testing
  records             = [azurerm_public_ip.appgw.ip_address]
}
```

> ⚠️ NEEDS USER INPUT: Azure Public DNS zones (`azurerm_dns_zone`) are for internet-resolvable domains. The hostname `module3.example.local` uses a `.local` TLD which is technically reserved for mDNS and will not be delegated by any public registrar. For the exercise, this is fine as a placeholder, but `nslookup` / `dig` will only resolve it if you configure the Azure DNS zone name servers in your local resolver, which you typically cannot do for `.local`. Options:
> 1. Use a real domain you own and create an Azure DNS zone for a subdomain (e.g., `module3.yourdomain.com`).
> 2. Use `/etc/hosts` (or `C:\Windows\System32\drivers\etc\hosts`) to map `api.module3.example.local` to the public IP manually for testing.
> 3. Use `azurerm_private_dns_zone` linked to the VNet for internal-only resolution (hostname only resolves inside the VNet).

### `private_endpoint.tf` — Stretch goal: Storage Account with Private Endpoint

```hcl
# ── Storage Account ────────────────────────────────────────────────────────────
resource "azurerm_storage_account" "main" {
  name                     = "stmodule3${random_id.suffix.hex}" # must be globally unique, 3-24 chars
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Disable all public network access — only accessible via Private Endpoint
  public_network_access_enabled = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ── Private Endpoint ───────────────────────────────────────────────────────────
# A dedicated subnet is required for private endpoints; it cannot be the same
# subnet that is delegated to ACI (delegated subnets reject private endpoints).
resource "azurerm_subnet" "private_endpoints" {
  name                 = "subnet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.3.0/24"]

  # Private endpoint network policies must be disabled for the subnet
  # (this is the default; explicitly shown for clarity)
  private_endpoint_network_policies_enabled = false
}

resource "azurerm_private_endpoint" "storage" {
  name                = "pe-storage-module3"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "storage-connection"
    private_connection_resource_id = azurerm_storage_account.main.id
    is_manual_connection           = false
    subresource_names              = ["blob"] # "blob" for Blob Storage endpoint
  }
}

# ── Private DNS Zone for blob.core.windows.net ────────────────────────────────
# Required so that <storage-account>.blob.core.windows.net resolves to the
# private IP of the private endpoint within the VNet.
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "blob-dns-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false # We only need conditional forwarding, not auto-registration
}

resource "azurerm_private_dns_a_record" "storage" {
  name                = azurerm_storage_account.main.name
  zone_name           = azurerm_private_dns_zone.blob.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 10
  records             = [azurerm_private_endpoint.storage.private_service_connection[0].private_ip_address]
}
```

> ⚠️ NEEDS USER INPUT: The stretch goal requires a **third subnet** (`subnet-pe`, `10.10.3.0/24`) because the ACI-delegated `subnet-backend` does not accept private endpoints. Update `variables.tf` and `network.tf` to include this address range if you implement the stretch goal. Also add the `random` provider to `required_providers`.

### `outputs.tf`

```hcl
output "appgw_public_ip" {
  description = "Public IP address of the Application Gateway."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_public_ip_fqdn" {
  description = "Azure-assigned DNS name for the public IP (use for initial testing before custom DNS)."
  value       = azurerm_public_ip.appgw.fqdn
}

output "api_v1_private_ip" {
  description = "Private IP address of the v1 Container Instance."
  value       = azurerm_container_group.api_v1.ip_address
}

output "api_v2_private_ip" {
  description = "Private IP address of the v2 Container Instance."
  value       = azurerm_container_group.api_v2.ip_address
}

output "dns_name_servers" {
  description = "Name servers for the Azure DNS zone. Delegate your domain to these."
  value       = azurerm_dns_zone.main.name_servers
}
```

---

## Deployment walkthrough

### 1. Prerequisites

```bash
# Install Azure CLI and log in (interactive)
az login

# Confirm active subscription
az account show --query "{name:name, id:id}" -o table

# If you need to switch subscription:
az account set --subscription "<subscription-id>"
```

### 2. Prepare the TLS certificate (Option A — pre-generated PFX)

```bash
# Generate a private key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 365 -nodes \
  -subj "/CN=api.module3.example.local/O=Module3 Exercise"

# Bundle into PFX with a password
openssl pkcs12 -export \
  -inkey key.pem -in cert.pem \
  -out appgw.pfx -passout pass:changeme

# Base64-encode the PFX for the Terraform variable
# On Linux/macOS:
base64 -w 0 appgw.pfx > appgw.pfx.b64
# On Windows (PowerShell):
# [Convert]::ToBase64String([IO.File]::ReadAllBytes("appgw.pfx")) | Out-File appgw.pfx.b64

# Add to terraform.tfvars (do NOT commit this file)
echo 'tls_pfx_base64  = "'$(cat appgw.pfx.b64)'"' >> terraform.tfvars
echo 'tls_pfx_password = "changeme"'               >> terraform.tfvars
```

### 3. Initialize and validate

```bash
cd homeworks/module3/terraform/

terraform init

# Validate syntax and provider schema
terraform validate
```

### 4. Plan and apply

```bash
# Review the execution plan
terraform plan -out=tfplan

# Inspect the plan output — confirm resource count, no unexpected replacements
# Then apply:
terraform apply tfplan
```

Application Gateway provisioning typically takes **5–10 minutes**. Wait for the apply to complete fully.

> ⚠️ **SESSION TIME NOTE:** With 5–10 minutes to provision and a similar window to destroy, a 10-minute test window is not realistic for this module. Plan for a **minimum 25–30 minute session** (provision → test → destroy). If your session is time-constrained, consider replacing Application Gateway + ACI with **Azure Container Apps**, which provisions in ~2 minutes, costs near-zero on the Consumption plan, and natively supports weighted canary splits via `traffic_weight` revision blocks — resolving both the provisioning time and the weighted-routing limitation noted in the Known Limitations section.

### 5. Retrieve the public IP

```bash
terraform output appgw_public_ip
# Example output: 20.x.x.x
export LB_IP=$(terraform output -raw appgw_public_ip)
```

### 6. Test path-based routing

```bash
# -k disables TLS certificate verification (self-signed cert)
curl -k https://$LB_IP/v1/items
# Expected: JSON array, e.g. [{"id":1,"name":"Widget"}, ...]

curl -k https://$LB_IP/v2/items
# Expected: JSON object, e.g. {"_version":"v2","total":3,"page":1,"page_size":10,"data":[...]}
```

### 7. Test the canary split on `/items`

```bash
for i in $(seq 1 50); do
  curl -sk https://$LB_IP/items
  echo
done | grep -c '"_version"'
# Expected: between 2 and 10 (targeting ~10% → ~5 out of 50, accepting variance)
```

> ❓ OPEN QUESTION: As noted in the weighted routing limitation, Application Gateway Standard_v2 does not perform a statistical 90/10 split between two different backend pools in a single path rule. If the canary split is implemented via Azure Container Apps or Azure Front Door, the test procedure above remains valid, but the infrastructure commands to configure it will differ. See "Known limitations" for the full discussion.

### 8. Verify TLS offloading

```bash
# terraform show confirms backend HTTP settings
terraform show | grep -A5 "backend_http_settings"
# Expected output should show: protocol = "Http", port = 8080

# Alternatively, use az CLI:
az network application-gateway show \
  --name appgw-module3 \
  --resource-group rg-module3-networking \
  --query "backendHttpSettingsCollection[].{name:name,protocol:protocol,port:port}" \
  -o table
# Expected: protocol=Http, port=8080
```

### 9. Verify backend containers have no public IP

```bash
az container show \
  --name aci-api-v1 \
  --resource-group rg-module3-networking \
  --query "ipAddress" -o json
# Expected: {"ip": "10.10.2.x", "type": "Private"} — no "publicIp" field
```

### 10. Add a DNS A record and test with hostname

```bash
# After terraform apply, get the name servers
terraform output dns_name_servers

# Add the hostname to /etc/hosts for local testing (if not using a real domain):
echo "$LB_IP  api.module3.example.local" | sudo tee -a /etc/hosts

# Test using the hostname
curl -k --resolve "api.module3.example.local:443:$LB_IP" \
  https://api.module3.example.local/v1/items
```

### 11. Stretch: Verify Private Endpoint

```bash
# From inside a container instance (requires az container exec or a jumpbox):
# The storage account FQDN should resolve to a 10.10.3.x IP
nslookup <storage-account-name>.blob.core.windows.net

# From outside the VNet, the same DNS name resolves to a public Microsoft IP
# and access is blocked (HTTP 403 or connection refused):
curl -I https://<storage-account-name>.blob.core.windows.net
# Expected: HTTP 403 (public network access is disabled)
```

### 12. Destroy

```bash
terraform destroy
# Confirm with "yes" when prompted.
# All resources including the resource group contents will be removed.
```

---

## Testing strategy

### Path routing verification

```bash
export LB_IP=$(terraform output -raw appgw_public_ip)

# v1: must return a JSON array
RESPONSE_V1=$(curl -sk https://$LB_IP/v1/items)
echo "$RESPONSE_V1" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list), 'Expected array'; print('PASS: /v1/items returns array')"

# v2: must return a JSON object with _version field
RESPONSE_V2=$(curl -sk https://$LB_IP/v2/items)
echo "$RESPONSE_V2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert isinstance(d, dict),       'Expected object'
assert '_version' in d,           'Missing _version field'
assert d['_version'] == 'v2',     '_version must equal v2'
assert 'data' in d,               'Missing data field'
print('PASS: /v2/items returns correct object shape')
"
```

### Canary split verification (50-request loop)

```bash
V2_COUNT=$(for i in $(seq 1 50); do
  curl -sk https://$LB_IP/items
  echo
done | grep -c '"_version"')

echo "v2 responses: $V2_COUNT / 50"

if [ "$V2_COUNT" -ge 2 ] && [ "$V2_COUNT" -le 10 ]; then
  echo "PASS: canary split within expected range (2–10 out of 50)"
else
  echo "FAIL: canary split out of expected range. Check Application Gateway routing rule."
fi
```

### TLS/HTTPS verification

```bash
# Verify TLS handshake succeeds (even with self-signed cert using -k)
curl -vk https://$LB_IP/v1/items 2>&1 | grep -E "SSL connection|subject|issuer|HTTP/"

# Verify that plain HTTP (port 80) is not open (no HTTP listener configured)
curl -v http://$LB_IP/v1/items 2>&1 | grep -E "Connection refused|HTTP/"
# Expected: Connection refused or timeout — no HTTP listener on port 80
```

### TLS offloading confirmation

```bash
# The backend setting must show Http (not Https) on port 8080.
az network application-gateway http-settings list \
  --gateway-name appgw-module3 \
  --resource-group rg-module3-networking \
  --query "[].{name:name,protocol:protocol,port:port}" \
  -o table
```

### Private Endpoint connectivity test (stretch)

```bash
# From inside the VNet (e.g., exec into the v1 container via az container exec):
az container exec \
  --name aci-api-v1 \
  --resource-group rg-module3-networking \
  --exec-command "/bin/sh"

# Inside the container:
nslookup <storage-account>.blob.core.windows.net
# Must resolve to 10.10.3.x (private endpoint IP)

# From outside the VNet (your local machine):
nslookup <storage-account>.blob.core.windows.net
# Resolves to a public Microsoft IP

curl -I https://<storage-account>.blob.core.windows.net
# Expected: HTTP 403 PublicAccessNotPermitted (or similar network error)
```

---

## Security and architecture notes

### NSG rules

- `subnet-backend` NSG allows **only** inbound TCP 8080 from `10.10.1.0/24` (the Application Gateway subnet). All other inbound traffic from the internet is denied.
- `subnet-lb` should have NSG rules for Application Gateway management traffic (inbound TCP 65503–65534 from `GatewayManager` service tag) if an NSG is attached. Omitting the NSG on `subnet-lb` is simpler for the exercise.
- Default Azure NSG rules deny all inbound internet traffic unless explicitly allowed; explicit deny rules in the Terraform code make the intent clear.

### TLS offloading

TLS is terminated at Application Gateway. Backend containers receive plain HTTP on port 8080. This is acceptable for an exercise scenario where the VNet is a trusted boundary. In production, consider end-to-end TLS (Application Gateway talks HTTPS to backends) to prevent eavesdropping on the VNet fabric itself. The `backend_http_settings` `protocol = "Http"` setting is the single control point for this behavior.

### Self-signed certificate

The self-signed certificate is acceptable for the exercise. For production or staging, use Azure Key Vault with `azurerm_key_vault_certificate` and reference it via `key_vault_secret_id` in the `ssl_certificate` block, or use Azure App Service Managed Certificates / Let's Encrypt via cert-manager.

### WAF considerations

Application Gateway v2 is available in both `Standard_v2` and `WAF_v2` tiers. The exercise uses `Standard_v2` to avoid WAF licensing costs. For production APIs, `WAF_v2` with OWASP 3.2 ruleset is recommended. The `sku` block's `name` and `tier` attributes both change to `"WAF_v2"`, and a `waf_configuration` block is added.

### Managed Identity for backends

For the stretch goal (Storage Account access from containers), use an Azure Managed Identity rather than connection strings. Assign `Storage Blob Data Reader` role to the container group's system-assigned managed identity. The `azurerm_container_group` resource supports `identity` blocks. This avoids secrets in environment variables.

### Azure Well-Architected Framework alignment

| Pillar | Applied practice |
|---|---|
| Security | Private subnet for backends; NSG denies direct internet access; TLS at gateway |
| Reliability | Application Gateway v2 is zone-redundant by default when capacity ≥ 2; set `capacity = 2` for HA |
| Cost Optimization | `capacity = 1` for the exercise; `Standard_v2` auto-scales to 0 when idle (min capacity = 0 supported) |
| Operational Excellence | All infra in Terraform; `terraform destroy` + `terraform apply` cycle verified by the exercise |
| Performance Efficiency | ACI containers start in ~30s; suitable for the exercise but not for latency-sensitive production workloads |

---

## Known limitations and open questions

### 1. Weighted canary split (critical)

**Azure Application Gateway Standard_v2 does not support weighted routing between two different backend pools in a single path rule.** This is a fundamental architectural gap versus AWS ALB's weighted forward action. The homework spec (`request_routing_rule` with multiple `backend_address_pool` targets) does not map cleanly to an Application Gateway capability.

Recommended alternatives ranked by fit for this exercise:

| Option | Weighted split | VNet-private backends | Complexity |
|---|---|---|---|
| **Azure Container Apps** (replace ACI; use `ingress.traffic` weights) | Native 0–100 weight per revision | Yes (Container Apps Environment in VNet) | Medium |
| **Azure Front Door Premium** (global layer in front of Application Gateway) | Native weighted origin group | Backends via Private Link | Medium-High |
| **NGINX / Envoy sidecar inside ACI** (proxy that forwards 90/10 by configuration) | Yes (proxy-level) | Yes | High |
| Application Gateway alone | Not supported | Yes | N/A |

The Terraform placeholder in `appgateway.tf` routes 100% to pool-v1 for the `/items*` path until this is resolved.

> ❓ OPEN QUESTION: Which approach should students use for the 90/10 canary split — Container Apps, Front Door, or a proxy sidecar? The answer determines whether `azurerm_container_group` should be replaced with `azurerm_container_app` and whether a Container Apps Environment is needed.

### 2. ACI subnet delegation constraint

The `subnet-backend` subnet is delegated to `Microsoft.ContainerInstance/containerGroups`. This means:
- No other resource types (VMs, AKS nodes, private endpoints) can be placed in this subnet.
- The stretch goal's Private Endpoint requires a separate subnet (`subnet-pe`).

### 3. DNS zone for `.local` domains

Azure Public DNS zones cannot be authoritative for `.local` because no registrar delegates it. Use `/etc/hosts` for local testing or use a real domain. Azure Private DNS zones work for VNet-internal resolution only.

### 4. Application Gateway provisioning time

Application Gateway v2 takes 5–10 minutes to provision. This is normal. `terraform apply` will wait; do not interrupt it.

### 5. Container image availability

The images `<registry>.azurecr.io/lesson03-api-v1:latest` and `lesson03-api-v2:latest` must be pushed to ACR before `terraform apply`. If they do not exist or ACI cannot authenticate, the deployment fails with an image pull error (not a Terraform error). Check ACI events in the Azure Portal or with `az container logs --name aci-api-v1 --resource-group <rg>`. Ensure anonymous pull is enabled on the ACR (`az acr update --name <registry> --anonymous-pull-enabled true`) or that `image_registry_credential` blocks are present in each `azurerm_container_group`.

### 6. ACI private IP non-determinism

ACI containers in a VNet receive a private IP from the subnet CIDR via DHCP. The IP is not predictable before the container is created. The Application Gateway backend pool is populated with the IP after `azurerm_container_group` resources are created (Terraform handles ordering via resource references). On `terraform destroy` + `terraform apply`, the IPs may change, and the Application Gateway backend pool will be updated automatically.

### 7. terraform.tfvars security

The `tls_pfx_base64` and `tls_pfx_password` variables are marked `sensitive = true`. Do not commit `terraform.tfvars` to source control if it contains these values. Add `terraform.tfvars` to `.gitignore`.
