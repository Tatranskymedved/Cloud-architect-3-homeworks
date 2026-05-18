# Module 6 — Data Processing (Azure)

Retail Demand Forecast Pipeline: ADLS Gen2 medallion storage (raw → processed → gold),
Azure Data Factory orchestration, Databricks PySpark transformation, and Azure Machine Learning
training + Managed Online Endpoint serving.

## Architecture

```
  UCI Online Retail II  (zip download, ~500 k rows, 2009–2011)
        │
        ▼  python scripts/excel_to_csv.py
  retail_2009.csv  retail_2010.csv
        │
        │  az storage blob upload-batch
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Azure Data Lake Storage Gen2  (StorageV2, HNS, LRS)               │
│                                                                     │
│  ┌──────────────┐  ADF CopyData   ┌────────────────┐               │
│  │  raw/        │ ──────────────► │  processed/    │               │
│  │  retail_     │                 │  retail_       │               │
│  │  2009.csv    │                 │  2009.csv      │               │
│  │  retail_     │                 │  retail_       │               │
│  │  2010.csv    │                 │  2010.csv      │               │
│  └──────────────┘                 └───────┬────────┘               │
│                                           │ Databricks reads        │
│                                           ▼                         │
│                                   ┌────────────────┐               │
│                                   │  gold/         │               │
│                                   │  part-*.parquet│               │
│                                   │  (StockCode,   │               │
│                                   │   date,        │               │
│                                   │   qty_sold)    │               │
│                                   └───────┬────────┘               │
└───────────────────────────────────────────┼─────────────────────────┘
                                            │
        ┌───────────────────────────────────┼──────────────────────────┐
        │  Azure Data Factory               │                          │
        │  Pipeline: retail_forecast        │                          │
        │  ┌─────────────┐  ┌──────────────▼──────────────────────┐  │
        │  │  CopyData   │  │  Databricks Notebook Activity        │  │
        │  │  raw →      │──►  notebooks/transform.py              │  │
        │  │  processed  │  │  parameter: run_date (optional)      │  │
        │  └─────────────┘  └────────────────────────────────────┘  │
        │  Parameter: run_date (YYYY-MM-DD, optional)                 │
        └────────────────────────────────────────────────────────────┘

        ┌─────────────────────────────────────────────────────────────┐
        │  Azure Databricks  (Standard, westeurope)                   │
        │  notebooks/transform.py  (PySpark)                         │
        │  • parse InvoiceDate → date                                 │
        │  • drop InvoiceNo starts with "C"  (cancelled)             │
        │  • drop Quantity ≤ 0 or CustomerID null                     │
        │  • groupBy(StockCode, date).sum(Quantity) → quantity_sold   │
        │  • write.parquet(gold/, mode="overwrite")                   │
        └─────────────────────────────────────────────────────────────┘

        ┌─────────────────────────────────────────────────────────────┐
        │  Azure Machine Learning  (Basic, westeurope)                │
        │  notebooks/train.py  (scikit-learn + MLflow)               │
        │  • read Parquet from gold/                                  │
        │  • 7-day lag features per StockCode                         │
        │  • 80/20 train/test split by date                           │
        │  • RandomForestRegressor → mlflow.log_metric("rmse", ...)  │
        │  • mlflow.sklearn.log_model → AML Model Registry           │
        │                                                             │
        │  Managed Online Endpoint  (Standard_DS2_v2)                │
        │  az ml online-endpoint invoke → {"forecast": 142.7}        │
        └─────────────────────────────────────────────────────────────┘

        ┌────────────────────────┐
        │  Azure Key Vault       │
        │  adls-storage-key      │
        │  databricks-pat-token  │
        │  (ADF reads via MI)    │
        └────────────────────────┘
```

> **Cost note:** Databricks Standard DBU ~€0.15/hr · AML compute cluster (0 min nodes, idle = €0) ·
> AML Managed Online Endpoint DS2_v2 ~€0.12/hr · ADF pay-per-use.
> **Destroy all resources when done** to avoid ongoing charges.

---

## Prerequisites

- Azure CLI ≥ 2.55 — `az --version`
- Terraform ≥ 1.6 — `terraform --version`
- Python 3.8+ — `python --version`
- `az ml` CLI extension — `az extension add -n ml`
- `databricks-cli` — `pip install databricks-cli`

All commands are written for **PowerShell 5.1** (Windows built-in).

---

## 1. Authenticate to Azure

```powershell
az login
az account set --subscription "<your-subscription-id>"
az account show --query "{name:name, id:id}" -o table
```

---

## 2. Provision infrastructure

Databricks workspace + AML workspace take 10–15 minutes total.
**While Terraform runs, install the Python dependencies in a second terminal.**

**Terminal 1 — start Terraform:**

