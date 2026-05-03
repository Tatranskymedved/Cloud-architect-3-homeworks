# Azure Implementation — Module 2: Compute (Image Thumbnail Generator)

---

## Azure service mapping

| Homework component | Azure service | SKU / tier | Why |
|---|---|---|---|
| Virtual machine (2 vCPU, 4 GB RAM) | Azure Virtual Machine | Standard_B2s (2 vCPU, 4 GiB) | Cheapest general-purpose SKU that satisfies the spec; burstable CPU is fine for a thumbnail workload with no sustained CPU pressure |
| VM public IP | Azure Public IP | Basic SKU, static allocation | Static assignment lets you test without chasing a changing IP; Basic is sufficient for a single VM with no zone redundancy requirement |
| VM network interface | Azure Network Interface | — (no SKU choice) | Required to attach the VM to the VNet |
| Virtual network + subnet | Azure Virtual Network | — | Provides the shared network boundary so all three deployments can be in the same `/16` address space |
| Firewall / port rules | Azure Network Security Group | — | Allows inbound TCP 80, 443, 22; default deny everything else |
| Managed container platform | Azure Container Apps + Container Apps Environment | Consumption workload profile | Serverless container hosting with per-second billing; handles restarts and scheduling without needing AKS |
| Container registry | Azure Container Registry | Basic SKU | 10 GB included storage, sufficient for one small image; supports `az acr build` |
| Serverless function | Azure Functions on Consumption plan | Linux, Python 3.11 runtime | True scale-to-zero, per-invocation billing; HTTP trigger is built-in, no separate API Gateway needed |
| Function host storage | Azure Storage Account (General Purpose v2) | LRS, Standard | Required by the Functions host for deployment artifacts and internal state |
| Test image object storage | Azure Blob Storage container | inside the shared storage account above | Keeps the resource count low; CORS can be enabled if needed for browser-based upload tests |
| Managed identity | Azure User-Assigned Managed Identity | — | Grants Container Apps and Functions access to ACR and Blob Storage without storing credentials in Terraform state |

---

## Architecture diagram (text)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Resource group: rg-thumbnail-dev                                           │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Virtual Network: vnet-thumbnail (10.0.0.0/16)                       │   │
│  │                                                                      │   │
│  │  subnet-vm  10.0.1.0/24          subnet-apps  10.0.2.0/24           │   │
│  │  ┌─────────────────┐             ┌──────────────────────────────┐   │   │
│  │  │  NSG             │             │  Container Apps Environment   │   │   │
│  │  │  allow 80,443,22 │             │  (Consumption workload)       │   │   │
│  │  │                  │             │  ┌────────────────────────┐   │   │   │
│  │  │  ┌────────────┐  │             │  │  Container App          │   │   │   │
│  │  │  │  Linux VM   │  │             │  │  thumbnail-container    │   │   │   │
│  │  │  │  Standard_  │  │             │  │  POST /thumbnail        │   │   │   │
│  │  │  │  B2s        │  │             │  │  image: acr/thumbnail   │   │   │   │
│  │  │  │  Gunicorn   │  │             │  └────────────────────────┘   │   │   │
│  │  │  │  port 80    │  │             └──────────────────────────────┘   │   │
│  │  │  └────────────┘  │                                                 │   │
│  │  │  Public IP       │             ┌──────────────────────────────┐   │   │
│  │  └─────────────────┘             │  Azure Functions              │   │   │
│  │                                  │  Consumption plan (Linux)     │   │   │
│  │                                  │  Python 3.11                  │   │   │
│  │                                  │  HTTP trigger → /thumbnail    │   │   │
│  │                                  └──────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────┐   ┌───────────────────────┐                       │
│  │  Azure Container    │   │  Azure Storage Account │                       │
│  │  Registry (Basic)   │   │  (GPv2, LRS)           │                       │
│  │  thumbnail image    │   │  • func-host container  │                       │
│  │                     │   │  • test-images blob     │                       │
│  └─────────────────────┘   └───────────────────────┘                       │
│                                                                             │
│  ┌───────────────────────────────────────┐                                 │
│  │  User-Assigned Managed Identity        │                                 │
│  │  Role: AcrPull (on ACR)               │                                 │
│  │  Role: Storage Blob Data Reader (on SA)│                                 │
│  └───────────────────────────────────────┘                                 │
└─────────────────────────────────────────────────────────────────────────────┘

