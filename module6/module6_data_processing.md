# Homework — Module 6: Data processing

## Learning objectives

- Design and deploy a multi-stage batch data pipeline that moves data through raw, processed, and gold storage zones using Azure Data Factory and Azure Databricks
- Implement data quality filters in PySpark: drop cancelled transactions, remove null keys, and eliminate non-positive quantities before aggregating to a reporting granularity
- Write Parquet output from a Databricks notebook and verify its correctness by querying it with Spark SQL
- Train a scikit-learn regression model inside an Azure Machine Learning pipeline, track the RMSE metric with MLflow, and register the resulting artifact in the AML Model Registry
- Deploy a registered model to an AML Managed Online Endpoint and invoke it via the Azure CLI to obtain a real-time demand forecast
- Parameterise an ADF pipeline with a `run_date` parameter and demonstrate that re-running the pipeline with a specific date produces a correctly filtered gold-zone output

## Application concept

The Retail Demand Forecast Pipeline processes historical UK e-commerce transaction data from the UCI Online Retail II dataset (~500,000 rows spanning 2009–2011) and produces next-week demand forecasts per product. Raw transaction CSV files land in a designated cold-storage zone; an Azure Data Factory pipeline then copies them to a processed zone and triggers a Databricks notebook that cleans and aggregates the data to a daily product-level summary written as Parquet to a gold zone. A downstream Azure Machine Learning pipeline reads the gold Parquet, engineers lag features, trains a RandomForestRegressor, and registers the model. The registered model is exposed as a Managed Online Endpoint that a student can query with a stock code and receive a numeric weekly demand forecast.

The pipeline is intentionally batch-oriented and follows a medallion architecture (raw → processed → gold) that is standard in modern data lakehouse designs. Students experience the full lifecycle: data ingestion, transformation, feature engineering, model training with experiment tracking, model registration, and real-time serving — all wired together with Terraform-provisioned infrastructure and code they write themselves. The ADF parameterisation task (Task 7) teaches students how a single reusable pipeline definition can be re-run for any historical date, which is the foundation of incremental processing in production systems.

## Architecture overview

- **Dataset source** — UCI Online Retail II (CC BY 4.0); helper script `scripts/excel_to_csv.py` converts the two Excel sheets to `retail_2009.csv` and `retail_2010.csv`; files are uploaded to ADLS with `az storage blob upload-batch`
- **Azure Data Lake Storage Gen2** — StorageV2 account with hierarchical namespace (HNS) enabled; three containers: `raw` (CSV landing), `processed` (copy destination), `gold` (Parquet output from Databricks)
- **Azure Data Factory** — pipeline with a CopyData activity (raw → processed) followed by a Databricks Notebook activity that triggers the PySpark transformation job; parameterised with a `run_date` string for incremental runs
- **Azure Databricks workspace** — Standard tier; PySpark notebook parses InvoiceDate, drops cancelled orders (InvoiceNo starts with `"C"`), drops rows with null CustomerID or non-positive Quantity, aggregates to daily StockCode-level total Quantity sold, and writes Parquet to the gold container
- **Azure Machine Learning workspace** — hosts the training pipeline (scikit-learn RandomForestRegressor with lag features), MLflow experiment tracking, model registry, and a Managed Online Endpoint for real-time scoring; auto-creates companion Application Insights, Container Registry, and Key Vault on provisioning
- **Azure Key Vault** — stores the ADLS storage account key and the Databricks PAT token; referenced by ADF linked services so no credentials are hard-coded in pipeline definitions
- **Terraform** — provisions all six infrastructure resources above; AML workspace provisioning is handled by `azurerm_machine_learning_workspace`; Databricks workspace by `azurerm_databricks_workspace`

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Data lake storage | ADLS Gen2 (StorageV2 + HNS enabled) | Amazon S3 |
| ETL orchestration | Azure Data Factory | AWS Glue / Step Functions |
| Distributed processing | Azure Databricks Standard | AWS Glue ETL / EMR Serverless |
| ML training + registry | Azure Machine Learning (Basic workspace) | Amazon SageMaker |
| Model serving | AML Managed Online Endpoint | SageMaker real-time endpoint |
| Secrets | Azure Key Vault (Standard tier) | AWS Secrets Manager |

## Exercise tasks

1. **Provision infrastructure with Terraform.**
   Run `terraform init && terraform plan && terraform apply` from `homeworks/module6/terraform_az/`. Provisioning takes 10–15 minutes because the Databricks workspace and AML workspace both involve background Azure operations. Confirm that the ADF instance, Databricks workspace, and AML workspace all appear in the Azure portal under the module6 resource group before proceeding.

