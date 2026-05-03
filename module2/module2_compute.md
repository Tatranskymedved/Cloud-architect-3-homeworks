# Homework — Module 2: Compute

## Learning objectives

- Understand that VMs, containers, and serverless are architectural trade-offs, not a progression from "worse" to "better"
- Measure cold start latency differences between always-on (VM) and event-driven (serverless) compute
- Compare per-invocation cost at low load (< 10 req/min) vs. high load (> 500 req/min) across all three models
- Provision identical application logic on three different compute platforms using Terraform
- Identify the operational overhead each model places on the developer (OS patching, container image management, runtime versioning)
- Analyze when each compute model is the right choice based on traffic pattern, budget, and team capability

## Application concept

The Image Thumbnail Generator takes an uploaded image (JPEG or PNG, up to 5 MB) via an HTTP POST request and returns a 128×128 pixel thumbnail as a binary response. The processing logic is identical across all three deployments — only the hosting model changes. The function reads the image from the request body, resizes it using a standard image library (Pillow for Python or Sharp for Node.js), and returns the resized bytes with the appropriate `Content-Type` header.

Each deployment exposes the same HTTP endpoint contract (`POST /thumbnail`), so a single load-test script can target all three without modification. Students deploy all three variants to the same cloud region and same virtual network to eliminate network latency as a variable in their measurements.

## Architecture overview

- **Shared storage**: one object storage bucket/account holds sample test images used by the load-test script
- **VM deployment**: a single general-purpose VM running a Python/Node.js HTTP server (e.g., Gunicorn or Express) behind a load balancer; the VM runs 24/7
- **Container deployment**: a managed container platform hosts one replica of the thumbnail service as a Docker container; the platform handles scheduling and restarts
- **Serverless deployment**: a function triggered by HTTP; the platform manages all infrastructure, scales to zero when idle
- **Load-test client**: a local script (k6 or Apache Bench) that sends bursts of POST requests to each endpoint and records p50/p95/p99 latency and error rate
- **Terraform root module**: one directory per deployment model (`vm/`, `container/`, `serverless/`), each with its own `main.tf`, `variables.tf`, and `outputs.tf`

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Virtual machine (2 vCPU, 4 GB RAM) | `azurerm_linux_virtual_machine` (Standard_B2s) | `aws_instance` (t3.medium) |
| VM public IP / DNS | `azurerm_public_ip` | `aws_eip` |
| VM network interface | `azurerm_network_interface` | `aws_network_interface` |
| Virtual network + subnet | `azurerm_virtual_network`, `azurerm_subnet` | `aws_vpc`, `aws_subnet` |
| Network security group (allow 80, 443, 22) | `azurerm_network_security_group` | `aws_security_group` |
| Managed container platform | `azurerm_container_app` + `azurerm_container_app_environment` | `aws_ecs_service` + `aws_ecs_cluster` (Fargate) |
| Container registry | `azurerm_container_registry` (Basic SKU) | `aws_ecr_repository` |
| Serverless function runtime | `azurerm_linux_function_app` (Consumption plan) | `aws_lambda_function` (runtime: python3.12) |
| Serverless function storage account | `azurerm_storage_account` (required by Functions host) | `aws_s3_bucket` (deployment package) |
| Serverless HTTP trigger / API gateway | Built into `azurerm_linux_function_app` | `aws_api_gateway_rest_api` + `aws_api_gateway_integration` |
| Object storage for test images | `azurerm_storage_container` inside existing storage account | `aws_s3_bucket` |
| IAM / managed identity | `azurerm_user_assigned_identity` | `aws_iam_role` + `aws_iam_role_policy` |

## Exercise tasks

1. **Set up the directory structure.** In your local checkout of the course repository (on your working branch), navigate to `homeworks/module2/`. Create a `terraform/` directory inside it with three subdirectories: `vm/`, `container/`, and `serverless/`. Each must be a standalone Terraform root module with `main.tf`, `variables.tf`, and `outputs.tf`.

2. **Write the thumbnail function** in Python (Pillow) or Node.js (Sharp). The handler must accept a raw binary POST body, resize the image to 128×128, and return the resized bytes. Commit this code to `homeworks/module2/src/`. Write a `Dockerfile` that produces an image under 200 MB.

3. **VM deployment**: Write Terraform in `homeworks/module2/terraform/vm/` to provision the VM, network, and security group. Add a `user_data` / `custom_data` cloud-init script that installs the runtime, clones your function code, and starts the HTTP server on port 80 as a systemd service. Run `terraform apply` and verify the endpoint responds to `curl -X POST http://<vm-ip>/thumbnail -H "Content-Type: image/jpeg" --data-binary @sample.jpg` with HTTP 200.

4. **Container deployment**: Push your Docker image to the container registry provisioned by Terraform. Write Terraform in `homeworks/module2/terraform/container/` to deploy one replica of that image. Expose port 80 via the platform's ingress. Verify the same `curl` command works against the container endpoint.

5. **Serverless deployment**: Package the function according to your chosen platform's requirements (a `.zip` for Lambda, or use the Azure Functions Core Tools zip deploy). Write Terraform in `homeworks/module2/terraform/serverless/` to deploy the function. Verify the same `curl` command works against the function URL.

6. **Cold start measurement**: Stop or idle each deployment for at least 5 minutes (shut down the VM, scale the container to zero replicas, let the serverless function go cold). Then send a single POST request to each endpoint and record the response time with `curl -w "%{time_total}\n"`. Repeat 5 times and record the minimum and maximum values for each platform.

7. **Load test**: Using k6 or Apache Bench, run a 60-second load test against each endpoint at two load levels: 10 concurrent users and 50 concurrent users. Record p50, p95, and p99 latency and the total error rate for each combination. Save the raw output as `results/load_<platform>_<concurrency>.txt`.

8. **Cost estimate**: Using your cloud provider's pricing calculator, estimate the monthly cost of each deployment at 10 req/min sustained load and at 1,000 req/min sustained load. Record the estimates in a table in your submission document.

9. **Tear down**: Run `terraform destroy` in all three module directories. Confirm in the cloud console that no billable resources remain.

10. **Write a comparison document** (`submission.md` in the root of your submission): a table with one row per platform and columns for cold start (min/max), p95 latency at 50 users, estimated monthly cost at 10 req/min, estimated monthly cost at 1,000 req/min, and your rating (1–5) of operational overhead. Below the table, write 2–3 sentences explaining which platform you would choose for a thumbnail service that receives 5 req/min on average but occasionally spikes to 200 req/min for 2 minutes.

## Acceptance criteria

- All three Terraform modules apply without errors and produce the required `outputs.tf` values (endpoint URL, resource group / region).
- All three endpoints return HTTP 200 and a valid JPEG/PNG binary body for a valid input image.
- All three endpoints return HTTP 400 or 422 (not 500) when sent a non-image binary payload.
- Cold start measurements are recorded for all three platforms with at least 5 samples each.
- Load test result files exist for all six combinations (3 platforms × 2 concurrency levels) and show p95 latency below 5,000 ms at 10 concurrent users for all platforms.
- The VM and container deployments show a cold start time under 5,000 ms; the serverless deployment cold start time is documented regardless of value.
- Cost estimates are provided for both load levels for all three platforms and are within ±20% of the instructor's reference calculation.
- `terraform destroy` removes all provisioned resources; the cloud console shows zero running instances, containers, and functions in the target resource group / account after destroy.
- `submission.md` contains the comparison table with all required columns filled in and the 2–3 sentence platform recommendation with a justification that references at least one measured data point.
