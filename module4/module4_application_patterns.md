# Homework — Module 4: Application Patterns

## Learning objectives

- Implement async messaging between decoupled services using a managed queue/topic
- Apply the choreography pattern to an order processing pipeline
- Implement retry with exponential back-off on the consumer side
- Handle poison messages by routing them to a dead-letter queue (DLQ) after a configurable number of delivery attempts
- Expose `/health` and `/metrics` (Prometheus format) endpoints on background worker services
- Build a Grafana dashboard that surfaces queue depth, processing rate, and error count in real time
- Provision all cloud resources with Terraform and keep credentials out of source code

## Application concept

The homework implements a minimal e-commerce order processing pipeline split into three independently deployable components. A **Producer** service exposes a REST API; when a client POSTs a new order, the Producer validates the payload and publishes a message to a managed queue or topic. A **Consumer** service runs as a background worker, polling the queue, writing the order to a simulated data store (an in-memory dict or a single-table database), and acknowledging the message on success. If processing fails repeatedly, the message is moved to a dead-letter queue automatically by the broker after the configured maximum delivery count is reached.

A third component, the **Dead-letter Handler**, polls the DLQ, logs each unprocessable message as a structured JSON line, increments a Prometheus counter, and discards the message. All three components run in Docker containers. Students provision the messaging infrastructure with Terraform, wire up the containers with environment variables, and finish by connecting a Grafana dashboard to a Prometheus instance that scrapes the Consumer and Dead-letter Handler.

## Architecture overview

- **Producer** — FastAPI application; `POST /orders` validates the request body (order ID, item SKU, quantity, customer email) and publishes to the primary queue/topic; returns `202 Accepted` with the message ID
- **Consumer** — Python worker (`while True` polling loop or push subscription); processes each message with a simulated 50–200 ms delay; retries up to 3 times with exponential back-off (base 1 s, factor 2) before letting the broker move the message to the DLQ; exposes `/health` (JSON `{"status": "ok"}`) and `/metrics` (Prometheus text format) on port 8001
- **Dead-letter Handler** — Python worker polling the DLQ; logs each message to stdout as `{"event": "dlq_received", "order_id": "...", "reason": "..."}` and increments a `dlq_messages_total` counter; exposes `/metrics` on port 8002
- **Prometheus** — scrapes Consumer `:8001/metrics` and Dead-letter Handler `:8002/metrics` every 15 s
- **Grafana** — reads from Prometheus; dashboard with three panels (queue depth, messages processed per minute, DLQ message count)
- **Managed queue/topic** — primary queue with a dead-letter sub-queue; maximum delivery count set to 3
- **Terraform** — provisions the messaging namespace/queue and (optionally) the container hosting environment

## Cloud resources to provision (via Terraform)

| Resource | Azure equivalent | AWS equivalent |
|---|---|---|
| Messaging namespace | `azurerm_servicebus_namespace` (Standard tier) | `aws_sqs_queue` (standard queue) |
| Primary queue | `azurerm_servicebus_queue` (`max_delivery_count = 3`, `dead_lettering_on_message_expiration = true`) | `aws_sqs_queue` with `redrive_policy` pointing to DLQ, `maxReceiveCount = 3` |
| Dead-letter queue | Built-in `$DeadLetterQueue` sub-queue on the Service Bus queue | Separate `aws_sqs_queue` referenced in the redrive policy |
| Shared access policy / IAM | `azurerm_servicebus_queue_authorization_rule` (Send + Listen) | `aws_iam_role` with `sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage` permissions |
| Container hosting (optional) | `azurerm_container_group` (ACI) | `aws_ecs_task_definition` + `aws_ecs_service` (Fargate) |
| Resource group / namespace | `azurerm_resource_group` | AWS region is implicit; use `aws_resourcegroups_group` for tagging |

## Exercise tasks

1. **Scaffold the module directory.** In your local checkout of the course repository (on your working branch), navigate to `homeworks/module4/` (this directory already exists). Create subdirectories `producer/`, `consumer/`, `dlq_handler/`, `terraform/`, and `monitoring/` inside it.

2. **Implement the Producer** — write a FastAPI app in `producer/main.py`. The `POST /orders` endpoint must validate that `order_id` (string), `sku` (string), `quantity` (int >= 1), and `email` (valid email format) are present, then publish a JSON-serialised message to the primary queue. Return `{"message_id": "<broker-assigned-id>"}` with HTTP 202. Add a `Dockerfile` that runs the app on port 8000.

