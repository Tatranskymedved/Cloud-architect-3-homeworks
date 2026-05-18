# Azure Implementation — Module 6: Data processing (Retail Demand Forecast Pipeline)

---

## Azure service mapping

| Homework component | Azure service | SKU / tier | Rationale |
|---|---|---|---|
| Data lake storage | Azure Data Lake Storage Gen2 | StorageV2, LRS, HNS enabled | HNS (hierarchical namespace) is required for ADLS Gen2 directory semantics and for Databricks to mount the filesystem using the ABFS driver. LRS is sufficient for coursework — data is recreatable from the source CSV. |
| ETL orchestration | Azure Data Factory | No SKU — pay-per-use | ADF is the standard Azure ETL orchestrator. The Copy Activity handles raw→processed movement at near-zero cost for ~1 GB of CSV. The Databricks Notebook Activity triggers the Spark job and waits for its completion before the pipeline run is marked succeeded. |
| Distributed processing | Azure Databricks | Premium tier, `Standard_DS2_v2` single-node cluster | Standard SKU was deprecated by Azure; Premium is now the minimum available tier. A single-node cluster (driver-only, no workers) is sufficient for ~500,000 rows and avoids multi-node costs. Autotermination after 30 minutes of inactivity prevents runaway charges. |
| ML training + registry | Azure Machine Learning | Basic workspace | Basic workspace includes MLflow experiment tracking, model registry, managed compute, and CLI-driven pipelines. Enterprise governance features (network isolation, customer-managed keys) are not needed for coursework. |
| Model serving | AML Managed Online Endpoint | `Standard_DS2_v2` instance type | Managed Online Endpoint handles container build, health probes, and traffic routing automatically. DS2_v2 (2 vCPU, 7 GB) is the minimum that avoids OOM during scikit-learn inference on the lag-feature matrix. |
| Secrets | Azure Key Vault | Standard tier | Stores the ADLS storage account key and the Databricks PAT token. ADF linked services reference Key Vault secrets by URI so no credentials appear in pipeline JSON. |

---

## Architecture diagram (text)

```
  UCI Online Retail II
  (zip download)
        │
        ▼
  scripts/excel_to_csv.py
  retail_2009.csv  retail_2010.csv
        │
        │  az storage blob upload-batch
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Azure Data Lake Storage Gen2  (StorageV2, HNS, LRS)           │
│                                                                 │
│  ┌──────────────┐   ADF CopyData   ┌────────────────┐          │
│  │  raw/        │ ──────────────►  │  processed/    │          │
│  │  retail_     │                  │  retail_       │          │
│  │  2009.csv    │                  │  2009.csv      │          │
│  │  retail_     │                  │  retail_       │          │
│  │  2010.csv    │                  │  2010.csv      │          │
│  └──────────────┘                  └───────┬────────┘          │
│                                            │                   │
│                                    Databricks reads            │
│                                            │                   │
│                                            ▼                   │
│                                    ┌────────────────┐          │
│                                    │  gold/         │          │
│                                    │  part-*.parquet│          │
│                                    │  (StockCode,   │          │
│                                    │   date,        │          │
│                                    │   qty_sold)    │          │
│                                    └───────┬────────┘          │
└────────────────────────────────────────────┼────────────────────┘
                                             │
        ┌────────────────────────────────────┼─────────────────────────┐
        │  Azure Data Factory                │                         │
        │                                   │                         │
        │  Pipeline: retail_forecast         │                         │
        │  ┌──────────────┐  ┌─────────────▼──────────────────────┐  │
        │  │  CopyData    │  │  Databricks Notebook Activity       │  │
        │  │  raw →       │  │  notebooks/transform.py             │  │
        │  │  processed   │──►  parameters: run_date (optional)    │  │
        │  └──────────────┘  └────────────────────────────────────┘  │
        │  Parameter: run_date (YYYY-MM-DD string, optional)          │
        └─────────────────────────────────────────────────────────────┘
                                             │
                                    Databricks writes
                                    Parquet to gold/
                                             │
                                             ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  Azure Databricks  (Standard tier, westeurope)              │
        │                                                             │
        │  notebooks/transform.py  (PySpark)                         │
        │  • parse InvoiceDate → date                                 │
        │  • drop InvoiceNo.startswith("C")                           │
        │  • drop Quantity <= 0 or CustomerID is null                 │
        │  • groupBy(StockCode, date).sum(Quantity) → quantity_sold   │
        │  • write.parquet(gold_path, mode="overwrite")               │
        └─────────────────────────────────────────────────────────────┘

        ┌─────────────────────────────────────────────────────────────┐
        │  Azure Machine Learning  (Basic workspace, westeurope)      │
        │                                                             │
        │  notebooks/train.py  (scikit-learn + MLflow)               │
        │  • read Parquet from gold/                                  │
        │  • build 7-day lag features per StockCode                   │
        │  • 80/20 train/test split by date                           │
        │  • RandomForestRegressor.fit()                              │
        │  • mlflow.log_metric("rmse", ...)                           │
        │  • mlflow.sklearn.log_model(...)                            │
        │                                                             │
        │  AML Model Registry  ──► Managed Online Endpoint           │
        │                          Standard_DS2_v2                    │
        │                          az ml online-endpoint invoke       │
        │                          {"stock_code": "85123A",           │
        │                           "week_offset": 1}                 │
        │                          → {"forecast": 142.7}             │
        └─────────────────────────────────────────────────────────────┘

        ┌────────────────────────┐
        │  Azure Key Vault       │
        │  Standard tier         │
        │  adls-storage-key      │
        │  databricks-pat-token  │
        │  (referenced by ADF    │
        │   linked services)     │
        └────────────────────────┘
```

---

## Terraform file structure

