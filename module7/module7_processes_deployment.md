# Homework — Module 7: Processes and App Deployment

## Learning objectives

- Design and implement a three-stage CI/CD pipeline (IaC validation, container build, deployment) using GitHub Actions with job dependencies and a manual approval gate
- Apply Infrastructure-as-Code security scanning to Terraform configurations using `tflint` and `checkov` and interpret scan findings
- Build and scan a Docker image for known CVEs with Trivy, and suppress or remediate findings at the CRITICAL severity level
- Write `terraform test` assertions for a reusable Terraform module and execute them in a GitHub Actions job
- Instrument a FastAPI service with Application Insights telemetry and verify that request traces appear in the Azure portal within minutes of traffic generation
- Configure Azure Monitor metric alert rules as Terraform resources, trigger them intentionally, and confirm the alert lifecycle transitions to `Fired` state

## Application concept

The Quote of the Day API is an intentionally small FastAPI service — fewer than 80 lines of Python — whose sole purpose is to demonstrate a complete, production-grade delivery pipeline. The service exposes three endpoints: a health check, a random quote retrieval endpoint backed by a bundled `quotes.json` file, and a Prometheus-format metrics endpoint that counts total requests broken down by path. The simplicity of the application code is deliberate: students should spend almost all of their effort on the pipeline, not on business logic.

Every request to the service is forwarded to Azure Application Insights as a request telemetry item, using the `opencensus-ext-azure` middleware. This gives students a concrete, verifiable observability target: after generating traffic they can open the Azure portal and see individual request traces by name, duration, and status code without writing any custom logging code. The Application Insights connection string is stored in Azure Key Vault and injected into both ACI container instances as a `secure_environment_variables` entry by Terraform, so the secret never appears in plaintext in the workflow logs or Terraform state.

The delivery pipeline consists of three GitHub Actions workflows that students create from scratch. The first workflow validates Terraform formatting and runs two IaC security scanners on every pull request. The second workflow runs unit tests, builds the Docker image, scans it for vulnerabilities, and pushes the passing image to Azure Container Registry. The third workflow deploys the image to a staging environment, waits for manual approval, and then promotes to production — all orchestrated through `terraform apply` targeting specific resources. By the end of the homework, students have operated a full GitOps loop: committing a deliberate error, watching the pipeline fail, fixing the error, and watching it pass.

## Architecture overview