Load-test client (local machine)
  │── POST http://<vm-ip>/thumbnail
  │── POST https://<container-app-fqdn>/thumbnail
  └── POST https://<function-app-name>.azurewebsites.net/api/thumbnail
```

---

## Terraform file structure

```
homeworks/module2/
├── terraform/
│   ├── shared/              # shared resources (VNet, NSG, ACR, Storage, Identity)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── vm/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── cloud-init.yaml  # user_data script
│   ├── container/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── serverless/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── src/
    └── thumbnail/
        ├── app.py           # Gunicorn/FastAPI handler (used by VM + Container)
        ├── function_app.py  # Azure Functions handler (used by Serverless)
        ├── requirements.txt # Pillow, fastapi, uvicorn[standard]
        └── Dockerfile
```

> ❓ OPEN QUESTION: The homework spec says each deployment is a standalone root module. The shared resources (VNet, Storage, ACR, Identity) must exist before the VM/Container/Serverless modules run. Two options: (a) add a fourth `module2_shared/` root module that students apply first, or (b) duplicate the shared resources inside each module and accept the redundancy. Option (a) is cleaner but adds a deployment step. Which approach should students use?

---

## Terraform resource definitions

### module2_shared/main.tf

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── Resource group ──────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = var.common_tags
}

# ── Virtual network ──────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "vnet-thumbnail"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "subnet-vm"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "apps" {
  name                 = "subnet-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# ── Network security group (VM subnet) ──────────────────────────────────────
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-thumbnail-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"      # restrict to your IP in production
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_source_cidr  # your public IP; never "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ── Container Registry ───────────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                = var.acr_name  # must be globally unique, alphanumeric only
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"

  # Basic SKU does not support private endpoints or geo-replication;
  # adequate for a student exercise with a single image.
  admin_enabled = false  # use managed identity instead of admin credentials
}

# ── Storage account (shared: function host + test images) ───────────────────
resource "azurerm_storage_account" "main" {
  name                     = var.storage_account_name  # globally unique, 3-24 lowercase alphanumeric
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"  # cheapest option; no geo-redundancy needed for a lab

  # Disable public blob access at the account level; individual containers
  # can still be accessed via SAS tokens or managed identity.
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "test_images" {
  name                  = "test-images"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

# ── User-assigned managed identity ──────────────────────────────────────────
resource "azurerm_user_assigned_identity" "thumbnail" {
  name                = "id-thumbnail"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Grant AcrPull so Container Apps and Functions can pull the image
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.thumbnail.principal_id
}

# Grant Storage Blob Data Reader for reading test images
resource "azurerm_role_assignment" "storage_reader" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.thumbnail.principal_id
}
```

### module2_shared/variables.tf

```hcl
variable "resource_group_name" {
  type    = string
  default = "rg-thumbnail-dev"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "acr_name" {
  type        = string
  description = "Globally unique ACR name (alphanumeric, 5-50 chars)"
}

variable "storage_account_name" {
  type        = string
  description = "Globally unique storage account name (3-24 lowercase alphanumeric)"
}

variable "ssh_source_cidr" {
  type        = string
  description = "Your public IP in CIDR notation, e.g. 203.0.113.10/32"
}

variable "common_tags" {
  type = map(string)
  default = {
    project     = "module2-compute"
    environment = "dev"
    managed_by  = "terraform"
  }
}
```

### module2_shared/outputs.tf

```hcl
output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "subnet_vm_id" {
  value = azurerm_subnet.vm.id
}

output "subnet_apps_id" {
  value = azurerm_subnet.apps.id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_id" {
  value = azurerm_storage_account.main.id
}

output "managed_identity_id" {
  value = azurerm_user_assigned_identity.thumbnail.id
}

output "managed_identity_principal_id" {
  value = azurerm_user_assigned_identity.thumbnail.principal_id
}
```

---

### module2_vm/main.tf

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── Public IP ────────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "vm" {
  name                = "pip-thumbnail-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Basic"  # Basic is sufficient for a single VM dev lab
}