```
homeworks/module6/
├── terraform_az/
│   ├── versions.tf                  # required_providers, terraform version constraint
│   ├── variables.tf                 # input variables: location, prefix, etc.
│   ├── main.tf                      # all resource definitions
│   ├── outputs.tf                   # storage account name, ADF name, Databricks URL, AML name
│   ├── terraform.tfvars.example     # non-secret example values (committed)
│   └── terraform.tfvars             # actual values (gitignored)
├── scripts/
│   └── excel_to_csv.py              # converts UCI xlsx sheets to two CSV files
└── notebooks/
    ├── transform.py                 # Databricks PySpark notebook (source format)
    └── train.py                     # AML training script (scikit-learn + MLflow)
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
      # Do not purge Key Vault on destroy — avoids accidental soft-delete lock in the lab
      purge_soft_delete_on_destroy = false
    }
    machine_learning {
      # AML workspace creates companion resources; allow destroy even if deployments exist
      purge_soft_deleted_workspace_on_destroy = true
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
  default     = "retail"
  description = "Short prefix used in resource names (lowercase, no spaces, ≤ 8 chars)."
}

variable "resource_group_name" {
  type    = string
  default = "rg-module6-data"
}

variable "storage_suffix" {
  type        = string
  default     = ""
  description = "Optional extra suffix for the storage account name to ensure global uniqueness. Leave empty to use a random suffix."
}
```

---

### `main.tf`

```hcl
# ── Random suffix for globally-unique resource names ──────────────────────────
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  # Use var.storage_suffix if provided; otherwise fall back to random suffix.
  # Storage account names: 3–24 chars, lowercase alphanumeric only.
  name_suffix   = var.storage_suffix != "" ? var.storage_suffix : random_string.suffix.result
  storage_name  = "${var.prefix}lake${local.name_suffix}"
  kv_name       = "${var.prefix}-kv-${local.name_suffix}"
  adf_name      = "${var.prefix}-adf-${local.name_suffix}"
  dbw_name      = "${var.prefix}-dbw-${local.name_suffix}"
  aml_name      = "${var.prefix}-aml-${local.name_suffix}"
  acr_name      = "${var.prefix}acr${local.name_suffix}"   # ACR: 5–50 chars, alphanumeric only
  appins_name   = "${var.prefix}-appins-${local.name_suffix}"
}

# ── Resource Group ─────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ── Azure Data Lake Storage Gen2 ──────────────────────────────────────────────
# StorageV2 + hierarchical namespace (HNS) enables ADLS Gen2 semantics.
# Databricks mounts ADLS using the ABFS driver (abfss://); HNS is mandatory.
resource "azurerm_storage_account" "lake" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # HNS must be enabled at creation time — it cannot be enabled after the fact.
  is_hns_enabled = true

  # Require HTTPS for all requests
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # Allow Blob public access is disabled — all data requires auth or SAS
  allow_nested_items_to_be_public = false
}

# Three zone containers: raw (CSV landing), processed (ADF copy destination), gold (Parquet output)
resource "azurerm_storage_data_lake_gen2_filesystem" "raw" {
  name               = "raw"
  storage_account_id = azurerm_storage_account.lake.id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "processed" {
  name               = "processed"
  storage_account_id = azurerm_storage_account.lake.id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "gold" {
  name               = "gold"
  storage_account_id = azurerm_storage_account.lake.id
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
  purge_protection_enabled   = false

  # Azure RBAC authorization (preferred over legacy access policies)
  enable_rbac_authorization = true
}

# Grant the Terraform deployer rights to write secrets
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Store the ADLS storage account key in Key Vault
# ADF linked service for ADLS will reference this secret by URI.
resource "azurerm_key_vault_secret" "adls_key" {
  name         = "adls-storage-key"
  value        = azurerm_storage_account.lake.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]
}

# Placeholder for the Databricks PAT token.
# The actual token must be generated in the Databricks UI after workspace provisioning
# (Terraform cannot create PAT tokens for the initial workspace via azurerm alone).
# Students update this secret manually after step 4 of the deployment walkthrough.
resource "azurerm_key_vault_secret" "databricks_pat" {
  name         = "databricks-pat-token"
  value        = "REPLACE_ME_AFTER_DATABRICKS_PROVISIONING"
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_role_assignment.deployer_kv_officer]

  lifecycle {
    # Prevent Terraform from overwriting the real token once the student has set it
    ignore_changes = [value]
  }
}

# ── Azure Data Factory ────────────────────────────────────────────────────────
resource "azurerm_data_factory" "adf" {
  name                = local.adf_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # System-assigned Managed Identity so ADF can read Key Vault secrets
  # without a static credential in the linked service definition.
  identity {
    type = "SystemAssigned"
  }
}

# Grant ADF Managed Identity read access to Key Vault secrets
resource "azurerm_role_assignment" "adf_kv_reader" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# Grant ADF Managed Identity access to read/write the ADLS account
resource "azurerm_role_assignment" "adf_storage_contributor" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# ── Azure Databricks Workspace ────────────────────────────────────────────────
# Standard tier does not require Unity Catalog; suitable for notebook-based labs.
resource "azurerm_databricks_workspace" "dbw" {
  name                = local.dbw_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "standard"

  # Managed resource group created automatically by Databricks
  managed_resource_group_name = "${var.resource_group_name}-dbw-managed"

  tags = {
    module = "module6"
  }
}

# ── Azure Machine Learning Workspace ─────────────────────────────────────────
# AML workspace requires three companion resources:
# Application Insights, Container Registry, and Key Vault.
# AML can create its own Key Vault; here we pass the one Terraform already created
# so students see one Key Vault in the resource group, not two.

resource "azurerm_application_insights" "appins" {
  name                = local.appins_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
}

resource "azurerm_container_registry" "acr" {
  name                = local.acr_name   # globally unique, alphanumeric
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false   # AML accesses ACR via Managed Identity
}

resource "azurerm_machine_learning_workspace" "aml" {
  name                    = local.aml_name
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  application_insights_id = azurerm_application_insights.appins.id
  container_registry_id   = azurerm_container_registry.acr.id
  key_vault_id            = azurerm_key_vault.kv.id
  storage_account_id      = azurerm_storage_account.lake.id

  # System-assigned Managed Identity for the AML workspace
  identity {
    type = "SystemAssigned"
  }

  # Basic SKU: experiment tracking, model registry, managed endpoints — no enterprise governance
  sku_name = "Basic"
}

# Grant AML Managed Identity access to the ADLS storage account
# so training scripts can read Parquet from the gold container.
resource "azurerm_role_assignment" "aml_storage_reader" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_workspace.aml.identity[0].principal_id
}

# Grant AML Managed Identity push/pull access to ACR
# so it can build and cache environment containers for training jobs.
resource "azurerm_role_assignment" "aml_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_machine_learning_workspace.aml.identity[0].principal_id
}

# ── AML Compute Cluster ───────────────────────────────────────────────────────
# Provisions the compute target used by the training job.
# Scales to 0 when idle — no charges when not running a job.
resource "azurerm_machine_learning_compute_cluster" "cpu_cluster" {
  name                          = "cpu-cluster"
  location                      = azurerm_resource_group.rg.location
  vm_priority                   = "Dedicated"
  vm_size                       = "Standard_DS2_v2"
  machine_learning_workspace_id = azurerm_machine_learning_workspace.aml.id

  scale_settings {
    min_node_count                       = 0
    max_node_count                       = 2
    scale_down_nodes_after_idle_duration = "PT30M"   # scale to 0 after 30 minutes idle
  }

  identity {
    type = "SystemAssigned"
  }
}

# Grant the compute cluster's Managed Identity access to ADLS.
# Training jobs run as the CLUSTER's identity, not the workspace's identity.
# Without this assignment, DefaultAzureCredential() in train.py receives HTTP 403
# when reading Parquet from the gold container.
resource "azurerm_role_assignment" "cpu_cluster_storage_reader" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_compute_cluster.cpu_cluster.identity[0].principal_id
}
```