- **FastAPI service** (`homeworks/module7/src/quote_api/`) — single Python container; exposes `GET /`, `GET /quotes`, and `GET /metrics`; instrumented with `opencensus-ext-azure` request middleware; fewer than 80 lines of Python
- **GitHub Actions workflows** — three workflows: `07_iac_validate.yml` (PR gate), `07_app_build.yml` (build and scan), `07_deploy.yml` (deploy with manual approval); students write all three from scratch
- **Azure Container Registry** (Basic SKU) — stores the `quote-api` Docker image; admin credentials enabled for ACI image pull; image is pushed by `07_app_build.yml` after Trivy scan passes
- **Azure Key Vault** (Standard tier) — stores ACR admin password and Application Insights connection string; secrets are injected into ACI via Terraform `secure_environment_variables`; never appear in workflow logs
- **Azure Application Insights** (workspace-based) — receives request telemetry from both ACI instances via `opencensus-ext-azure` middleware; the Transaction search view is the primary verification target
- **Azure Log Analytics Workspace** — backs the workspace-based Application Insights instance; required for workspace-based mode
- **Azure Container Instances — staging** (`quote-api-staging`, 0.5 vCPU / 0.5 GB) — deployed by `07_deploy.yml` after `terraform test` passes; receives the `APPLICATIONINSIGHTS_CONNECTION_STRING` secret from Key Vault
- **Azure Container Instances — production** (`quote-api-prod`, 0.5 vCPU / 1 GB) — deployed after manual approval in the `production` environment gate; separate resource from staging to enforce an explicit promotion step
- **Azure Monitor metric alert rules** × 2 — `latency-slo` (p99 request duration > 500 ms) and `error-rate-slo` (HTTP 5xx rate > 1%); both backed by an Action Group that sends email on `Fired`; provisioned and managed entirely by Terraform
- **Azure Policy assignments** × 2 — enforce the built-in "Require a tag and its value" policy for `environment` and `owner` tags on all resources in the resource group; compliance state is visible in the Azure portal Policy blade

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Resource group | `azurerm_resource_group` | AWS resource group (tag-based) |
| Container registry | Azure Container Registry (Basic SKU) | Amazon ECR (private repository) |
| Key Vault | Azure Key Vault (Standard tier) | AWS Secrets Manager |
| Key Vault secrets | `azurerm_key_vault_secret` × 2 | `aws_secretsmanager_secret` × 2 |
| Log Analytics workspace | Azure Log Analytics Workspace | Amazon CloudWatch Log Group |
| Application Insights | Azure Application Insights (workspace-based) | AWS X-Ray + CloudWatch Application Insights |
| Container runtime — staging | Azure Container Instances (0.5 vCPU / 0.5 GB) | AWS App Runner or ECS Fargate (0.25 vCPU / 0.5 GB) |
| Container runtime — production | Azure Container Instances (0.5 vCPU / 1 GB) | AWS App Runner or ECS Fargate (0.25 vCPU / 1 GB) |
| Monitor action group | Azure Monitor Action Group (email receiver) | Amazon SNS topic + subscription |
| Monitor metric alert — latency | `azurerm_monitor_metric_alert` (p99 > 500 ms) | CloudWatch Alarm on `p99Latency` metric |
| Monitor metric alert — error rate | `azurerm_monitor_metric_alert` (5xx rate > 1%) | CloudWatch Alarm on `5xxError` metric |
| Azure Policy assignment — environment tag | `azurerm_resource_policy_assignment` | AWS Config Rule (required-tags) |
| Azure Policy assignment — owner tag | `azurerm_resource_policy_assignment` | AWS Config Rule (required-tags) |

## Exercise tasks

1. **Create `07_iac_validate.yml` and verify it gates bad formatting.**
   Write a GitHub Actions workflow triggered on PRs that touch `homeworks/module7/**`. The workflow must run `terraform fmt --check` on `homeworks/module7/terraform_az/`, then `tflint --chdir homeworks/module7/terraform_az/`, then `checkov --directory homeworks/module7/terraform_az/ --framework terraform`. Commit a deliberate formatting error to the Terraform code (for example, remove a blank line between resource blocks that `terraform fmt` would add), open a PR, and confirm the `terraform fmt --check` step fails with a non-zero exit code visible in the Actions log. Fix the formatting error, push to the branch, and confirm the workflow passes. Include the `checkov` scan output — including any suppressions you added — in your submission screenshot.

2. **Create `07_app_build.yml`, scan the image, and push it to ACR.**
   Write a GitHub Actions workflow triggered on pushes to `main` that touch `homeworks/module7/src/**`. The workflow must: run `pytest homeworks/module7/src/quote_api/tests/`; build the Docker image with `docker build -t quote-api homeworks/module7/src/quote_api/`; run `trivy image --exit-code 1 --severity CRITICAL quote-api`. If Trivy reports CRITICAL CVEs, either fix them by switching to a newer base image tag or suppress known acceptable CVEs by adding a `.trivyignore` file with the CVE ID and a comment explaining why it is acceptable. Confirm the workflow completes with all three steps green and the image appears in the ACR repository list in the Azure portal.

3. **Write `.tftest.hcl` assertions for the `container_instance` module.**
   Create `homeworks/module7/terraform_az/modules/container_instance/container_instance.tftest.hcl`. The test must include a `run` block that asserts `output.cpu == 0.5` and `output.memory == 0.5` for a staging-sized container instance configuration. Run `terraform test` locally from `homeworks/module7/terraform_az/` and confirm the command prints at least one `pass` assertion. The test file does not need to deploy real infrastructure — `command = plan` (the default) is sufficient and incurs no cost.

