# Module 7 — Processes and App Deployment (Azure)

Quote of the Day API with a three-stage CI/CD pipeline, Application Insights telemetry, Azure Monitor alerts, and Azure Policy tag enforcement.

## Architecture

```
  Developer Laptop
  ┌──────────────┐
  │  git push    │
  │  git pr      │
  └──────┬───────┘
         │ push / PR
         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │  GitHub                                                       │
  │                                                               │
  │  PR to main  ──► 07_iac_validate  (fmt, tflint, checkov)     │
  │                                                               │
  │  push to main ─► 07_app_build  (pytest, docker, trivy, push) │
  │                      │                                        │
  │                      ▼                                        │
  │               07_deploy                                       │
  │               Job 1: terraform test                           │
  │               Job 2: staging apply + health check             │
  │               Job 3: [manual approval] prod apply             │
  └──────────────────────────────────────────────────────────────┘
         │
         ▼
  ┌────────────────────────────┐
  │  Azure Container Registry  │
  │  quote-api:latest          │
  └──────────┬─────────────────┘
             │ image pull
     ┌───────┴────────┐
     ▼                ▼
  ┌──────────┐  ┌──────────────┐
  │  ACI     │  │  ACI         │
  │ staging  │  │ production   │
  │ 0.5vCPU  │  │ 0.5vCPU     │
  │ 0.5 GB   │  │ 1 GB         │
  │ :8000    │  │ :8000        │
  └────┬─────┘  └──────┬───────┘
       │ telemetry     │ telemetry
       └───────┬───────┘
               ▼
  ┌──────────────────────────────────────┐
  │  Application Insights (workspace)    │
  │  Transaction search · Live Metrics   │
  └──────────────┬───────────────────────┘
                 │ metric feed
                 ▼
  ┌──────────────────────────────────────┐
  │  Azure Monitor Metric Alerts         │
  │  latency-slo   (p99 > 500 ms)       │
  │  error-rate-slo (5xx rate > 1%)     │
  └──────────────┬───────────────────────┘
                 │ fires
                 ▼
  ┌──────────────────────────────────────┐
  │  Action Group — email notification   │
  └──────────────────────────────────────┘

  ┌──────────────────────────────────────┐
  │  Key Vault (Standard)                │
  │  acr-admin-password                  │
  │  appinsights-connection-string       │
  └──────────────────────────────────────┘

  ┌──────────────────────────────────────┐
  │  Azure Policy (resource group scope) │
  │  Require tag: environment=module7    │
  │  Require tag: owner=<your username>  │
  └──────────────────────────────────────┘
```

> **Cost note:** ACI staging ~€0.02/hr · ACI prod ~€0.03/hr · ACR Basic ~€0.17/day · Key Vault Standard ~negligible · App Insights ~negligible for lab volumes.
> **Destroy when done** (`terraform destroy`) to avoid ongoing charges.

---

## Prerequisites

- Azure CLI ≥ 2.55 — `az --version`
- Terraform ≥ 1.6 — `terraform --version`
- Docker Desktop (to build and push the image) — `docker --version`

All commands below are written for **PowerShell 5.1** (Windows built-in).

---

## 1. Authenticate to Azure

```powershell
az login
az account set --subscription "<your-subscription-id>"
```

---

## 2. Provision infrastructure + build image in parallel

The first apply creates all shared infrastructure (ACR, Key Vault, App Insights, alerts, policy) but **not** the ACI containers — those need the image to exist in ACR first.
The apply takes only ~5–8 minutes. Use that time to build the Docker image in a second terminal.

**Terminal 1 — start Terraform:**
```powershell
cd homeworks/module7/terraform_az

Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
# Fill in: alert_email, owner_tag. Leave container_image = "" for now.

terraform init
terraform validate
# Expected: "Success! The configuration is valid."

terraform plan -out=tfplan
# Review: ~12–14 resources (no ACI yet — container_image is empty)

terraform apply tfplan
```

**Terminal 2 — build the image while Terminal 1 is running:**
```powershell
cd homeworks/module7/src/quote_api
docker build -t quote-api .
# Takes ~1–2 minutes — will be done before terraform apply finishes.
```

---

## 3. Push image to ACR and deploy containers

Once `terraform apply` finishes, ACR exists. Push the pre-built image and deploy both ACI instances.