---

### `outputs.tf`

```hcl
output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the module6 resource group."
}

output "storage_account_name" {
  value       = azurerm_storage_account.lake.name
  description = "ADLS Gen2 storage account name. Use this in az storage blob upload-batch commands."
}

output "storage_account_key" {
  value       = azurerm_storage_account.lake.primary_access_key
  sensitive   = true
  description = "Primary access key for the ADLS account. Stored in Key Vault as adls-storage-key."
}

output "adf_name" {
  value       = azurerm_data_factory.adf.name
  description = "Azure Data Factory name. Use this in az datafactory pipeline create-run commands."
}

output "databricks_workspace_url" {
  value       = "https://${azurerm_databricks_workspace.dbw.workspace_url}"
  description = "URL of the Databricks workspace. Open in a browser to access notebooks."
}

output "databricks_workspace_id" {
  value       = azurerm_databricks_workspace.dbw.workspace_id
  description = "Numeric Databricks workspace ID."
}

output "aml_workspace_name" {
  value       = azurerm_machine_learning_workspace.aml.name
  description = "AML workspace name. Use with --workspace-name in az ml commands."
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Key Vault name. Students update the databricks-pat-token secret here after workspace provisioning."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Key Vault URI. Used in ADF linked service configuration."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server. Used by AML to store training environment images."
}
```

---

### `terraform.tfvars.example`

```hcl
# Copy this file to terraform.tfvars and fill in your values.
# terraform.tfvars is gitignored — never commit it.

location            = "westeurope"
prefix              = "retail"
resource_group_name = "rg-module6-data"
# storage_suffix    = ""   # leave empty to use a random 6-character suffix
```

---

## Helper scripts

### `scripts/excel_to_csv.py`

```python
"""
Convert UCI Online Retail II Excel sheets to CSV files.

Usage:
    python scripts/excel_to_csv.py --input "Online Retail II.xlsx" --output-dir .

Requirements:
    pip install openpyxl pandas
"""

import argparse
import pathlib
import pandas as pd


def main():
    parser = argparse.ArgumentParser(description="Convert Online Retail II xlsx to CSV.")
    parser.add_argument("--input",  required=True, help="Path to the .xlsx file.")
    parser.add_argument("--output-dir", default=".", help="Directory for output CSV files.")
    args = parser.parse_args()

    out = pathlib.Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    sheet_map = {
        "Year 2009-2010": "retail_2009.csv",
        "Year 2010-2011": "retail_2010.csv",
    }

    for sheet_name, csv_name in sheet_map.items():
        print(f"Reading sheet '{sheet_name}' ...")
        df = pd.read_excel(args.input, sheet_name=sheet_name, dtype=str)
        out_path = out / csv_name
        df.to_csv(out_path, index=False)
        print(f"  Written {len(df):,} rows to {out_path}")

    print("Done.")


if __name__ == "__main__":
    main()
```

---

### `notebooks/transform.py` (Databricks PySpark notebook source)