```powershell
cd homeworks/module6/terraform_az

Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if you want a different location, prefix, or resource group name.

terraform init
terraform validate
terraform plan -out=tfplan
# Expected: ~15–18 resources.
# Verify: azurerm_storage_account has is_hns_enabled = true
#         azurerm_databricks_workspace.dbw shows sku = "standard"
#         azurerm_machine_learning_workspace.aml references the shared Key Vault

terraform apply tfplan
# Databricks workspace: 5–10 min (normal — do not interrupt)
# AML workspace: 3–5 min
```

> **Note:** The Databricks resource reports `Still creating...` for several minutes. This is normal —
> the Azure Databricks control plane is performing background setup.

**Terminal 2 — install Python deps while Terminal 1 runs:**

```powershell
cd homeworks/module6
pip install -r scripts/requirements.txt
```

---

## 3. Capture Terraform outputs

> All `terraform output` commands must be run from `homeworks/module6/terraform_az/`.

```powershell
cd homeworks/module6/terraform_az

$RG      = terraform output -raw resource_group_name
$SA      = terraform output -raw storage_account_name
$SA_KEY  = terraform output -raw storage_account_key
$ADF     = terraform output -raw adf_name
$DBW_URL = terraform output -raw databricks_workspace_url
$AML     = terraform output -raw aml_workspace_name
$KV      = terraform output -raw key_vault_name

Write-Host "Resource group : $RG"
Write-Host "Storage account: $SA"
Write-Host "ADF name       : $ADF"
Write-Host "Databricks URL : $DBW_URL"
Write-Host "AML workspace  : $AML"
Write-Host "Key Vault      : $KV"
```

---

## 4. Create a Databricks PAT token, cluster, and import the notebook

Terraform cannot create Databricks PAT tokens. Create one manually:

```powershell
# Open the Databricks workspace in a browser
Start-Process $DBW_URL

# In the Databricks UI:
#   1. Click your username (top-right) → Settings → Developer → Access tokens
#   2. Click "Generate new token"
#   3. Set comment = "ADF integration" and lifetime = 90 days
#   4. Copy the token value (shown only once)

# Store the token in Key Vault
$PAT = Read-Host "Paste Databricks PAT token" -AsSecureString
$PAT_PLAIN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PAT)
)

az keyvault secret set `
    --vault-name $KV `
    --name "databricks-pat-token" `
    --value $PAT_PLAIN

Write-Host "PAT token stored in Key Vault."
```

Configure the Databricks CLI and create a cluster:

```powershell
# Configure Databricks CLI (runs interactively — enter Host and Token when prompted)
databricks configure --token
# Host:  <paste $DBW_URL value, e.g. https://adb-123456789.12.azuredatabricks.net>
# Token: <paste the PAT token from above>

# Create a single-node cluster with ADLS access configured in Spark config.
# The key fs.azure.account.key.<account>.dfs.core.windows.net lets the notebook
# read from abfss:// without per-read authentication.
$cluster_config = @"
{
  "cluster_name": "retail-transform",
  "spark_version": "14.3.x-scala2.12",
  "node_type_id": "Standard_DS2_v2",
  "num_workers": 0,
  "spark_conf": {
    "spark.master": "local[*, 4]",
    "spark.databricks.cluster.profile": "singleNode",
    "fs.azure.account.key.$($SA).dfs.core.windows.net": "$SA_KEY",
    "fs.azure.account.name": "$SA"
  },
  "custom_tags": {"ResourceClass": "SingleNode"},
  "autotermination_minutes": 30
}
"@

$cluster_config | Out-File -Encoding utf8 cluster.json
$CLUSTER_ID = (databricks clusters create --json-file cluster.json | ConvertFrom-Json).cluster_id
Write-Host "Cluster ID: $CLUSTER_ID"
```

Import the transformation notebook into Databricks:

```powershell
# Import notebooks/transform.py into the /notebooks/ path in the workspace
databricks workspace import `
    --language PYTHON `
    --format SOURCE `
    --overwrite `
    homeworks/module6/notebooks/transform.py `
    /notebooks/transform
```

---

## 5. Upload the dataset to ADLS

```powershell
# Download the UCI Online Retail II zip (~40 MB)
Invoke-WebRequest `
    -Uri "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip" `
    -OutFile "online_retail_II.zip"

Expand-Archive -Path "online_retail_II.zip" -DestinationPath ".\uci_data" -Force

# Convert Excel to CSV (reads two sheets → retail_2009.csv + retail_2010.csv)
cd homeworks/module6
python scripts/excel_to_csv.py `
    --input "uci_data\Online Retail II.xlsx" `
    --output-dir .\uci_data

Get-ChildItem .\uci_data\retail_*.csv   # verify both files exist

# Upload both CSVs to the ADLS raw container
az storage blob upload-batch `
    --account-name $SA `
    --account-key $SA_KEY `
    --destination raw `
    --source .\uci_data `
    --pattern "retail_*.csv" `
    --overwrite

# Verify upload
az storage blob list `
    --account-name $SA `
    --account-key $SA_KEY `
    --container-name raw `
    --output table
```

