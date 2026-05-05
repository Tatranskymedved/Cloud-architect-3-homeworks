# Module 5 — Persistent Layer (Azure)

Product Catalog API with Redis cache-aside, PostgreSQL primary + read replica, and Azure Blob Storage for pre-signed asset URLs.

## Architecture

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

**Cache-aside flow (GET /products/{id}):**
```
Request ──► check Redis ──HIT──► return cached JSON + SAS URLs
                │
               MISS
                │
                ▼
          query PG replica ──► store in Redis (TTL 60 s) ──► return JSON + SAS URLs
```

**Write flow (POST / PUT / DELETE):**
```
Request ──► write PG primary ──► invalidate Redis cache ──► return JSON + SAS URLs
```

> **Cost note:** PostgreSQL GP D2s_v3 ~€0.19/hr per server · Redis Standard C1 ~€0.055/hr · ACI ~€0.04/hr · ACR Basic ~€0.17/day.
> **Destroy when done** (`terraform destroy`) to avoid ongoing charges.

---

## Prerequisites

- Azure CLI ≥ 2.55 — `az --version`
- Terraform ≥ 1.6 — `terraform --version`
- Docker Desktop (to build and push the image) — `docker --version`
- `psql` client — `winget install -e --id PostgreSQL.PostgreSQL.17`

All commands below are written for **PowerShell 5.1** (Windows built-in).

---

## 1. Authenticate to Azure

```powershell
az login
az account set --subscription "<your-subscription-id>"
```

---

## 2. Provision infrastructure + build image in parallel

The first apply creates all infrastructure except ACI (ACI needs the image to be in ACR first).
PostgreSQL + Redis take 25–35 minutes — **use that time to build the Docker image in a second terminal.**

**Terminal 1 — start Terraform:**
```powershell
cd homeworks/module5/terraform_az

# Copy the example vars file
Copy-Item terraform.tfvars.example terraform.tfvars

# Set your laptop's public IP in terraform.tfvars (PostgreSQL firewall rule)
$MY_IP = (Invoke-RestMethod https://ifconfig.me/ip).Trim()
Write-Host "Set this in terraform.tfvars:  my_ip = `"$MY_IP`""
# Edit terraform.tfvars and replace the my_ip placeholder with the printed value

terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

> **Password:** `PostgreSQL@Module5` is pre-set in `terraform.tfvars.example` for dev convenience.

> **Time estimate:** PostgreSQL ~10 min, Redis Standard ~15–20 min, ACR ~1 min. Total: ~25–35 min.

**Terminal 2 — build the image while Terminal 1 is running:**
```powershell
cd homeworks/module5/src
docker build -t catalog-api .
# Takes ~1–2 min. Will be done long before terraform apply finishes.
```

---

## 3. Push image to ACR and deploy ACI

Once `terraform apply` finishes, ACR exists. Push the pre-built image and deploy ACI in one shot.