```python
# Databricks notebook source
# This file is imported into Databricks via the UI or Databricks CLI.
# It is also used by the ADF Databricks Notebook Activity.

# COMMAND ----------
# Parameters widget — ADF passes run_date when calling this notebook.
# Default is empty string (full historical load).
dbutils.widgets.text("run_date", "", "Run Date (YYYY-MM-DD, optional)")
run_date = dbutils.widgets.get("run_date").strip()

# COMMAND ----------
import os
from pyspark.sql import functions as F
from pyspark.sql.types import DateType

# Storage account configuration — read from Spark config or environment variable.
# In production, configure the cluster with the ADLS account key via:
#   spark.conf.set(f"fs.azure.account.key.{storage_account}.dfs.core.windows.net", key)
storage_account = spark.conf.get("fs.azure.account.name", "")
if not storage_account:
    # Fallback: read from environment variable set in cluster config
    storage_account = os.environ.get("ADLS_ACCOUNT_NAME", "")

assert storage_account, "ADLS_ACCOUNT_NAME must be set in cluster Spark config or environment."

processed_path = f"abfss://processed@{storage_account}.dfs.core.windows.net/"
gold_path      = f"abfss://gold@{storage_account}.dfs.core.windows.net/"

# COMMAND ----------
# Read both processed CSV files
df = (
    spark.read
    .option("header", "true")
    .option("inferSchema", "false")
    .csv(processed_path)
)

print(f"Raw row count: {df.count():,}")

# COMMAND ----------
# Parse InvoiceDate to date (handles both "2010-12-01 08:26:00" and "2010-12-01" formats)
df = df.withColumn(
    "date",
    F.to_date(F.col("InvoiceDate"), "yyyy-MM-dd HH:mm:ss").cast(DateType())
)
# Some rows have date format without time component
df = df.withColumn(
    "date",
    F.when(F.col("date").isNull(), F.to_date(F.col("InvoiceDate"), "yyyy-MM-dd")).otherwise(F.col("date"))
)

# COMMAND ----------
# If run_date is provided, filter to that specific day only (incremental mode)
if run_date:
    print(f"Incremental mode: filtering to run_date={run_date}")
    df = df.filter(F.col("date") == F.lit(run_date).cast(DateType()))

# COMMAND ----------
# Data quality filters
df_clean = (
    df
    # Drop cancelled orders (InvoiceNo starts with "C")
    .filter(~F.col("InvoiceNo").startswith("C"))
    # Drop rows with null CustomerID
    .filter(F.col("Customer ID").isNotNull())
    # Drop rows with non-positive Quantity
    .filter(F.col("Quantity").cast("int") > 0)
)

print(f"Row count after cleaning: {df_clean.count():,}")

# COMMAND ----------
# Aggregate to daily product-level total quantity sold
df_gold = (
    df_clean
    .withColumn("quantity", F.col("Quantity").cast("int"))
    .groupBy("StockCode", "date")
    .agg(F.sum("quantity").alias("quantity_sold"))
    .filter(F.col("StockCode").isNotNull())
    .orderBy("StockCode", "date")
)

print(f"Gold zone row count: {df_gold.count():,}")

# COMMAND ----------
# Write Parquet to gold zone
df_gold.write.mode("overwrite").parquet(gold_path)
print(f"Written Parquet to {gold_path}")

# COMMAND ----------
# Validation: assert no nulls in key columns
null_check = (
    df_gold
    .filter(
        F.col("StockCode").isNull() |
        F.col("date").isNull() |
        F.col("quantity_sold").isNull()
    )
    .count()
)
assert null_check == 0, f"Null check failed: {null_check} rows with null values in key columns"
print("Null check passed.")
```

---

### `notebooks/train.py` (AML training script)

```python
"""
AML training script: Retail demand forecast with RandomForestRegressor.

Run as an AML Command job:
    az ml job create --file train_job.yml --workspace-name <aml_name> --resource-group <rg>

Requirements (specified in the AML environment):
    scikit-learn>=1.3.0
    pandas
    pyarrow
    adlfs
    azure-identity
    mlflow
    azureml-mlflow
"""

import argparse
import os

import mlflow
import mlflow.sklearn
import numpy as np
import pandas as pd
from azure.identity import DefaultAzureCredential
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_squared_error


def build_lag_features(df: pd.DataFrame, n_lags: int = 7) -> pd.DataFrame:
    """
    For each StockCode, create lag features: quantity_sold shifted by 1..n_lags days.
    Only rows where all lag columns are non-null are kept (i.e., we need n_lags days of history).
    """
    df = df.sort_values(["StockCode", "date"]).copy()
    for lag in range(1, n_lags + 1):
        df[f"lag_{lag}"] = df.groupby("StockCode")["quantity_sold"].shift(lag)

    # Target: quantity_sold at time t (already present as quantity_sold)
    df = df.dropna()
    return df


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage-account", required=True, help="ADLS storage account name.")
    parser.add_argument("--n-estimators",    type=int, default=100, help="Number of RF trees.")
    parser.add_argument("--n-lags",          type=int, default=7,   help="Number of lag features.")
    args = parser.parse_args()

    gold_path = (
        f"abfs://gold@{args.storage_account}.dfs.core.windows.net/"
        "*.parquet"
    )

    # ── Read gold Parquet ────────────────────────────────────────────────────
    # Use pandas + pyarrow via fsspec for ADLS access without Spark.
    # Use DefaultAzureCredential — works with AML Managed Identity,
    # service principal, and interactive az login during local development.
    credential = DefaultAzureCredential()

    storage_options = {
        "account_name": args.storage_account,
        "credential": credential,
    }
    df = pd.read_parquet(
        f"abfs://gold@{args.storage_account}.dfs.core.windows.net/",
        storage_options=storage_options,
    )
    df["date"] = pd.to_datetime(df["date"])
    df["quantity_sold"] = pd.to_numeric(df["quantity_sold"], errors="coerce").fillna(0)

    print(f"Loaded {len(df):,} rows from gold zone.")

    # ── Feature engineering ──────────────────────────────────────────────────
    df_feat = build_lag_features(df, n_lags=args.n_lags)

    feature_cols = [f"lag_{i}" for i in range(1, args.n_lags + 1)]
    X = df_feat[feature_cols].values
    y = df_feat["quantity_sold"].values

    # 80/20 split by row index (rows are sorted by StockCode + date)
    split = int(len(X) * 0.8)
    X_train, X_test = X[:split], X[split:]
    y_train, y_test = y[:split], y[split:]

    # ── Training ─────────────────────────────────────────────────────────────
    mlflow.start_run()

    mlflow.log_param("n_estimators", args.n_estimators)
    mlflow.log_param("n_lags", args.n_lags)
    mlflow.log_param("train_rows", len(X_train))
    mlflow.log_param("test_rows",  len(X_test))

    model = RandomForestRegressor(
        n_estimators=args.n_estimators,
        random_state=42,
        n_jobs=-1,
    )
    model.fit(X_train, y_train)

    y_pred = model.predict(X_test)
    rmse = float(np.sqrt(mean_squared_error(y_test, y_pred)))

    mlflow.log_metric("rmse", rmse)
    print(f"RMSE on test set: {rmse:.4f}")

    # ── Log model ────────────────────────────────────────────────────────────
    mlflow.sklearn.log_model(
        model,
        artifact_path="demand_forecast_model",
        registered_model_name="retail-demand-forecast",
    )

    mlflow.end_run()
    print("Training complete. Model registered as 'retail-demand-forecast'.")


if __name__ == "__main__":
    main()
```