```powershell
cd homeworks/module7/terraform_az

$ACR_NAME   = terraform output -raw acr_name
$ACR_SERVER = terraform output -raw acr_login_server

# Authenticate Docker to ACR
az acr login --name $ACR_NAME

# Tag and push
docker tag quote-api "$ACR_SERVER/quote-api:latest"
docker push "$ACR_SERVER/quote-api:latest"

# Set container_image and apply — creates staging + prod ACI (~2 min)
Add-Content terraform.tfvars "`ncontainer_image = `"$ACR_SERVER/quote-api:latest`""
terraform apply -auto-approve
```

Key outputs to note:
```powershell
terraform output
```
- `staging_fqdn` — staging container hostname
- `prod_fqdn` — production container hostname
- `acr_login_server` — used to tag/push images
- `acr_name` — used for `az acr login`

> **Startup time:** ACI containers take ~30–60 seconds to start. Wait before testing.

---

## 4. Verify access

> All `terraform output` commands must be run from `homeworks/module7/terraform_az/`.

```powershell
cd homeworks/module7/terraform_az
```

**Confirm the staging FQDN is reachable:**
```powershell
Test-NetConnection -ComputerName (terraform output -raw staging_fqdn) -Port 8000
# Expected: TcpTestSucceeded : True
```

**API health check:**
```powershell
$STAGING = terraform output -raw staging_fqdn
Invoke-RestMethod "http://${STAGING}:8000/healthz"
# Expected: {"status": "ok", "version": "1.0.0"}

Invoke-RestMethod "http://${STAGING}:8000/quotes"
# Expected: {"id": <number>, "text": "...", "author": "..."}
```

**Prometheus metrics:**
```powershell
Invoke-WebRequest "http://${STAGING}:8000/metrics" | Select-Object -ExpandProperty Content
# Expected: lines starting with "# HELP", "# TYPE", "quote_api_requests_total"
```

---

## 5. Verify Application Insights telemetry (Exercise 5)

Generate traffic, then check the Azure portal.

```powershell
cd homeworks/module7/terraform_az
$STAGING = terraform output -raw staging_fqdn

# Send 20 requests to the quotes endpoint
1..20 | ForEach-Object {
    Invoke-RestMethod "http://${STAGING}:8000/quotes" | Out-Null
    Write-Host "Request $_ / 20 sent"
    Start-Sleep -Milliseconds 200
}
Write-Host "Done. Open Application Insights -> Transaction search in the Azure portal."
```

In the Azure portal:
1. Navigate to the Application Insights resource (`<prefix>-ai`).
2. Click **Transaction search** in the left menu.
3. Set time range to **Last 30 minutes** → click **Search**.
4. Confirm you see telemetry items for `GET /quotes` with status `200` within ~5 minutes.

**Verify Application Insights is wired (if traces are missing):**
```powershell
$RG = terraform output -raw resource_group_name
az container show --resource-group $RG --name quoteapi-staging `
    --query "containers[0].environmentVariables[].name"
# Confirm "APPLICATIONINSIGHTS_CONNECTION_STRING" appears in the list.
# The value shows as null — that is expected for secure_environment_variables.
```

---

## 6. Trigger the latency alert (Exercise 6)