# ── Network interface ────────────────────────────────────────────────────────
resource "azurerm_network_interface" "vm" {
  name                = "nic-thumbnail-vm"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_vm_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ── Virtual machine ──────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "thumbnail" {
  name                = "vm-thumbnail"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = "Standard_B2s"  # 2 vCPU, 4 GiB RAM — matches spec

  admin_username = var.admin_username

  # Use SSH key auth only; password auth is disabled for security.
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  disable_password_authentication = true

  network_interface_ids = [azurerm_network_interface.vm.id]

  os_disk {
    name                 = "osdisk-thumbnail-vm"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"  # cheapest option; Premium not needed for this workload
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init script installs Python, Pillow, and starts Gunicorn as a
  # systemd service on port 80.
  custom_data = filebase64("${path.module}/cloud-init.yaml")

  tags = var.common_tags
}
```

### module2_vm/cloud-init.yaml

```yaml
#cloud-config
package_update: true
package_upgrade: false

packages:
  - python3
  - python3-pip
  - python3-venv
  - git

write_files:
  - path: /opt/thumbnail/app.py
    content: |
      import io
      from fastapi import FastAPI, Request, HTTPException, Response

      app = FastAPI()

      @app.post("/thumbnail")
      async def thumbnail(request: Request):
          body = await request.body()
          if not body:
              raise HTTPException(status_code=400, detail="Empty body")
          try:
              from PIL import Image
              img = Image.open(io.BytesIO(body))
              img.thumbnail((128, 128))
              buf = io.BytesIO()
              fmt = img.format or "JPEG"
              img.save(buf, format=fmt)
              return Response(content=buf.getvalue(),
                              media_type="image/jpeg" if fmt == "JPEG" else "image/png")
          except Exception as e:
              raise HTTPException(status_code=422, detail=str(e))

  - path: /etc/systemd/system/thumbnail.service
    content: |
      [Unit]
      Description=Thumbnail Service
      After=network.target

      [Service]
      User=www-data
      WorkingDirectory=/opt/thumbnail
      ExecStart=/opt/thumbnail/.venv/bin/uvicorn app:app --host 0.0.0.0 --port 80
      Restart=always

      [Install]
      WantedBy=multi-user.target

runcmd:
  - python3 -m venv /opt/thumbnail/.venv
  - /opt/thumbnail/.venv/bin/pip install fastapi uvicorn[standard] Pillow
  - chown -R www-data:www-data /opt/thumbnail
  - systemctl daemon-reload
  - systemctl enable thumbnail
  - systemctl start thumbnail
```

### module2_vm/outputs.tf

```hcl
output "endpoint_url" {
  value       = "http://${azurerm_public_ip.vm.ip_address}/thumbnail"
  description = "POST this URL with a JPEG/PNG body to get a 128x128 thumbnail"
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}
```

---

### module2_container/main.tf

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── Log Analytics workspace (required by Container Apps Environment) ─────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-thumbnail"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30  # minimum; reduce cost by shortening retention
}

# ── Container Apps Environment ───────────────────────────────────────────────
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-thumbnail"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  # Workload profile type "Consumption" is the serverless/pay-per-use model.
  # Omitting workload_profile blocks defaults to the Consumption environment,
  # which has no minimum instance cost when idle.
}

# ── Container App ────────────────────────────────────────────────────────────
resource "azurerm_container_app" "thumbnail" {
  name                         = "ca-thumbnail"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.managed_identity_id  # pulls using the managed identity, no password
  }

  ingress {
    external_enabled = true
    target_port      = 80

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0  # scale to zero when idle — observe cold start behaviour
    max_replicas = 3

    container {
      name   = "thumbnail"
      image  = "${var.acr_login_server}/thumbnail:latest"
      cpu    = 0.5
      memory = "1Gi"

      # Liveness probe — restart the container if the app is wedged
      liveness_probe {
        path             = "/thumbnail"
        port             = 80
        transport        = "HTTP"
        initial_delay    = 5
        interval_seconds = 30
      }
    }
  }
}
```

> ⚠️ NEEDS USER INPUT: The `azurerm_container_app` `liveness_probe` block attribute names (e.g., `initial_delay`, `interval_seconds`) may differ across azurerm provider versions. Verify against the provider changelog for your pinned version (`~> 3.110`). The correct attribute name for the startup delay has been `initial_delay` in recent 3.x releases, but confirm with `terraform providers schema`.

### module2_container/outputs.tf

```hcl
output "endpoint_url" {
  value       = "https://${azurerm_container_app.thumbnail.latest_revision_fqdn}/thumbnail"
  description = "POST this URL with a JPEG/PNG body to get a 128x128 thumbnail"
}
```

---

### module2_serverless/main.tf

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── App Service plan — Consumption (serverless) ──────────────────────────────
resource "azurerm_service_plan" "functions" {
  name                = "asp-thumbnail-consumption"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"  # Y1 = Consumption plan; true scale-to-zero, per-invocation billing
}

# ── Function app ─────────────────────────────────────────────────────────────
resource "azurerm_linux_function_app" "thumbnail" {
  name                       = var.function_app_name  # must be globally unique
  resource_group_name        = var.resource_group_name
  location                   = var.location
  service_plan_id            = azurerm_service_plan.functions.id
  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_access_key
  # Alternatively, set storage_uses_managed_identity = true and assign
  # "Storage Blob Data Owner" + "Storage Queue Data Contributor" roles
  # to the function app's identity, which avoids storing the key in state.

  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }

    # Enable CORS if you want to call the function from a browser
    # cors {
    #   allowed_origins = ["*"]
    # }
  }

  app_settings = {
    # WEBSITE_RUN_FROM_PACKAGE instructs the host to mount the zip as read-only.
    # Set to "1" when deploying via zip (func azure functionapp publish).
    WEBSITE_RUN_FROM_PACKAGE = "1"

    # Disable built-in Application Insights auto-instrumentation if you are
    # not using Application Insights in this lab (saves ~$0.30/GB ingest cost).
    APPINSIGHTS_INSTRUMENTATIONKEY = ""
  }

  tags = var.common_tags
}
```

> ⚠️ NEEDS USER INPUT: `storage_account_access_key` must be supplied as a sensitive variable. If you want to avoid the key appearing in Terraform state entirely, switch to `storage_uses_managed_identity = true` and add the required role assignments (`Storage Blob Data Owner`, `Storage Queue Data Contributor`, `Storage Table Data Contributor`) to the function app's system-assigned identity on the storage account. This is the recommended approach for production but adds complexity for a student lab.

### module2_serverless/variables.tf

```hcl
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "function_app_name"   { type = string }  # globally unique
variable "storage_account_name"       { type = string }
variable "storage_account_access_key" {
  type      = string
  sensitive = true
}
variable "managed_identity_id"        { type = string }
variable "common_tags"                { type = map(string) default = {} }
```

### module2_serverless/outputs.tf

```hcl
output "endpoint_url" {
  value       = "https://${azurerm_linux_function_app.thumbnail.default_hostname}/api/thumbnail"
  description = "POST this URL with a JPEG/PNG body to get a 128x128 thumbnail"
}