```powershell
cd homeworks/module5/terraform_az

$ACR_NAME   = terraform output -raw acr_name
$ACR_SERVER = terraform output -raw acr_login_server

# Authenticate Docker to ACR, tag and push
az acr login --name $ACR_NAME
docker tag catalog-api "$ACR_SERVER/catalog-api:latest"
docker push "$ACR_SERVER/catalog-api:latest"

# Set image reference then apply — creates ACI only (~2 min)
Add-Content terraform.tfvars "`ncontainer_image = `"$ACR_SERVER/catalog-api:latest`""
terraform apply -auto-approve
```

Key outputs to note after apply:
```powershell
terraform output
```
- `postgres_primary_fqdn` — write endpoint
- `postgres_replica_fqdn` — read endpoint
- `redis_hostname` — Redis hostname (public access, TLS 6380)
- `storage_account_name` — globally unique storage account name
- `api_url` — public URL of the ACI container

> **Startup time:** ACI containers take ~30–60 seconds to start. The app logs `Schema ready`
> once the PostgreSQL connection and table creation succeed.
> **The `products` table does not exist until the container has started at least once** —
> seed data (step 5) must be inserted only after `Schema ready` appears in the logs.

Stream startup logs:
```powershell
$RG = terraform output -raw resource_group_name
az container logs --resource-group $RG --name catalog-api --follow
```

---

## 4. Verify access model

> All `terraform output` commands must be run from `homeworks/module5/terraform_az/`.
> Running them from any other directory returns an empty string and `Test-NetConnection` will fail with a "null or empty" DNS error.

```powershell
cd homeworks/module5/terraform_az
```

**PostgreSQL is publicly reachable** (IP-restricted to your laptop):
```powershell
Test-NetConnection -ComputerName (terraform output -raw postgres_primary_fqdn) -Port 5432
# Expected: TcpTestSucceeded : True
```

**Redis is publicly reachable** (TLS + password required — no anonymous access):
```powershell
Test-NetConnection -ComputerName (terraform output -raw redis_hostname) -Port 6380
# Expected: TcpTestSucceeded : True
```

**API health check:**
```powershell
$API = terraform output -raw api_url
Invoke-WebRequest "$API/healthz"
# Expected: {"status":"ok"}
```

**Connect to PostgreSQL from VS Code** (SQLTools or PostgreSQL extension):

| Setting | Value |
|---|---|
| Host | `terraform output -raw postgres_primary_fqdn` |
| Port | `5432` |
| Database | `catalog` |
| Username | `pgadmin` |
| Password | `PostgreSQL@Module5` |
| SSL | `require` |

Run a quick smoke-test query after connecting:
```sql
SELECT version();
```

> **If your IP changes** (different network, VPN toggle), update `my_ip` in `terraform.tfvars`
> and run `terraform apply -target=module.postgres` (~10 seconds, firewall rules only).

> Private Endpoints for Redis and Blob are still provisioned — they provide private routing
> for any workload running inside the VNet (e.g. future Container Apps deployment).

---

## 5. Seed initial data

Once the app logs `Schema ready`, insert a sample product row. In **VS Code** (connected to the primary), run:

```sql
INSERT INTO products (name, description, price, stock_level)
VALUES ('Widget Pro', 'A high-quality widget', 29.99, 100);
```

> **Azure Portal alternative:** open the PostgreSQL resource → **Query editor** → log in as `pgadmin` → paste and run the query above.

---

## 6. Upload sample assets

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

> **Note:** `--auth-mode login` uses your `az login` identity. The Terraform deployment already
> granted your identity `Storage Blob Data Contributor` on this account.

---

## 7. Test cache-aside behaviour

Before testing, invalidate any existing cache entry by updating the product (triggers `_invalidate_cache`):

```powershell
$API = terraform output -raw api_url
$body = '{"name":"Widget Pro","description":"A high-quality widget","price":29.99,"stock_level":100}'
Invoke-WebRequest "$API/products/1" -Method PUT -Body $body -ContentType "application/json"
```

> **Azure Portal alternative — flush Redis:** open the Redis resource → **Console** (left menu) → type `FLUSHALL` → press Enter. This clears all cached keys.

Now test the MISS → HIT sequence:

```powershell
# First call — expect X-Cache: MISS
$r1 = Invoke-WebRequest "$API/products/1"
$r1.Headers["X-Cache"]   # prints: MISS

# Second call within 60 seconds — expect X-Cache: HIT
$r2 = Invoke-WebRequest "$API/products/1"
$r2.Headers["X-Cache"]   # prints: HIT
```

Verify the response body contains SAS token URLs:

```powershell
$r1.Content | ConvertFrom-Json | Select-Object image_url, datasheet_url
```

---

## 8. Measure replication lag (Exercise 4)

Open two PowerShell terminals, both in `homeworks/module5/terraform_az/`:

**Terminal 1 — generate write load via the API:**

```powershell
$API = terraform output -raw api_url

1..200 | ForEach-Object {
    $price = [math]::Round((Get-Random -Min 1 -Max 999)/10.0, 2)
    $body  = "{`"name`":`"Load $_`",`"description`":`"lag test`",`"price`":$price,`"stock_level`":10}"
    Invoke-WebRequest "$API/products" -Method POST -Body $body -ContentType "application/json" | Out-Null
    if ($_ % 20 -eq 0) { Write-Host "Inserted $_ / 200" }
}
```

**Terminal 2 — check replication lag in VS Code while Terminal 1 runs:**

Connect VS Code to the **primary** and run this query every ~10 seconds (press F5 to re-run):

```sql
SELECT client_addr, state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