---

### `notebooks/score.py` (AML Managed Online Endpoint scoring script)

The scoring script is required for the Managed Online Endpoint to handle inference requests in the format `{"stock_code": "85123A", "week_offset": 1}`. It loads a pre-computed daily sales lookup table from the gold zone, builds lag features for the requested StockCode, and returns a numeric forecast.

```python
"""
AML Managed Online Endpoint scoring script.

Loaded once at container startup (init function).
Called once per request (run function).

Expected request body:
    {"stock_code": "85123A", "week_offset": 1}

Response body:
    {"forecast": 142.7}
"""

import json
import logging
import os

import mlflow
import numpy as np
import pandas as pd
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)

# Global state — loaded once at startup
MODEL = None
SALES_LOOKUP = None   # dict: stock_code -> list of last 7 daily quantities (most recent last)


def init():
    """Called once when the container starts. Load the model and pre-compute the lookup table."""
    global MODEL, SALES_LOOKUP

    model_dir = os.environ.get("AZUREML_MODEL_DIR", ".")
    MODEL = mlflow.sklearn.load_model(os.path.join(model_dir, "demand_forecast_model"))

    storage_account = os.environ.get("ADLS_ACCOUNT_NAME", "")
    if not storage_account:
        logger.warning("ADLS_ACCOUNT_NAME not set; forecast will use zero-padded lag features.")
        SALES_LOOKUP = {}
        return

    credential = DefaultAzureCredential()
    storage_options = {"account_name": storage_account, "credential": credential}

    try:
        df = pd.read_parquet(
            f"abfs://gold@{storage_account}.dfs.core.windows.net/",
            storage_options=storage_options,
        )
        df["date"] = pd.to_datetime(df["date"])
        df = df.sort_values(["StockCode", "date"])

        # For each StockCode, keep the last 7 daily quantities
        SALES_LOOKUP = (
            df.groupby("StockCode")["quantity_sold"]
            .apply(lambda s: list(s.tail(7)))
            .to_dict()
        )
        logger.info("Loaded sales lookup for %d stock codes.", len(SALES_LOOKUP))
    except Exception as exc:
        logger.error("Failed to load gold zone data: %s", exc)
        SALES_LOOKUP = {}


def run(raw_data):
    """Called once per inference request."""
    data = json.loads(raw_data)
    stock_code = str(data.get("stock_code", ""))
    week_offset = int(data.get("week_offset", 1))

    # Look up recent sales for this stock code (padded with zeros if not found)
    history = SALES_LOOKUP.get(stock_code, [])
    if len(history) < 7:
        history = [0] * (7 - len(history)) + history

    lag_features = np.array(history[-7:], dtype=float).reshape(1, -1)
    forecast = float(MODEL.predict(lag_features)[0])

    return json.dumps({"forecast": round(forecast, 2)})
```

---

## Deployment walkthrough

### 1. Authenticate to Azure

```powershell
# Interactive login (laptop)
az login
az account set --subscription "<your-subscription-id>"

# Verify the correct subscription is active
az account show --query "{name:name, id:id}" -o table
```

### 2. Initialise and apply Terraform

```powershell
cd homeworks/module6/terraform_az

# Copy the example tfvars and edit if needed
Copy-Item terraform.tfvars.example terraform.tfvars

terraform init
terraform validate

terraform plan -out=tfplan
# Expected resource count: ~15–18 resources.
# Verify in the plan:
#   - azurerm_storage_account has is_hns_enabled = true
#   - azurerm_machine_learning_workspace.aml shows key_vault_id pointing to the shared KV
#   - azurerm_data_factory has identity type = SystemAssigned

terraform apply tfplan
# Databricks workspace provisioning: 5–10 minutes (normal — see Known Limitations #1).
# AML workspace provisioning: 3–5 minutes.
# Total apply time: ~10–15 minutes.
```

> **Note:** The Terraform apply output will show the Databricks workspace resource as `Creating` for several minutes before progressing. This is normal — the Azure Databricks control plane is performing background setup. Do not interrupt the apply.

### 3. Capture Terraform outputs

```powershell
# Run all output commands from homeworks/module6/terraform_az/
$RG          = terraform output -raw resource_group_name
$SA          = terraform output -raw storage_account_name
$SA_KEY      = terraform output -raw storage_account_key
$ADF         = terraform output -raw adf_name
$DBW_URL     = terraform output -raw databricks_workspace_url
$AML         = terraform output -raw aml_workspace_name
$KV          = terraform output -raw key_vault_name

Write-Host "Resource group : $RG"
Write-Host "Storage account: $SA"
Write-Host "ADF name       : $ADF"
Write-Host "Databricks URL : $DBW_URL"
Write-Host "AML workspace  : $AML"
Write-Host "Key Vault      : $KV"
```

### 4. Create a Databricks PAT token and store it in Key Vault

Terraform cannot create Databricks PAT tokens via `azurerm` alone. Create one manually:

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

### 5. Configure the Databricks cluster with the ADLS account key

```powershell
# In Databricks UI: Compute → Create compute
# Settings:
#   - Cluster name : retail-transform
#   - Cluster mode : Single node
#   - Node type    : Standard_DS2_v2
#   - Databricks Runtime: 14.x LTS (includes Spark 3.5, Scala 2.12)
#   - Autotermination: 30 minutes
#   - Advanced options → Spark config: add the following line
#     fs.azure.account.key.<storage_account>.dfs.core.windows.net <storage_account_key>
#
# Replace <storage_account> and <storage_account_key> with the $SA and $SA_KEY values from step 3.

# You can also set this programmatically using the Databricks CLI:
pip install databricks-cli

# Configure Databricks CLI
databricks configure --token
# Host: $DBW_URL  (e.g. https://adb-123456789.12.azuredatabricks.net)
# Token: <PAT from step 4>

# Create the cluster via CLI (saves the cluster ID for later use in ADF)
$cluster_config = @"
{
  "cluster_name": "retail-transform",
  "spark_version": "14.3.x-scala2.12",
  "node_type_id": "Standard_DS2_v2",
  "num_workers": 0,
  "spark_conf": {
    "spark.master": "local[*, 4]",
    "spark.databricks.cluster.profile": "singleNode",
    "fs.azure.account.key.$($SA).dfs.core.windows.net": "$SA_KEY"
  },
  "custom_tags": {"ResourceClass": "SingleNode"},
  "autotermination_minutes": 30
}
"@

$cluster_config | Out-File -Encoding utf8 cluster.json
databricks clusters create --json-file cluster.json
```