2. **Prepare and upload the dataset.**
   Download the UCI Online Retail II zip from `https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip`, extract the Excel file, and run `python scripts/excel_to_csv.py` to produce `retail_2009.csv` and `retail_2010.csv`. Upload both files to the ADLS `raw` container with `az storage blob upload-batch --destination raw --source ./ --pattern "retail_*.csv"`. Trigger the ADF pipeline manually from the ADF Monitor or Azure CLI and verify that both the CopyData activity and the Databricks Notebook activity show `Succeeded` status.

3. **Implement the PySpark transformation notebook.**
   In Databricks, create a notebook at `notebooks/transform.py` (or import `homeworks/module6/notebooks/transform.py`). The notebook must: read both CSV files from the `processed` container; parse InvoiceDate to a date column; drop any row where InvoiceNo begins with `"C"` (cancelled orders); drop rows where Quantity is ≤ 0 or CustomerID is null; group by StockCode and date to compute total Quantity sold (`quantity_sold`); and write the result as Parquet to the `gold` container with `mode("overwrite")`. The notebook must accept a `run_date` widget so that Task 7 can filter by date.

4. **Inspect and validate the gold-zone output.**
   In a new Databricks SQL cell (or `spark.read.parquet()` call), read the gold-zone Parquet. Assert that the row count is strictly less than the combined raw CSV row count (demonstrating that cancelled/null rows were removed). Verify that `spark.sql("SELECT COUNT(*) FROM gold WHERE StockCode IS NULL OR date IS NULL OR quantity_sold IS NULL").collect()[0][0] == 0`. Include the row counts and the null-check result in your submission notes.

5. **Write and run the AML training script.**
   Create `homeworks/module6/notebooks/train.py`. The script must: read Parquet from the gold container using the storage account connection string; pivot the data to build 7-day lag features per StockCode; split 80/20 by date into train and test sets; train a `sklearn.ensemble.RandomForestRegressor`; compute RMSE on the test set; call `mlflow.log_metric("rmse", rmse_value)`; and save the model with `mlflow.sklearn.log_model`. Submit the script as an AML `Command` job using `az ml job create`. Confirm the experiment run appears in AML Studio with a logged `rmse` value.

6. **Register the model and deploy to a Managed Online Endpoint.**
   After the training job completes, register the model in the AML Model Registry with `az ml model create`. Create a Managed Online Endpoint with `az ml online-endpoint create` and deploy the registered model with `az ml online-deployment create`. Once the endpoint reports `Succeeded` provisioning state, invoke it with `az ml online-endpoint invoke --request-file request.json` where `request.json` contains `{"stock_code": "85123A", "week_offset": 1}`. Confirm the response body contains a numeric `forecast` field.

7. **Parameterise the ADF pipeline and run an incremental date filter.**
   Add a string parameter `run_date` (format `YYYY-MM-DD`) to the ADF pipeline and pass it to the Databricks Notebook activity as a notebook parameter. Modify the Databricks notebook to check whether the `run_date` widget is set and, if so, filter the processed data to only rows where `InvoiceDate == run_date` before aggregating and writing to the gold container. Trigger the pipeline with `run_date=2010-12-01` using `az datafactory pipeline create-run`. Read the resulting gold-zone Parquet and verify it contains only rows where `date == "2010-12-01"`.

## Acceptance criteria

- `terraform apply` completes with zero errors; ADF, Databricks workspace, and AML workspace are all visible in the Azure portal under the module6 resource group
- ADF pipeline run shows `Succeeded` status for both the CopyData activity and the Databricks Notebook activity in ADF Monitor
- Gold-zone Parquet files are present in the ADLS `gold` container; a Databricks SQL query confirms zero null values in the `StockCode`, `date`, and `quantity_sold` columns, and the row count is lower than the raw CSV row count
- AML experiment run is visible in AML Studio under the module6 experiment with a logged `rmse` metric value
- Trained model appears in the AML Model Registry with at least version 1
- Managed Online Endpoint reports `Succeeded` provisioning state and returns HTTP 200 with a JSON body containing a numeric `forecast` field when invoked via `az ml online-endpoint invoke`
- Parameterised ADF pipeline run with `run_date=2010-12-01` produces gold-zone Parquet files that contain only rows where `date == "2010-12-01"`, confirmed by a Databricks SQL or PySpark assertion
- `terraform destroy` removes all resources without errors and the Azure portal shows an empty resource group (note: the AML Managed Online Endpoint must be deleted manually before running destroy — see the Azure implementation guide)