output "function_app_name" {
  value = azurerm_linux_function_app.thumbnail.name
}
```

---

## Deployment walkthrough

### Prerequisites

```bash
# 1. Install tools
az --version          # Azure CLI >= 2.55
terraform --version   # Terraform >= 1.7
func --version        # Azure Functions Core Tools >= 4.x
docker --version      # Docker >= 24

# 2. Authenticate
az login
az account set --subscription "<your-subscription-id>"

# 3. (Optional) Create a service principal for CI/CD or Terraform
az ad sp create-for-rbac \
  --name "sp-terraform-thumbnail" \
  --role Contributor \
  --scopes /subscriptions/<your-subscription-id>
# Export ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
```

### Step 1 — Deploy shared resources

```bash
cd homeworks/module2/terraform/shared

cat > terraform.tfvars <<EOF
resource_group_name  = "rg-thumbnail-dev"
location             = "westeurope"
acr_name             = "acrthumbnaildev<your-suffix>"   # globally unique
storage_account_name = "stthumbnaildev<your-suffix>"    # globally unique
ssh_source_cidr      = "$(curl -s https://api.ipify.org)/32"
EOF

terraform init
terraform plan
terraform apply
```

### Step 2 — Build and push the Docker image

```bash
# Log in to ACR using the Azure CLI (no admin password needed)
ACR_NAME=$(terraform -chdir=homeworks/module2/terraform/shared output -raw acr_login_server | cut -d. -f1)
az acr login --name "$ACR_NAME"