---

## 6. Create ADF linked services and pipeline

ADF linked services must be created in the ADF Studio portal (they reference Key Vault secrets
and cannot be created via the Azure CLI without complex JSON authoring).

```powershell
# Open ADF Studio
Start-Process "https://adf.azure.com/en/home"
# Click "Open Azure Data Factory Studio" → select your subscription → select $ADF
```

In ADF Studio, create **two Linked Services** (Manage → Linked services → New):

**Linked Service 1 — ADLS Gen2:**
| Field | Value |
|---|---|
| Name | `LS_ADLS_Retail` |
| Type | Azure Data Lake Storage Gen2 |
| Auth method | Account key |
| Account name | `<value of $SA>` |
| Account key | From Key Vault: `adls-storage-key` (select your Key Vault `<value of $KV>`) |

**Linked Service 2 — Azure Databricks:**
| Field | Value |
|---|---|
| Name | `LS_Databricks_Retail` |
| Workspace | Select from subscription → `<value of $DBW_URL region>` |
| Cluster | Existing cluster → `retail-transform` (use cluster ID from step 4) |
| Auth | Access token from Key Vault: `databricks-pat-token` |

Create a **Pipeline** named `retail_forecast` (Author → Pipelines → New pipeline):

1. Add a **String parameter** named `run_date` with default value `""`.
2. Add a **Copy Data** activity:
   - Source: `LS_ADLS_Retail`, container `raw`, wildcard `retail_*.csv`
   - Destination: `LS_ADLS_Retail`, container `processed`
3. Add a **Databricks Notebook** activity (runs after Copy Data succeeds):
   - Notebook path: `/notebooks/transform`
   - Base parameters:
     ```json
     {
       "storage_account": "<value of $SA>",
       "run_date": "@pipeline().parameters.run_date"
     }
     ```

---

## 7. Trigger the ADF pipeline and verify gold-zone output

```powershell
# Trigger the pipeline (full historical load — no run_date filter)
$RUN_RESULT = az datafactory pipeline create-run `
    --resource-group $RG `
    --factory-name $ADF `
    --name "retail_forecast" `
    --parameters "{}" | ConvertFrom-Json

$RUN_ID = $RUN_RESULT.runId
Write-Host "Pipeline run ID: $RUN_ID"

# Poll for completion (repeat every 30 seconds until status = Succeeded)
az datafactory pipeline-run show `
    --resource-group $RG `
    --factory-name $ADF `
    --run-id $RUN_ID `
    --query "{status:status, message:message}" `
    --output table
```

> Pipeline total time: ~5–15 minutes depending on Databricks cluster warm-up (~2–5 min cold start).

Verify the gold-zone Parquet was written:

```powershell
az storage blob list `
    --account-name $SA `
    --account-key $SA_KEY `
    --container-name gold `
    --output table
# Expected: one or more part-*.parquet files
```

Validate data quality in a Databricks notebook cell:

```python
# Run this in a new Databricks notebook cell after the pipeline completes
from pyspark.sql import functions as F

storage_account = spark.conf.get("fs.azure.account.name")
gold_path = f"abfss://gold@{storage_account}.dfs.core.windows.net/"
raw_path  = f"abfss://processed@{storage_account}.dfs.core.windows.net/"

df_gold = spark.read.parquet(gold_path)
df_raw  = spark.read.option("header", "true").csv(raw_path)

gold_count = df_gold.count()
raw_count  = df_raw.count()
print(f"Raw row count : {raw_count:,}")
print(f"Gold row count: {gold_count:,}")
assert gold_count < raw_count, "Gold count should be less than raw (cancelled rows removed)"

null_count = df_gold.filter(
    F.col("StockCode").isNull() | F.col("date").isNull() | F.col("quantity_sold").isNull()
).count()
assert null_count == 0, f"Found {null_count} rows with nulls in key columns"
print("All assertions passed.")
```

---

## 8. Submit the AML training job

```powershell
# Set defaults so --workspace-name and --resource-group are not needed on every command
az configure --defaults group=$RG workspace=$AML

# Create the Conda environment definition
$env_yaml = @"
name: retail-forecast-env
channels:
  - conda-forge
dependencies:
  - python=3.10
  - pip:
    - scikit-learn>=1.3.0
    - pandas
    - pyarrow
    - adlfs
    - azure-identity
    - mlflow
    - azureml-mlflow