### 6. Upload the dataset to ADLS

```powershell
# Download the UCI Online Retail II zip
Invoke-WebRequest `
    -Uri "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip" `
    -OutFile "online_retail_II.zip"

Expand-Archive -Path "online_retail_II.zip" -DestinationPath ".\uci_data" -Force

# Convert Excel to CSV
cd homeworks/module6
pip install openpyxl pandas
python scripts/excel_to_csv.py `
    --input "uci_data\Online Retail II.xlsx" `
    --output-dir .\uci_data

# Verify the two CSV files exist
Get-ChildItem .\uci_data\retail_*.csv

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

### 7. Create the ADF linked services and pipeline

ADF pipeline definitions are created in the Azure portal or via JSON. The steps below use the portal for the linked services (which require secrets) and the Azure CLI for triggering runs.

```powershell
# Open ADF Studio
Start-Process "https://adf.azure.com/en/home"

# In ADF Studio, create two Linked Services:
#
# 1. Azure Data Lake Storage Gen2 linked service
#    - Name      : LS_ADLS_Retail
#    - Auth type : Account key
#    - Account key: from Key Vault → adls-storage-key
#    - Account name: $SA
#
# 2. Azure Databricks linked service
#    - Name       : LS_Databricks_Retail
#    - Workspace  : select the Databricks workspace from the subscription
#    - Cluster    : existing cluster (select retail-transform by ID)
#    - Auth       : Access token from Key Vault → databricks-pat-token
#
# Create a pipeline named "retail_forecast" with:
#    - Parameter: run_date (String, default "")
#    - Activity 1: Copy Data
#        Source     : LS_ADLS_Retail, container=raw, wildcard=retail_*.csv
#        Destination: LS_ADLS_Retail, container=processed
#    - Activity 2: Databricks Notebook (runs after Activity 1 succeeds)
#        Notebook path: /notebooks/transform
#        Base parameters: {"run_date": "@pipeline().parameters.run_date"}
```

### 8. Trigger the ADF pipeline and verify

```powershell
# Trigger the pipeline (full historical load — no run_date filter)
az datafactory pipeline create-run `
    --resource-group $RG `
    --factory-name $ADF `
    --name "retail_forecast" `
    --parameters "{}"

# The command outputs a runId. Poll for completion:
$RUN_ID = "<paste runId from above>"
az datafactory pipeline-run show `
    --resource-group $RG `
    --factory-name $ADF `
    --run-id $RUN_ID `
    --query "{status:status, message:message}" `
    --output table

# Repeat the above query every 30 seconds until status shows "Succeeded".
# Total pipeline run time: ~5–15 minutes depending on cluster warm-up.

# Verify gold-zone Parquet was written
az storage blob list `
    --account-name $SA `
    --account-key $SA_KEY `
    --container-name gold `
    --output table
```

### 9. Submit the AML training job

```powershell
# Configure the AML CLI extension
az extension add -n ml

# Set the default workspace so you don't have to repeat --workspace-name everywhere
az configure --defaults group=$RG workspace=$AML

# Create the AML environment with required packages
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
az ml environment create --name retail-forecast-env --conda-file conda_env.yml --image mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu20.04

# Create the training job YAML
# Note: --storage-key is no longer passed — the script authenticates via the
# AML workspace Managed Identity using DefaultAzureCredential.
# The cpu-cluster compute target is provisioned by terraform apply (see main.tf).
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
code: ./notebooks
environment: azureml:retail-forecast-env@latest
compute: azureml:cpu-cluster
"@
$job_yaml | Out-File -Encoding utf8 train_job.yml

# Submit the training job
az ml job create --file train_job.yml --stream
# --stream tails the logs. Press Ctrl+C to detach (job continues in background).
# To check status later:
# az ml job show --name <job-name> --query "{status:status, rmse:outputs}"
```

### 10. Register the model and deploy the Managed Online Endpoint

```powershell
# After the training job completes, the model is already auto-registered by mlflow.sklearn.log_model.
# Confirm it is in the registry:
az ml model list --output table
# Expected: retail-demand-forecast  version 1

$MODEL_VERSION = "1"

# Create the Managed Online Endpoint (this provisions the compute — takes 8–12 minutes)
az ml online-endpoint create `
    --name retail-forecast-endpoint `
    --auth-mode key

# Monitor provisioning state (repeat until it shows "Succeeded")
az ml online-endpoint show `
    --name retail-forecast-endpoint `
    --query "{name:name, provisioning_state:provisioning_state}" `
    --output table

# Create the deployment YAML (score.py is the scoring script in ./notebooks/)
$scoring_env_yaml = @"
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
$scoring_env_yaml | Out-File -Encoding utf8 deployment.yml

az ml online-deployment create --file deployment.yml --all-traffic

# Wait for deployment to reach "Succeeded" state (~8–12 minutes)
az ml online-deployment show `
    --endpoint-name retail-forecast-endpoint `
    --name blue `
    --query "{name:name, provisioning_state:provisioning_state}" `
    --output table

# Create the request file
'{"stock_code": "85123A", "week_offset": 1}' | Out-File -Encoding utf8 request.json

# Invoke the endpoint
az ml online-endpoint invoke `
    --name retail-forecast-endpoint `
    --request-file request.json
# Expected output: {"forecast": <numeric value>}
```

---

## Testing strategy

### Acceptance criterion 1: Terraform apply completes with zero errors

```powershell
cd homeworks/module6/terraform_az
terraform apply -auto-approve 2>&1 | Tee-Object -FilePath apply.log
Select-String -Path apply.log -Pattern "Error|error" | Where-Object { $_ -notmatch "0 errors" }
# Expected: no output (zero lines matching Error outside the summary line)