# Build and push (or use az acr build for cloud-side build)
docker build -t "$ACR_NAME.azurecr.io/thumbnail:latest" homeworks/module2/src/thumbnail/
docker push "$ACR_NAME.azurecr.io/thumbnail:latest"

# Alternative: build in the cloud (no local Docker daemon required)
az acr build \
  --registry "$ACR_NAME" \
  --image "thumbnail:latest" \
  homeworks/module2/src/thumbnail/
```

### Step 3 — Deploy the VM

```bash
cd homeworks/module2/terraform/vm

cat > terraform.tfvars <<EOF
resource_group_name   = "rg-thumbnail-dev"
location              = "westeurope"
subnet_vm_id          = "$(terraform -chdir=../shared output -raw subnet_vm_id)"
admin_username        = "azureuser"
ssh_public_key_path   = "~/.ssh/id_rsa.pub"
EOF

terraform init && terraform apply

VM_IP=$(terraform output -raw vm_public_ip)
# Wait ~2 min for cloud-init to finish, then test:
curl -X POST "http://$VM_IP/thumbnail" \
  -H "Content-Type: image/jpeg" \
  --data-binary @sample.jpg \
  --output result_vm.jpg
```

### Step 4 — Deploy the container

```bash
cd homeworks/module2/terraform/container

cat > terraform.tfvars <<EOF
resource_group_name  = "rg-thumbnail-dev"
location             = "westeurope"
acr_login_server     = "$(terraform -chdir=../shared output -raw acr_login_server)"
managed_identity_id  = "$(terraform -chdir=../shared output -raw managed_identity_id)"
EOF

terraform init && terraform apply

CONTAINER_URL=$(terraform output -raw endpoint_url)
curl -X POST "$CONTAINER_URL" \
  -H "Content-Type: image/jpeg" \
  --data-binary @sample.jpg \
  --output result_container.jpg
```

### Step 5 — Deploy the serverless function

```bash
# Package and deploy the function code using Azure Functions Core Tools
cd homeworks/module2/src/thumbnail
pip install -r requirements.txt --target .python_packages/lib/site-packages
func azure functionapp publish "$(terraform -chdir=../../terraform/serverless output -raw function_app_name)" --python

# (Alternatively, set WEBSITE_RUN_FROM_PACKAGE and deploy as a zip)

cd ../../terraform/serverless

cat > terraform.tfvars <<EOF
resource_group_name          = "rg-thumbnail-dev"
location                     = "westeurope"
function_app_name            = "func-thumbnail-<your-suffix>"
storage_account_name         = "$(terraform -chdir=../shared output -raw storage_account_name)"
storage_account_access_key   = "$(az storage account keys list \
                                   --account-name <storage-account-name> \
                                   --query '[0].value' -o tsv)"
managed_identity_id          = "$(terraform -chdir=../shared output -raw managed_identity_id)"
EOF

terraform init && terraform apply

FUNCTION_URL=$(terraform output -raw endpoint_url)
curl -X POST "$FUNCTION_URL" \
  -H "Content-Type: image/jpeg" \
  --data-binary @sample.jpg \
  --output result_serverless.jpg
```

### Step 6 — Upload test images to Blob Storage

```bash
STORAGE_NAME=$(terraform -chdir=homeworks/module2/terraform/shared output -raw storage_account_name)
az storage blob upload \
  --account-name "$STORAGE_NAME" \
  --container-name test-images \
  --name sample.jpg \
  --file sample.jpg \
  --auth-mode login
```

### Step 7 — Tear down (in reverse order)

```bash
terraform -chdir=homeworks/module2/terraform/serverless destroy
terraform -chdir=homeworks/module2/terraform/container destroy
terraform -chdir=homeworks/module2/terraform/vm destroy
terraform -chdir=homeworks/module2/terraform/shared destroy
```

---

## Testing strategy

### Smoke test (single request)

```bash
# Returns HTTP 200 and a valid binary body; save and open the output file
curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT" \
  -H "Content-Type: image/jpeg" --data-binary @sample.jpg
# Expected: 200

