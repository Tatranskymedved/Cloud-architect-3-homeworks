# Module 2 — Terraform Azure Infrastructure

Three standalone Terraform root modules that provision the thumbnail-generator homework on Azure:

| Module | What it creates |
|---|---|
| `shared/` | Resource group, VNet, NSG, ACR, Storage Account, Managed Identity |
| `vm/` | Standard_B2s Ubuntu VM with Gunicorn on port 80 (via cloud-init) |
| `container/` | Container Apps Environment + Container App (min 0 replicas) |
| `serverless/` | App Service Plan Y1 + Python 3.11 Linux Function App |

**Apply order:** `shared` first, then `vm` / `container` / `serverless` in any order.

All commands below are written for **Windows PowerShell**.

---

## Prerequisites

Install the following tools (run each installer, then reopen PowerShell):

- **Azure CLI** — https://aka.ms/installazurecliwindows
- **Terraform** — https://developer.hashicorp.com/terraform/install (pick Windows AMD64, unzip, add to PATH)
- **Azure Functions Core Tools** — https://github.com/Azure/azure-functions-core-tools/releases (v4 Windows x64 MSI)
- **Docker Desktop** — https://www.docker.com/products/docker-desktop (only needed for local image builds)

Verify:

```powershell
az --version
terraform --version
func --version
docker --version
```

---

## 1. Validate (no Azure login required)

Run `init` + `validate` in each module. These are purely offline checks — nothing touches Azure.

```powershell
$base = "homeworks/module2/terraform_az"

foreach ($module in @("shared", "vm", "container", "serverless")) {
    Write-Host "=== $module ===" -ForegroundColor Cyan
    terraform -chdir="$base/$module" init -input=false
    terraform -chdir="$base/$module" validate
}
```

Expected output for each module: `Success! The configuration is valid.`

---

## 2. Apply to Azure

### Step 1 — Authenticate

```powershell
az login
# A browser window opens — sign in with your Azure account

az account set --subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# Paste your Subscription ID from portal.azure.com → Subscriptions

# Confirm the right subscription is active
az account show --output table
```

No environment variables needed — Terraform reads the active Azure CLI session automatically.

### Step 2 — Find your public IP

The NSG restricts SSH to your IP only. Get it:

```powershell
(Invoke-RestMethod https://api.ipify.org)
# Example output: 85.160.42.11
# Your ssh_source_cidr will be: 85.160.42.11/32
```

### Step 3 — Generate an SSH key (if you don't have one)

```powershell
ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\id_rsa"
# Press Enter twice to skip the passphrase

# Print the public key — you'll paste this into terraform.tfvars below
Get-Content "$env:USERPROFILE\.ssh\id_rsa.pub"
```

### Step 4 — Deploy shared resources

```powershell
Set-Location homeworks/module2/terraform_az/shared

# Create the variables file — fill in YOUR public IP before applying
@'
resource_group_name = "rg-thumbnail-dev"
location            = "westeurope"
prefix              = "thumbnail"
ssh_source_cidr     = "YOUR_PUBLIC_IP/32"
'@ | Set-Content terraform.tfvars

terraform init -input=false
terraform plan
terraform apply
# Type: yes
```

Capture outputs into PowerShell variables for the steps below:

```powershell
$RG_NAME      = terraform output -raw resource_group_name
$LOCATION     = terraform output -raw location
$SUBNET_VM_ID = terraform output -raw subnet_vm_id
$ACR_LOGIN    = terraform output -raw acr_login_server
$SA_NAME      = terraform output -raw storage_account_name
$SA_ID        = terraform output -raw storage_account_id
$MI_ID        = terraform output -raw managed_identity_id

Write-Host "Resource group : $RG_NAME"
Write-Host "ACR            : $ACR_LOGIN"
Write-Host "Storage account: $SA_NAME"
```

> These variables live only in the current PowerShell session. If you close and reopen PowerShell, re-run this block from the `shared/` directory.

### Step 5 — Build and push the Docker image

> **Free / student subscriptions:** `az acr build` (cloud-side build) is disabled on free trial and student subscriptions with a `TasksOperationsNotAllowed` error. Use the local Docker build below instead.
> Docker Desktop must be installed and running (whale icon in taskbar = ready): https://www.docker.com/products/docker-desktop

```powershell
$ACR_NAME = $ACR_LOGIN.Split(".")[0]
az acr login --name $ACR_NAME

docker build -t "$ACR_LOGIN/thumbnail:latest" homeworks/module2/src/thumbnail/
docker push "$ACR_LOGIN/thumbnail:latest"

# Verify the image arrived in ACR
az acr repository list --name $ACR_NAME --output table
```

### Step 6 — Deploy the VM

```powershell
Set-Location homeworks/module2/terraform_az/vm

$SSH_KEY = Get-Content "$env:USERPROFILE\.ssh\id_rsa.pub" -Raw

@"
resource_group_name = "$RG_NAME"
location            = "$LOCATION"
subnet_vm_id        = "$SUBNET_VM_ID"
admin_username      = "azureuser"
ssh_public_key      = "$($SSH_KEY.Trim())"
"@ | Set-Content terraform.tfvars

terraform init -input=false
terraform plan
terraform apply
# Type: yes

$VM_URL = terraform output -raw endpoint_url
Write-Host "VM endpoint: $VM_URL"
```

> The VM takes ~4 minutes after `apply` finishes — cloud-init installs Python and starts the service. Wait before testing.

### Step 7 — Deploy the Container App

```powershell
Set-Location homeworks/module2/terraform_az/container

@"
resource_group_name = "$RG_NAME"
location            = "$LOCATION"
acr_login_server    = "$ACR_LOGIN"
managed_identity_id = "$MI_ID"
"@ | Set-Content terraform.tfvars

terraform init -input=false
terraform plan
terraform apply
# Type: yes

$CONTAINER_URL = terraform output -raw endpoint_url
Write-Host "Container endpoint: $CONTAINER_URL"
```