# Verify all three services appear in the portal
az resource list --resource-group $RG --output table
# Expected rows include: Microsoft.DataFactory/factories, Microsoft.Databricks/workspaces,
#                        Microsoft.MachineLearningServices/workspaces,
#                        Microsoft.Storage/storageAccounts, Microsoft.KeyVault/vaults
```

### Acceptance criterion 2: ADF pipeline run shows Succeeded for both activities

```powershell
# List the most recent pipeline runs and their activity details
az datafactory activity-run query-by-pipeline-run `
    --resource-group $RG `
    --factory-name $ADF `
    --run-id $RUN_ID `
    --last-updated-after "2024-01-01T00:00:00Z" `
    --last-updated-before "2030-01-01T00:00:00Z" `
    --query "value[].{activity:activityName, status:status}" `
    --output table
# Expected:
#   activity           status
#   -----------------  ---------
#   CopyData           Succeeded
#   DatabricksNotebook Succeeded
```

### Acceptance criterion 3: Gold-zone Parquet is correct — no nulls, reduced row count

```python
# Run this in a Databricks SQL cell or notebook cell after the pipeline completes.
import os
from pyspark.sql import functions as F

storage_account = os.environ.get("ADLS_ACCOUNT_NAME", "")
gold_path = f"abfss://gold@{storage_account}.dfs.core.windows.net/"
raw_path  = f"abfss://processed@{storage_account}.dfs.core.windows.net/"

df_gold = spark.read.parquet(gold_path)
df_raw  = spark.read.option("header", "true").csv(raw_path)

gold_count = df_gold.count()
raw_count  = df_raw.count()

print(f"Raw row count : {raw_count:,}")
print(f"Gold row count: {gold_count:,}")
assert gold_count < raw_count, "Gold row count should be less than raw (cancelled rows removed)"

null_count = df_gold.filter(
    F.col("StockCode").isNull() | F.col("date").isNull() | F.col("quantity_sold").isNull()
).count()
assert null_count == 0, f"Found {null_count} rows with nulls in key columns"

print("All assertions passed.")
```

### Acceptance criterion 4 and 5: AML experiment run with RMSE metric and registered model

```powershell
# List experiment runs and their metrics
az ml job list --query "[?experiment_name=='retail-demand-forecast'].{name:name, status:status}" --output table

# Show the RMSE metric for the most recent completed run
$JOB_NAME = "<job-name from list above>"
az ml job show --name $JOB_NAME --query "properties.userProperties" --output json
# Look for "rmse" in the metrics output

# Verify model is registered
az ml model show --name retail-demand-forecast --version 1 `
    --query "{name:name, version:version, path:path}" `
    --output table
# Expected: retail-demand-forecast  1  <artifact path>
```

### Acceptance criterion 6: Managed Online Endpoint returns HTTP 200 with numeric forecast

```powershell
# Check endpoint provisioning state
az ml online-endpoint show `
    --name retail-forecast-endpoint `
    --query "{name:name, scoring_uri:scoring_uri, provisioning_state:provisioning_state}" `
    --output table

# Invoke the endpoint and inspect the response
$RESPONSE = az ml online-endpoint invoke `
    --name retail-forecast-endpoint `
    --request-file request.json `
    --output json | ConvertFrom-Json

Write-Host "Forecast value: $($RESPONSE.forecast)"
# The value must be a number (not null, not a string). Any positive float is acceptable.

# Verify HTTP 200 with curl (optional cross-check)
$ENDPOINT_KEY = (az ml online-endpoint get-credentials `
    --name retail-forecast-endpoint `
    --query primaryKey -o tsv)
$SCORING_URI = (az ml online-endpoint show `
    --name retail-forecast-endpoint `
    --query scoring_uri -o tsv)

Invoke-WebRequest `
    -Uri $SCORING_URI `
    -Method POST `
    -Headers @{"Authorization" = "Bearer $ENDPOINT_KEY"; "Content-Type" = "application/json"} `
    -Body (Get-Content request.json -Raw)
# Expected StatusCode: 200
```

### Acceptance criterion 7: Parameterised pipeline with run_date filter

```powershell
# Trigger pipeline with run_date=2010-12-01
az datafactory pipeline create-run `
    --resource-group $RG `
    --factory-name $ADF `
    --name "retail_forecast" `
    --parameters '{"run_date": "2010-12-01"}'

# After run completes, verify gold-zone output in Databricks:
# spark.read.parquet(gold_path).select("date").distinct().show()
# Expected: only 2010-12-01 is present
```

```python
# Databricks assertion cell
from pyspark.sql import functions as F
df = spark.read.parquet(gold_path)
dates = [row.date.strftime("%Y-%m-%d") for row in df.select("date").distinct().collect()]
assert dates == ["2010-12-01"], f"Expected only 2010-12-01, got: {dates}"
print("Date filter assertion passed.")
```

---

## Security and architecture notes

### Azure Well-Architected Framework alignment

| Pillar | Decision |
|---|---|
| **Security** | ADLS access key is stored in Key Vault; ADF and AML access it via Managed Identity with `Key Vault Secrets User` role — no static credentials in pipeline JSON. The Databricks PAT token is also stored in Key Vault and referenced by the ADF linked service. ADLS `allow_nested_items_to_be_public = false` prevents anonymous data access. HTTPS is enforced on the storage account. |
| **Reliability** | ADF pipeline retries are configurable per activity (default: 0 retries; for production, set retry = 3 on the Copy Activity). Databricks cluster autotermination prevents runaway cost but means the first notebook run after inactivity pays a cold-start penalty (~2–5 minutes for cluster restart). AML endpoint uses a single deployment (`instance_count = 1`) — not HA, which is acceptable for coursework. |
| **Cost Optimization** | Databricks Standard tier (no Unity Catalog) + single-node cluster minimises Databricks DBU cost. The cluster autotermination at 30 minutes prevents forgotten running clusters. AML compute cluster scales to 0 when idle. All resources should be torn down with `terraform destroy` (plus manual endpoint delete) after the lab. |
| **Operational Excellence** | All six infrastructure resources are Terraform-managed. ADF linked service secrets are Key Vault references — updating a secret does not require redeployment of the pipeline. MLflow experiment tracking provides a reproducible record of every training run. The `run_date` parameterisation enables incremental reruns without code changes. |
| **Performance Efficiency** | PySpark on a single-node cluster handles 500,000 rows comfortably within a 5-minute execution window. Parquet columnar format in the gold zone enables fast predicate pushdown for any downstream SQL query. RandomForest with 100 trees on the lag-feature matrix trains in under 60 seconds on `Standard_DS2_v2`. |