> **Azure Portal alternative:** open the primary PostgreSQL resource → **Query editor** → log in as `pgadmin` → paste the query above and run it repeatedly while Terminal 1 is inserting.

Record the peak `replay_lag` value and include it in your submission.

---

## 9. Simulate primary failover (Exercise 6)

Azure PostgreSQL Flexible Server has two distinct failover mechanisms:

| Setup | Mechanism | CLI command |
|---|---|---|
| HA enabled (ZoneRedundant / SameZone) | Automatic failover to standby | `az postgres flexible-server restart --failover-mode Planned` |
| No HA — read replica only (this setup) | Manual replica promotion | `az postgres flexible-server replica promote --promote-mode standalone` |

This module uses a **read replica without HA** (GP_Standard_D2s_v3). To simulate a failover:

```powershell
cd homeworks/module5/terraform_az

$RG           = terraform output -raw resource_group_name
$REPLICA_NAME = (terraform output -raw postgres_primary_server_name) -replace 'primary','replica'
$API          = terraform output -raw api_url

# Record the start time
Get-Date

# Promote the replica to a standalone server (breaks replication — irreversible)
az postgres flexible-server replica promote `
    --resource-group $RG `
    --name $REPLICA_NAME `
    --promote-mode standalone `
    --promote-option forced

# Poll until the API returns HTTP 200
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

> **Note:** `promote --promote-mode standalone` is a one-way operation — the promoted server becomes independent
> and cannot be re-attached as a replica. After this exercise, `terraform destroy` will clean up both servers.

The FastAPI service uses tenacity retry logic (max 5 retries, exponential backoff, 2 s base) and reconnects automatically without a manual restart.

---

## 10. Terraform module validation (Exercise 7)

```powershell
cd homeworks/module5/terraform_az
terraform validate          # must pass with no errors
terraform plan -out=tfplan  # must show the postgres_with_replica module in use
```

---

## Local development (optional)

To run the app locally against the same Azure resources (useful for debugging):

```powershell
cd homeworks/module5/src

$TF      = "../terraform_az"
$KV_NAME = terraform -chdir=$TF output -raw key_vault_name
$PRIMARY = terraform -chdir=$TF output -raw postgres_primary_fqdn
$REPLICA = terraform -chdir=$TF output -raw postgres_replica_fqdn
$REDIS   = terraform -chdir=$TF output -raw redis_hostname
$SA      = terraform -chdir=$TF output -raw storage_account_name

$REDIS_PASSWORD = az keyvault secret show `
    --vault-name $KV_NAME --name redis-primary-key --query value -o tsv
$STORAGE_KEY = az keyvault secret show `
    --vault-name $KV_NAME --name storage-account-key --query value -o tsv

$envContent = @"
PG_PRIMARY_HOST=$PRIMARY
PG_REPLICA_HOST=$REPLICA
PG_USER=pgadmin
PG_PASSWORD=PostgreSQL@Module5
PG_DB=catalog
PG_SSLMODE=require
PG_PORT=5432
REDIS_HOST=$REDIS
REDIS_PORT=6380
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_TLS=true
AZURE_STORAGE_ACCOUNT=$SA
AZURE_STORAGE_KEY=$STORAGE_KEY
"@
$envContent = $envContent -replace "`r`n", "`n"
[System.IO.File]::WriteAllText((Join-Path $PWD ".env"), $envContent, [System.Text.UTF8Encoding]::new($false))

docker build -t catalog-api .
docker run --rm -p 8000:8000 --env-file .env catalog-api
```

The app will be available at `http://localhost:8000`.

---

## Tear down

```powershell
cd homeworks/module5/terraform_az
terraform destroy
```

This removes all resources in the resource group (~10–15 minutes).

> **Key Vault soft-delete:** The Key Vault uses a 7-day soft-delete retention period. If you need
> to recreate it with the same name within 7 days, purge it first:
> ```powershell
> $KV_LOCATION = terraform output -raw location
> az keyvault purge --name (terraform output -raw key_vault_name) --location $KV_LOCATION
> ```