### Step 1 — inject artificial latency
Edit `homeworks/module7/src/quote_api/main.py`. Add `import time` at the top (it's already imported) and add `time.sleep(0.7)` as the first line of the `get_quote` function:

```python
@app.get("/quotes")
async def get_quote():
    time.sleep(0.7)          # artificial latency for alert test — remove after exercise
    return random.choice(_quotes)
```

### Step 2 — rebuild and redeploy staging
```powershell
cd homeworks/module7/terraform_az
$ACR_NAME   = terraform output -raw acr_name
$ACR_SERVER = terraform output -raw acr_login_server

cd ../src/quote_api
docker build -t quote-api .
az acr login --name $ACR_NAME
docker tag quote-api "$ACR_SERVER/quote-api:latest"
docker push "$ACR_SERVER/quote-api:latest"

cd ../../terraform_az
terraform apply -target=module.quote_api_staging -auto-approve
```

### Step 3 — generate load
```powershell
$STAGING = terraform output -raw staging_fqdn

1..50 | ForEach-Object {
    Invoke-RestMethod "http://${STAGING}:8000/quotes" | Out-Null
    Write-Host "Request $_ / 50 sent (each takes ~0.7 s)"
}
Write-Host "Load done. Wait up to 10 minutes for alert to fire."
```

### Step 4 — confirm in Azure portal
Navigate to **Monitor → Alerts**. Within 10 minutes, `latency-slo` should transition to **Fired** state.

**Verify via CLI:**
```powershell
$RG = terraform output -raw resource_group_name
terraform state list | Select-String "monitor_metric_alert"
# Expected:
# azurerm_monitor_metric_alert.latency_slo
# azurerm_monitor_metric_alert.error_rate_slo
```

### Step 5 — restore normal behavior
Remove the `time.sleep(0.7)` line from `main.py`, rebuild, and redeploy staging using the same commands as Step 2.

---

## 7. Verify Azure Policy compliance (Exercise 7)

After `terraform apply`, all resources have `environment` and `owner` tags from `common_tags` in `main.tf`. Trigger an immediate compliance scan:

```powershell
cd homeworks/module7/terraform_az
$RG = terraform output -raw resource_group_name

az policy state trigger-scan --resource-group $RG
# Command returns immediately; the scan runs asynchronously. Wait ~5 minutes.

az policy state list --resource-group $RG `
    --filter "complianceState eq 'NonCompliant'" --output table
# Expected: empty table
```

In the portal: **Policy → Compliance** → filter by the resource group. Both `require-environment-tag` and `require-owner-tag` rows should show **Compliant**.

---

## 8. CI/CD exercises

### Exercise 1 — Create `07_iac_validate.yml` and verify it gates bad formatting

The workflow file is already in `.github/workflows/07_iac_validate.yml`. Review it to understand the three steps: `terraform fmt --check`, `tflint`, and `checkov`.

**To test the gate:**
```powershell
# Create a branch with a deliberate formatting error
git checkout -b test/fmt-error
# Remove a blank line between two resource blocks in terraform_az/main.tf
# Then commit and push
git add homeworks/module7/terraform_az/main.tf
git commit -m "test: deliberate fmt error"
git push origin test/fmt-error
```
Open a PR and confirm the `07 IaC Validate` check fails. Fix with `terraform fmt .`, push, and confirm it passes.

### Exercise 2 — Create `07_app_build.yml` and push image to ACR

The workflow is in `.github/workflows/07_app_build.yml`. Before it runs, configure these GitHub repository settings:

**Required secrets** (Settings → Secrets and variables → Actions → Secrets):
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

**Required variables** (Settings → Secrets and variables → Actions → Variables):
- `ACR_NAME` — value from `terraform output -raw acr_name`
- `ALERT_EMAIL` — your email address
- `OWNER_TAG` — your student username

The OIDC service principal must have `Contributor` on the subscription.

**Run Trivy locally first:**
```powershell
cd homeworks/module7/src/quote_api
docker build -t quote-api .
trivy image --exit-code 1 --severity CRITICAL quote-api
# If CRITICAL CVEs appear, add their IDs to .trivyignore with a comment.
```

### Exercise 3 — Run `terraform test` for the `container_instance` module

```powershell
cd homeworks/module7/terraform_az/modules/container_instance
terraform init -backend=false
terraform test
# Expected:
# run "staging_cpu_and_memory"... pass
# Success! 1 passed, 0 failed.
```

### Exercise 4 — Create `07_deploy.yml` and deploy to staging

The workflow is in `.github/workflows/07_deploy.yml`. Before it runs:

1. Create the `production` environment in GitHub:
   - Settings → Environments → New environment → name it `production`.
   - Add yourself as a required reviewer.
   - Save.

2. Push a change to `homeworks/module7/src/**` to trigger `07_app_build.yml`. Once it passes, `07_deploy.yml` starts automatically.

3. After Job 2 (staging) completes, confirm the staging FQDN returns HTTP 200:
```powershell
$STAGING = terraform output -raw staging_fqdn
Invoke-RestMethod "http://${STAGING}:8000/"
# Expected: {"status": "ok", "version": "1.0.0"}
```

4. Approve Job 3 in the GitHub Actions UI to deploy to production.

---

## Tear down

```powershell
cd homeworks/module7/terraform_az
terraform destroy -auto-approve
# ~3–5 minutes to remove all resources.
```

After destroy, verify the resource group is gone:
```powershell
az group show --name (terraform output -raw resource_group_name) 2>&1
# Expected: "ResourceGroupNotFound" error
```

> **Key Vault soft-delete:** The Key Vault enters soft-deleted state after destroy (7-day retention).
> If you re-apply within 7 days using the same `prefix`, Key Vault creation will fail with a name-conflict error.
> To recover: `az keyvault recover --name (terraform output -raw key_vault_name)`
> Or change the `prefix` value in `terraform.tfvars`.