3. **Implement the Consumer** — write a Python worker in `consumer/worker.py`. Poll the primary queue in a loop. For each message: parse the JSON body, print `{"event": "order_received", "order_id": "..."}` to stdout, and simulate processing with `time.sleep(random.uniform(0.05, 0.2))`. If processing raises an exception, do NOT acknowledge the message so the broker retry counter increments. After the third failed attempt the broker moves it to the DLQ automatically — do not implement manual DLQ routing. Expose `/health` and `/metrics` on port 8001 using a background thread running a minimal HTTP server (or a second FastAPI app). Track two Prometheus metrics: `orders_processed_total` (counter) and `order_processing_duration_seconds` (histogram, buckets 0.05–1.0 s). Add a `Dockerfile`.

4. **Implement the Dead-letter Handler** — write `dlq_handler/worker.py`. Poll the DLQ every 5 s. For each message log a JSON line to stdout and increment `dlq_messages_total` (Prometheus counter, label `reason` set to the broker's dead-letter reason string). Acknowledge (delete) the message after logging. Expose `/metrics` on port 8002. Add a `Dockerfile`.

5. **Write Terraform** — in `homeworks/module4/terraform/`, write `main.tf`, `variables.tf`, and `outputs.tf`. Provision the messaging namespace and queue (maximum delivery count = 3). Output the primary queue connection string / URL and the DLQ connection string / URL. Add a `terraform.tfvars.example` file with placeholder values and add `terraform.tfvars` to `.gitignore`. Support both Azure and AWS by using a `var.cloud_provider` variable (values `"azure"` or `"aws"`) with a `count`-based or module-based conditional. Alternatively, provide two separate provider-specific subdirectories `homeworks/module4/terraform/azure/` and `homeworks/module4/terraform/aws/`.

6. **Wire up with Docker Compose** — write `monitoring/docker-compose.yml` that starts all five services: Producer, Consumer, Dead-letter Handler, Prometheus, and Grafana. Pass the queue connection strings as environment variables read from a `.env` file (add `.env` to `.gitignore`). Mount `monitoring/prometheus.yml` as the Prometheus scrape config. Grafana should auto-provision the Prometheus data source via `monitoring/grafana/provisioning/datasources/prometheus.yml`.

7. **Configure Prometheus** — write `monitoring/prometheus.yml` that scrapes `consumer:8001/metrics` and `dlq_handler:8002/metrics` with a 15 s interval.

8. **Build the Grafana dashboard** — log in to Grafana (default `admin`/`admin`), create a dashboard with exactly three panels:
   - Panel 1 — "Queue Depth": use the broker's CloudWatch or Azure Monitor metric for approximate message count, or a Prometheus gauge you update in the Consumer (name it `queue_depth_approx`)
   - Panel 2 — "Processing Rate": `rate(orders_processed_total[1m])` visualised as a time-series graph
   - Panel 3 — "DLQ Messages": `dlq_messages_total` visualised as a stat panel
   Export the dashboard as JSON and save it to `monitoring/grafana/dashboards/order_pipeline.json`.

9. **Test poison message handling** — add a `POST /orders/poison` endpoint to the Producer that publishes a message with `"sku": null`. Verify that after three delivery attempts the message appears in the DLQ and the `dlq_messages_total` counter increments by 1. Document the test steps in a `TESTING.md` file inside `homeworks/module4/`.

10. **Tear down** — run `terraform destroy` and confirm all provisioned resources are removed. Include the console output (redacted of secrets) as `terraform_destroy.txt` in your submission.

## Acceptance criteria

- `terraform init && terraform validate` completes with no errors in both the Azure and AWS configurations (or in whichever provider the student chose, with a comment explaining the alternative)
- `terraform plan` shows exactly the resources listed in the "Cloud resources to provision" table and no others, assuming a clean target environment
- `docker compose up` starts all five services without error; `curl -s http://localhost:8000/` returns HTTP 200 or 404 (service is reachable)
- `curl -X POST http://localhost:8000/orders` with a valid JSON body returns HTTP 202 and a `message_id` field within 2 s
- `curl -X POST http://localhost:8000/orders` with a missing `quantity` field returns HTTP 422
- Within 10 s of a valid POST, the Consumer logs a line containing `"event": "order_received"` and the matching `order_id`
- `curl -s http://localhost:8001/metrics` returns a response containing the lines `orders_processed_total` and `order_processing_duration_seconds_bucket`
- `curl -s http://localhost:8002/metrics` returns a response containing `dlq_messages_total`
- After calling `POST /orders/poison` once and waiting 30 s, `curl -s http://localhost:8002/metrics` shows `dlq_messages_total` with a value >= 1
- The Grafana dashboard JSON file exists at `monitoring/grafana/dashboards/order_pipeline.json`, is valid JSON, and contains panels whose titles match exactly "Queue Depth", "Processing Rate", and "DLQ Messages"
- No credentials, connection strings, or secrets appear in any committed file; `.gitignore` excludes `.env` and `terraform.tfvars`
- `TESTING.md` documents the poison-message test with expected and actual outputs
- `terraform_destroy.txt` is present and contains the string `Destroy complete!`