### Step 8 — Deploy the Function App

```powershell
Set-Location homeworks/module2/terraform_az/serverless

# Generate a unique suffix so the Function App name is globally unique
$SUFFIX    = [System.Guid]::NewGuid().ToString().Substring(0, 8)
$FUNC_NAME = "func-thumbnail-$SUFFIX"

@"
resource_group_name  = "$RG_NAME"
location             = "$LOCATION"
function_app_name    = "$FUNC_NAME"
storage_account_name = "$SA_NAME"
storage_account_id   = "$SA_ID"
managed_identity_id  = "$MI_ID"
"@ | Set-Content terraform.tfvars

terraform init -input=false
terraform plan
terraform apply
# Type: yes

$FUNC_URL = terraform output -raw endpoint_url
Write-Host "Function endpoint: $FUNC_URL"
```

### Step 9 — Deploy the Function code

Terraform creates the Function App infrastructure but does not upload the Python code. Do that separately:

```powershell
Set-Location homeworks/module2/src/thumbnail

$FUNC_NAME = terraform -chdir="../../terraform_az/serverless" output -raw function_app_name

func azure functionapp publish $FUNC_NAME --python --build remote
# --build remote: Azure compiles Pillow against Linux so it runs correctly
```

### Step 10 — Smoke test all three endpoints

Prepare any valid JPEG file named `sample.jpg`, then:

```powershell
$SAMPLE = "sample.jpg"

foreach ($URL in @($VM_URL, $CONTAINER_URL, $FUNC_URL)) {
    Write-Host "Testing: $URL"
    $response = curl.exe -s -o result.jpg -w "%{http_code}" `
        -X POST $URL `
        -H "Content-Type: image/jpeg" `
        --data-binary "@$SAMPLE"
    Write-Host "  HTTP $response (expected 200)"
}

# Open result.jpg to confirm it is a 128x128 thumbnail
Start-Process result.jpg

# Error case — send a text file, expect 400 or 422 (not 500)
foreach ($URL in @($VM_URL, $CONTAINER_URL, $FUNC_URL)) {
    $response = curl.exe -s -o NUL -w "%{http_code}" `
        -X POST $URL `
        -H "Content-Type: image/jpeg" `
        --data-binary "@README.md"
    Write-Host "Error case $URL → HTTP $response (expected 400 or 422)"
}
```

> `curl.exe` is used explicitly to call the real curl binary. PowerShell's built-in `curl` is an alias for `Invoke-WebRequest` and behaves differently.

### Step 11 — Tear down

Destroy in reverse dependency order (shared last):

```powershell
$base = "homeworks/module2/terraform_az"

terraform -chdir="$base/serverless" destroy
terraform -chdir="$base/container"  destroy
terraform -chdir="$base/vm"         destroy
terraform -chdir="$base/shared"     destroy
```

Verify no billable resources remain:

```powershell
az resource list --resource-group rg-thumbnail-dev --output table
# Expected: empty list or "resource group not found"
```

---

## Variables reference

### shared/

| Variable | Required | Default | Notes |
|---|---|---|---|
| `resource_group_name` | no | `rg-thumbnail-dev` | |
| `location` | no | `westeurope` | Use `eastus` or `northeurope` if Consumption plan unavailable |
| `prefix` | no | `thumbnail` | 2–10 lowercase alphanumeric/hyphen; used to derive unique ACR and SA names |
| `ssh_source_cidr` | no | `0.0.0.0/0` | **Set to your IP** — `0.0.0.0/0` leaves SSH open to the internet |

### vm/

| Variable | Required | Default | Notes |
|---|---|---|---|
| `resource_group_name` | **yes** | — | From `shared` output |
| `subnet_vm_id` | **yes** | — | From `shared` output |
| `ssh_public_key` | **yes** | — | Contents of `~/.ssh/id_rsa.pub` |
| `admin_username` | no | `azureuser` | |

### container/

| Variable | Required | Default | Notes |
|---|---|---|---|
| `resource_group_name` | **yes** | — | From `shared` output |
| `acr_login_server` | **yes** | — | From `shared` output |
| `managed_identity_id` | **yes** | — | From `shared` output |

### serverless/

| Variable | Required | Default | Notes |
|---|---|---|---|
| `resource_group_name` | **yes** | — | From `shared` output |
| `function_app_name` | **yes** | — | Globally unique; e.g. `func-thumbnail-<suffix>` |
| `storage_account_name` | **yes** | — | From `shared` output |
| `storage_account_id` | **yes** | — | From `shared` output |
| `managed_identity_id` | **yes** | — | From `shared` output |

---

## Notes

- **`terraform.tfvars` files contain no secrets** — storage access key is never used; the Function App authenticates to Storage via its system-assigned managed identity.
- **Add `terraform.tfstate` to `.gitignore`** — state files may contain sensitive output values.
- **PowerShell variables are session-scoped** — the `$RG_NAME`, `$ACR_LOGIN`, etc. variables set after `shared` apply exist only in the current terminal window. If you close PowerShell, re-run the output capture block before continuing.
- **Consumption plan region** — Linux Consumption (`Y1`) is not available in every region. If `apply` fails with a capacity error, switch `location` to `eastus` or `northeurope`.
- **VM cold start** — for the cold-start exercise, deallocate the VM first: `az vm deallocate -g rg-thumbnail-dev -n vm-thumbnail`, then start it and measure time to first HTTP 200.
- **Container App cold start** — with `min_replicas = 0`, the app scales to zero after ~5 min idle. Send a request after that window to observe the cold start delay.