"@
$env_yaml | Out-File -Encoding utf8 conda_env.yml
az ml environment create `
    --name retail-forecast-env `
    --conda-file conda_env.yml `
    --image mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu20.04

# Create the training job definition
# The compute target "cpu-cluster" was provisioned by terraform apply.
$job_yaml = @"
`$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
type: command
display_name: retail-demand-forecast-training
experiment_name: retail-demand-forecast
command: >-
  python train.py
  --storage-account $SA
  --n-estimators 100
  --n-lags 7
code: ../notebooks
environment: azureml:retail-forecast-env@latest
compute: azureml:cpu-cluster
"@
$job_yaml | Out-File -Encoding utf8 train_job.yml

# Submit (--stream tails the log; press Ctrl+C to detach — job continues in background)
az ml job create --file train_job.yml --stream
```

> **Compute warm-up:** First job after idle pays a ~3–5 min cluster warm-up penalty.
> Total job time: ~10–15 minutes.

Confirm the RMSE metric appears in AML Studio:
```powershell
az ml job list `
    --query "[?experiment_name=='retail-demand-forecast'].{name:name, status:status}" `
    --output table

# Verify model is registered
az ml model list --output table
# Expected: retail-demand-forecast  version 1
```

---

## 9. Deploy the Managed Online Endpoint

```powershell
# Create the endpoint (provisions compute — takes 8–12 minutes)
az ml online-endpoint create `
    --name retail-forecast-endpoint `
    --auth-mode key

# Poll until provisioning_state = Succeeded
az ml online-endpoint show `
    --name retail-forecast-endpoint `
    --query "{name:name, provisioning_state:provisioning_state}" `
    --output table

# Create deployment YAML (score.py is the scoring script in ./notebooks/)
$MODEL_VERSION = "1"
$deploy_yaml = @"
`$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: blue
endpoint_name: retail-forecast-endpoint
model: azureml:retail-demand-forecast:$MODEL_VERSION
instance_type: Standard_DS2_v2
instance_count: 1
code_configuration:
  code: ./notebooks
  scoring_script: score.py
environment_variables:
  ADLS_ACCOUNT_NAME: $SA
"@
$deploy_yaml | Out-File -Encoding utf8 deployment.yml

az ml online-deployment create --file deployment.yml --all-traffic

# Wait for deployment to reach Succeeded (~8–12 minutes)
az ml online-deployment show `
    --endpoint-name retail-forecast-endpoint `
    --name blue `
    --query "{name:name, provisioning_state:provisioning_state}" `
    --output table
```

Invoke the endpoint:

```powershell
'{"stock_code": "85123A", "week_offset": 1}' | Out-File -Encoding utf8 request.json

az ml online-endpoint invoke `
    --name retail-forecast-endpoint `
    --request-file request.json
# Expected: {"forecast": <numeric value>}
```

---

## 10. Exercise: parameterised ADF run (Task 7)

Trigger the pipeline with a specific `run_date` to exercise incremental filtering:

```powershell
az datafactory pipeline create-run `
    --resource-group $RG `
    --factory-name $ADF `
    --name "retail_forecast" `
    --parameters '{"run_date": "2010-12-01"}'
```

After the run completes, verify the gold zone contains only rows for that date:

```python
# Run in a Databricks notebook cell
from pyspark.sql import functions as F

storage_account = spark.conf.get("fs.azure.account.name")
gold_path = f"abfss://gold@{storage_account}.dfs.core.windows.net/"

df = spark.read.parquet(gold_path)
dates = [row.date.strftime("%Y-%m-%d") for row in df.select("date").distinct().collect()]
assert dates == ["2010-12-01"], f"Expected only 2010-12-01, got: {dates}"
print("Date filter assertion passed.")
```

---

## Terraform module validation (Task 1)

```powershell
cd homeworks/module6/terraform_az
terraform validate         # must pass with no errors
terraform plan -out=tfplan # verify expected resource count (~15–18 resources)
```

---

## Tear down

> **Important:** The AML Managed Online Endpoint must be deleted **before** `terraform destroy`.
> Azure refuses to delete the AML workspace while active deployments exist.

```powershell
# 1. Delete the deployment and endpoint
az ml online-deployment delete `
    --endpoint-name retail-forecast-endpoint `
    --name blue `
    --resource-group $RG `
    --workspace-name $AML `
    --yes

az ml online-endpoint delete `
    --name retail-forecast-endpoint `
    --resource-group $RG `
    --workspace-name $AML `
    --yes

# 2. Destroy all Terraform-managed resources (~10–15 minutes)
cd homeworks/module6/terraform_az
terraform destroy
```

> **Key Vault soft-delete:** If you need to recreate the Key Vault with the same name within
> 7 days, purge it first:
> ```powershell
> az keyvault purge --name $KV --location (terraform output -raw location)
> ```