# Error case: send a text file, expect 400 or 422
curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT" \
  -H "Content-Type: image/jpeg" --data-binary @README.md
# Expected: 400 or 422 (not 500)
```

### Cold start measurement

```bash
# 1. Force idle state:
#    VM:          az vm deallocate --resource-group rg-thumbnail-dev --name vm-thumbnail
#    Container:   set min_replicas = 0 in Terraform, apply, then wait 5 minutes with no traffic
#    Serverless:  no action needed — Consumption plan scales to zero automatically after ~5 min idle

# 2. Record response time (5 repetitions per platform):
for i in {1..5}; do
  curl -s -o /dev/null -w "%{time_total}\n" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: image/jpeg" \
    --data-binary @sample.jpg
  sleep 10  # allow function to go cold again between VM tests (VM will not go cold — omit sleep for VM)
done
```

> ❓ OPEN QUESTION: For the VM cold start test, the spec says "shut down the VM." After an `az vm start`, cloud-init does not re-run, so the systemd service should start immediately. The cold start for the VM therefore measures OS boot time, not application init time. Should students measure from `az vm start` to first HTTP 200 (which requires polling), or simply record the first HTTP response time after the VM is already running (which measures only application latency)? The spec is ambiguous here.

### k6 load test

Install k6: https://k6.io/docs/getting-started/installation/

```javascript
// load_test.js
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

// Load a sample image once — k6 does not natively read binary files from disk;
// use a base64-encoded copy embedded in the script, or serve from blob storage.
const ENDPOINT = __ENV.ENDPOINT;

export const options = {
  scenarios: {
    low_load: {
      executor: 'constant-vus',
      vus: 10,
      duration: '60s',
    },
  },
};