4. **Implement `07_deploy.yml` with three jobs and deploy to staging.**
   Write a GitHub Actions workflow that triggers after `07_app_build.yml` succeeds. Job 1 runs `terraform test` on the `container_instance` module. Job 2 (`needs: test`) runs `terraform apply -target=module.quote_api_staging -auto-approve` to deploy the staging ACI. Job 3 (`needs: staging`, `environment: production`) uses a manual approval gate and then runs `terraform apply -auto-approve` for the full configuration including the production ACI. After Job 2 completes, confirm that `GET /` against the staging FQDN (obtained from `terraform output -raw staging_fqdn`) returns HTTP 200 with body `{"status": "ok", "version": "1.0.0"}`.

5. **Instrument the app with Application Insights and verify traces.**
   Confirm that `main.py` uses the `AzureExporter` middleware from `opencensus-ext-azure` and that the `APPLICATIONINSIGHTS_CONNECTION_STRING` environment variable is wired from Key Vault through a `secure_environment_variables` block in the Terraform `container_instance` module call for staging. Redeploy if needed, then use a loop (`for i in {1..20}; do curl -s <staging_fqdn>:8000/quotes; done`) to generate 20 requests against the staging ACI. Open Azure portal → Application Insights resource → Transaction search, set the time range to the last 30 minutes, and confirm that request telemetry items for `GET /quotes` are visible with a status code of `200` within 5 minutes of generating traffic.

6. **Trigger the latency alert and confirm it fires.**
   Run `terraform state list` and confirm both `azurerm_monitor_metric_alert.latency_slo` and `azurerm_monitor_metric_alert.error_rate_slo` appear in the output. To trigger the latency alert, temporarily add `import time; time.sleep(0.7)` at the start of the `/quotes` handler, rebuild and push the image, redeploy the staging ACI via `terraform apply -target=module.quote_api_staging`, and generate at least 50 requests. Wait up to 10 minutes (Azure Monitor alert evaluation granularity is a minimum of 1 minute with a 5-minute aggregation window) and confirm in the Azure portal under Monitor → Alerts that the `latency-slo` alert transitions to `Fired` state. Remove the `time.sleep` call, rebuild, and redeploy to restore normal behavior.

7. **Enforce and verify Azure Policy tag compliance.**
   Run `terraform apply` and navigate to Azure portal → Policy → Compliance. Confirm that one or more resources in the resource group are flagged as non-compliant because they are missing the `environment` or `owner` tag. Add `tags = { environment = "module7", owner = "student" }` (or equivalent) to every `resource` and `module` block in your Terraform configuration. Run `terraform apply` again. Then run `az policy state trigger-scan --resource-group <rg-name>` to force an immediate compliance evaluation (compliance scans otherwise run on a 30-minute delay). Confirm the compliance report in the portal shows 0 non-compliant resources for both the `environment` and `owner` tag assignments.

## Acceptance criteria

- `07_iac_validate.yml` fails on a PR with a deliberate Terraform formatting error and passes after the error is corrected; the `checkov` scan output (including any `# checkov:skip` suppressions) is visible in the GitHub Actions log
- `07_app_build.yml` completes with zero CRITICAL CVEs in the Trivy scan output (either the base image has no CRITICAL CVEs or a `.trivyignore` file suppresses them with documented justification); the `quote-api` Docker image is pushed to ACR and is visible in the registry portal
- `terraform test` passes for the `container_instance` module; the GitHub Actions log for Job 1 of `07_deploy.yml` shows at least one `pass` assertion for the `cpu` and `memory` outputs
- The staging ACI FQDN is reachable after Job 2 of `07_deploy.yml` completes; `GET /` returns HTTP 200 with body `{"status": "ok", "version": "1.0.0"}`
- Application Insights Transaction search shows request telemetry items for `GET /quotes` with status `200` within 5 minutes of generating 20 requests against the staging ACI
- `terraform state list` shows both `azurerm_monitor_metric_alert.latency_slo` and `azurerm_monitor_metric_alert.error_rate_slo`; the `latency-slo` alert transitions to `Fired` in the Azure portal during the `time.sleep(0.7)` injection test
- Azure Policy compliance report shows 0 non-compliant resources after `environment` and `owner` tags are applied to all Terraform resources via `terraform apply` and an on-demand scan is triggered with `az policy state trigger-scan`
- `terraform destroy` removes all resources without errors; the resource group is absent from the Azure portal after destruction completes