### Managed Identity and RBAC chain

The deployment creates the following role assignments, which are all defined in `main.tf`:

| Principal | Role | Scope | Purpose |
|---|---|---|---|
| Terraform deployer (current user) | Key Vault Secrets Officer | Key Vault | Write ADLS key and Databricks PAT placeholder during `terraform apply` |
| ADF Managed Identity | Key Vault Secrets User | Key Vault | Read ADLS key and Databricks PAT at pipeline runtime |
| ADF Managed Identity | Storage Blob Data Contributor | ADLS account | Copy raw → processed without a static key |
| AML workspace Managed Identity | Storage Blob Data Reader | ADLS account | Workspace-level data access (scoring endpoint reads gold zone) |
| AML workspace Managed Identity | AcrPush | Container Registry | Build and cache training environment images |
| AML compute cluster Managed Identity | Storage Blob Data Reader | ADLS account | Training job reads gold Parquet — jobs run as the **cluster** identity, not the workspace identity |

No credentials are hard-coded in pipeline JSON definitions or in Terraform resource attributes (except the PAT placeholder, which is overwritten in step 4).

### ADLS HNS and the ABFS driver

Databricks accesses ADLS Gen2 using the Azure Blob File System (ABFS) driver with the `abfss://` URI scheme. This requires `is_hns_enabled = true` on the storage account — hierarchical namespace enables atomic directory operations that ABFS relies on. Storage accounts with HNS enabled are ADLS Gen2; those without HNS are ordinary Blob Storage. **HNS cannot be enabled after account creation** — if Terraform state shows HNS disabled, destroy and recreate the account (see Known Limitations #5).

---

## Known limitations and operational notes

1. **Databricks workspace provisioning appears to hang** — The `azurerm_databricks_workspace` resource typically takes 5–10 minutes to provision. During this window, Terraform reports `Still creating... [Xm Xs elapsed]` with no further output. This is normal — the Azure Databricks control plane is performing backend setup. Do not interrupt `terraform apply`. If the apply times out (rare), re-run `terraform apply`; Terraform will pick up where it left off.

2. **AML workspace creates a second Key Vault by default** — If `key_vault_id` is not explicitly passed to `azurerm_machine_learning_workspace`, Azure automatically creates a companion Key Vault, leaving the resource group with two Key Vaults. The Terraform in this module passes the shared Key Vault via `key_vault_id = azurerm_key_vault.kv.id`, so only one Key Vault is created. If you see two Key Vaults in the portal, the workspace was created outside Terraform — destroy and re-provision.

3. **AML Managed Online Endpoint deployment takes 8–12 minutes** — `az ml online-deployment create` returns immediately with a `Running` provisioning state, but the endpoint is not reachable until the state transitions to `Succeeded`. Calling `az ml online-endpoint invoke` before this transition returns HTTP 404. Poll with `az ml online-deployment show` every 60 seconds and wait for `provisioning_state == Succeeded` before invoking.

4. **Databricks PAT token must be created manually** — The `azurerm` Terraform provider cannot create Databricks PAT tokens for the initial workspace. The Databricks Terraform provider (`databricks/databricks`) can, but introducing a second provider adds authentication complexity not warranted for this lab. Students must create the PAT via the Databricks UI (step 4 of the walkthrough) and store it in Key Vault manually.

5. **ADLS Gen2 HNS is irreversible** — Once a storage account is created with `is_hns_enabled = true`, it cannot be downgraded to standard Blob Storage. Conversely, a Blob Storage account cannot be upgraded to ADLS Gen2 in place. If you need to change this setting, `terraform destroy` the account and recreate it. For this lab, the Parquet data is ephemeral and recreatable from the source CSVs, so destroy-and-recreate is acceptable.

6. **ADF Databricks Notebook Activity requires an existing cluster ID** — The ADF linked service for Databricks must reference a specific existing cluster ID (not a job cluster). If the cluster is deleted or the workspace is reprovisioned, the linked service must be updated with the new cluster ID. For production workloads, use job clusters or Databricks Workflows instead of ADF Notebook Activities to avoid this coupling.

7. **`terraform destroy` fails if the AML Managed Online Endpoint has active deployments** — Azure will refuse to delete the AML workspace while a Managed Online Endpoint with deployments exists. Run the following commands before `terraform destroy`:

   ```powershell
   # Delete the deployment first, then the endpoint
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

   # Now destroy is safe
   cd homeworks/module6/terraform_az
   terraform destroy -auto-approve
   ```

8. **AML compute cluster minimum instance count** — The `cpu-cluster` is created with `min-instances = 0`, meaning it scales to zero when idle. The first training job after inactivity pays a cluster warm-up penalty of ~3–5 minutes. If you are iterating on the training script frequently, temporarily set `min-instances = 1` to keep at least one node warm. Remember to set it back to 0 before leaving to avoid unnecessary compute charges.

9. **`ADLS_ACCOUNT_NAME` must be set in the deployment YAML** — The scoring script (`score.py`) reads the gold zone at container startup via `ADLS_ACCOUNT_NAME`. If this environment variable is missing or empty, the endpoint will start successfully but all forecasts will be based on zero-padded lag features (effectively returning a zero-trained prediction). Set it to the storage account name from `$SA` (step 3) in `deployment.yml` under `environment_variables`. Redeploying the endpoint after correcting the variable requires running `az ml online-deployment create` again with `--all-traffic`.