export default function () {
  // POST a small JPEG (embed a minimal valid JPEG in base64 here, or use
  // a pre-uploaded blob SAS URL as the source image to avoid binary embedding)
  const res = http.post(ENDPOINT, open('./sample.jpg', 'b'), {
    headers: { 'Content-Type': 'image/jpeg' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

```bash
# 10 concurrent users, 60 seconds
k6 run -e ENDPOINT="$VM_URL"        load_test.js 2>&1 | tee results/load_vm_10.txt
k6 run -e ENDPOINT="$CONTAINER_URL" load_test.js 2>&1 | tee results/load_container_10.txt
k6 run -e ENDPOINT="$FUNCTION_URL"  load_test.js 2>&1 | tee results/load_serverless_10.txt

# 50 concurrent users, 60 seconds — change vus to 50 in options or override via --vus
k6 run --vus 50 -e ENDPOINT="$VM_URL"        load_test.js 2>&1 | tee results/load_vm_50.txt
k6 run --vus 50 -e ENDPOINT="$CONTAINER_URL" load_test.js 2>&1 | tee results/load_container_50.txt
k6 run --vus 50 -e ENDPOINT="$FUNCTION_URL"  load_test.js 2>&1 | tee results/load_serverless_50.txt
```

> ⚠️ NEEDS USER INPUT: k6's `open()` function for binary files requires running with `--http-debug` or using `SharedArray` with base64 decoding; confirm the exact pattern for your k6 version. The simpler alternative is to use Apache Bench: `ab -n 600 -c 10 -p sample.jpg -T image/jpeg "$ENDPOINT"`.

### Cost estimation

**Approach 1 — Azure Pricing Calculator (manual)**

1. Go to https://azure.microsoft.com/en-us/pricing/calculator/
2. Add each component:
   - Standard_B2s VM (West Europe, Linux, Pay As You Go): ~$0.042/hour = ~$30/month always-on
   - Container Apps (Consumption): billed per vCPU-second and GiB-second; at 0 idle cost
   - Azure Functions (Consumption): first 1 million executions/month free; $0.20 per additional million; compute at $0.000016/GB-s
3. Compute request count: 10 req/min × 60 × 24 × 30 = 432,000 req/month; 1,000 req/min = 43.2 million req/month

**Approach 2 — CLI after deployment (actual usage)**

```bash
# View cost for the resource group over the last 30 days
az consumption usage list \
  --start-date $(date -d "30 days ago" +%Y-%m-%d) \
  --end-date $(date +%Y-%m-%d) \
  --query "[?contains(instanceId,'rg-thumbnail-dev')].[pretaxCost,currency,product]" \
  -o table
```

> ⚠️ NEEDS USER INPUT: The `az consumption` command requires the `Microsoft.Consumption` resource provider to be registered and is not available on all subscription types (e.g., free trial or CSP subscriptions). Students on such subscriptions should use the Pricing Calculator exclusively.

---

## Security and architecture notes

### Identity and access

- **No shared secrets for image pulls.** The Container App and Functions identity pull from ACR using the User-Assigned Managed Identity with `AcrPull`. The `admin_enabled = false` setting on the ACR resource prevents use of the registry admin password.
- **SSH access is restricted by source IP** via the `ssh_source_cidr` NSG rule. Students must supply their own public IP. Opening SSH to `*` is a common mistake that should be flagged in code review.
- **Storage account access key in Terraform state.** If `storage_uses_managed_identity = true` is not used for the Functions storage account, the access key will appear in `terraform.tfstate`. This is acceptable for a short-lived lab but must not be committed to source control. Add `terraform.tfstate` to `.gitignore`.

### Network exposure

- The VM is the only resource with a direct public IP. The Container App and Function endpoints are served over HTTPS with TLS managed by Azure; the VM endpoint is HTTP only (port 80). For a real deployment, a TLS certificate and Azure Application Gateway or Front Door would be required in front of the VM.
- All three deployments are in the same VNet; they can communicate with each other over private IPs. The load-test client runs locally and reaches all three endpoints over the public internet.

### Well-Architected Framework notes

| Pillar | Concern | Recommendation |
|---|---|---|
| Security | VM SSH exposed publicly | Restrict to bastion host or use Azure Bastion; remove public IP after setup |
| Cost Optimization | VM runs 24/7 even in lab | Deallocate the VM when not testing (`az vm deallocate`) to stop compute charges |
| Reliability | Container min_replicas = 0 | This is intentional for cold-start measurement; set to 1 in production to avoid cold starts |
| Operational Excellence | Manual function deployment | Use GitHub Actions `azure/functions-action` to deploy on push to main |
| Performance Efficiency | Single Container App replica | Adequate for the lab; increase `max_replicas` and add HTTP scaling rules for production |

---

## Known limitations and open questions

1. **Shared module dependency.** The `module2_shared/` root module must be applied before the other three. Terraform remote state (`azurerm` backend) should be used to share outputs between modules, but this requires a pre-existing storage account — a chicken-and-egg problem. For the lab, students can use `terraform output` and pass values as `tfvars`. The instructor should decide whether to require a remote backend setup or allow local state.

2. **Function deployment method.** Terraform can provision the Function App infrastructure but cannot deploy function code directly with the `azurerm` provider alone. Students must use either `func azure functionapp publish` (Core Tools) or a GitHub Actions workflow. The Terraform resource sets `WEBSITE_RUN_FROM_PACKAGE = "1"` but the zip must be deployed separately.

3. **Cold start definition for the VM.** See the open question in the Testing Strategy section. The VM never truly "goes cold" in the serverless sense; OS boot time is a different phenomenon from application cold start.

4. **Container App liveness probe attribute names.** Marked with `NEEDS USER INPUT` above — verify against the installed provider version before applying.

5. **Consumption plan region availability.** Azure Functions Consumption plan on Linux is available in most regions but not all. If `terraform apply` fails with a capacity error, try `eastus` or `northeurope` instead of `westeurope`.

6. **ACR Basic SKU and Container Apps.** Basic ACR with `admin_enabled = false` and managed identity pull works in most regions, but if the Container App Environment and ACR are in different regions, egress charges apply. Keep all resources in the same region.

7. **Pillow binary dependencies.** The `Pillow` library requires native binaries. In the Azure Functions Consumption plan, the build must happen on Linux (use `--build remote` with the Core Tools, or set `SCM_DO_BUILD_DURING_DEPLOYMENT=true` in `app_settings`). A mismatch between the local build platform (Windows/macOS) and the Linux runtime will cause import errors at cold start.

   > ⚠️ NEEDS USER INPUT: Confirm whether the course instructor expects students to use `func azure functionapp publish --build remote` or a Docker-based local build. Add the appropriate `app_settings` key to the Terraform resource if remote build is required.
