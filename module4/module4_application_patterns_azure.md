# Azure Implementation — Module 4: Application Patterns (Async Order Processing Pipeline)

## Azure service mapping

| Homework component | Azure service | SKU / tier | Rationale |
|---|---|---|---|
| Messaging namespace | Azure Service Bus namespace | **Standard** tier | Standard tier is the minimum that supports topics and dead-letter queues. The homework uses a queue (not a topic), so Basic would technically suffice, but Standard is recommended for the DLQ visibility features and forward-compatibility if topics are added later. |
| Primary queue | Azure Service Bus queue | `max_delivery_count = 3` | Built-in DLQ sub-queue (`$DeadLetterQueue`) is automatically created alongside every Service Bus queue. No extra resource needed. |
| Dead-letter queue | `<queue-name>/$DeadLetterQueue` sub-queue | (built-in, no extra cost) | Automatically managed by the broker. Consumers connect using the full entity path `orders/$DeadLetterQueue`. |
| Shared access policy | `azurerm_servicebus_queue_authorization_rule` | Send + Listen rights | Scoped to the queue level (not namespace level) for least privilege. One rule for the Producer (Send), one for the Consumer and DLQ Handler (Listen). |
| Container hosting (optional) | Azure Container Instances (ACI) — `azurerm_container_group` | Consumption-based | Suitable for short-lived homework runs. Each container group maps to one logical service. Alternatively, run locally with Docker Compose only. |
| Resource group | `azurerm_resource_group` | n/a | Logical boundary for all homework resources; makes `terraform destroy` a single operation. |
| Secrets storage (recommended) | Azure Key Vault — `azurerm_key_vault` + `azurerm_key_vault_secret` | Standard tier | Keep connection strings out of `.env` files. Optional for homework, but noted in the security section. |

---

## Architecture diagram (text)

```
┌─────────────────────────────────────────────────────────────────┐
│  Docker Compose (local)                                         │
│                                                                 │
│  ┌──────────────┐   POST /orders    ┌─────────────────────────┐ │
│  │   Client     │ ────────────────► │  Producer (FastAPI)     │ │
│  │  (curl/test) │                   │  port 8000              │ │
│  └──────────────┘                   └──────────┬──────────────┘ │
│                                                │ publish msg    │
│                           ┌────────────────────▼──────────────┐ │
│                           │  Azure Service Bus (Standard)     │ │
│                           │  Namespace: <prefix>-sb-ns        │ │
│                           │                                   │ │
│                           │  Queue: orders                    │ │
│                           │  ├─ max_delivery_count = 3        │ │
│                           │  └─ DLQ: orders/$DeadLetterQueue  │ │
│                           └──────┬────────────────┬───────────┘ │
│                                  │ poll           │ poll DLQ    │
│                    ┌─────────────▼───────┐  ┌────▼────────────┐ │
│                    │  Consumer           │  │  DLQ Handler    │ │
│                    │  worker.py          │  │  worker.py      │ │
│                    │  port 8001          │  │  port 8002      │ │
│                    │  /health, /metrics  │  │  /metrics       │ │
│                    └─────────────┬───────┘  └────┬────────────┘ │
│                                  │ scrape         │ scrape      │
│                    ┌─────────────▼───────────────▼────────────┐ │
│                    │  Prometheus (port 9090)                  │ │
│                    │  scrape interval: 15 s                   │ │
│                    └─────────────────────────────────────────┬┘ │
│                                                              │   │
│                    ┌─────────────────────────────────────────▼┐  │
│                    │  Grafana (port 3000)                     │  │
│                    │  dashboards: Queue Depth, Processing     │  │
│                    │  Rate, DLQ Messages                      │  │
│                    └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

Azure (Terraform-managed)
┌──────────────────────────────────────────────────┐
│  Resource Group: rg-order-pipeline-dev           │
│                                                  │
│  Service Bus Namespace (Standard)                │
│  └── Queue: orders                               │
│       ├── Authorization Rule: producer-send      │
│       └── Authorization Rule: consumer-listen    │
└──────────────────────────────────────────────────┘
```

---

## Terraform file structure

```
homeworks/module4/
└── terraform/
    └── azure/
        ├── main.tf              # Provider + resources
        ├── variables.tf         # Input variables
        ├── outputs.tf           # Connection strings, queue URLs
        ├── terraform.tfvars.example   # Placeholder values (committed)
        └── .gitignore           # Excludes terraform.tfvars, .terraform/, *.tfstate*
```

The `.gitignore` inside `terraform/azure/` should contain at minimum:

```
terraform.tfvars
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl   # optional: commit this if you want reproducible provider versions
```

---

## Terraform resource definitions

### `variables.tf`

```hcl
variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "prefix" {
  description = "Short prefix used in all resource names to avoid collisions."
  type        = string
  default     = "orderpipeline"
}

variable "environment" {
  description = "Environment label (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "servicebus_sku" {
  description = "Service Bus namespace SKU. Must be 'Standard' or 'Premium' to use dead-letter queues."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.servicebus_sku)
    error_message = "Basic SKU does not support dead-letter queues. Use Standard or Premium."
  }
}

variable "queue_max_delivery_count" {
  description = "Number of delivery attempts before the broker moves the message to the DLQ."
  type        = number
  default     = 3
}
```

### `main.tf`

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"   # Tested with 3.x; upgrade to 4.x requires reviewing breaking changes
    }
  }
  required_version = ">= 1.5"
}

provider "azurerm" {
  features {}
  # Authentication is handled via environment variables or az login.
  # For CI/CD use OIDC:
  #   use_oidc                = true
  #   ARM_CLIENT_ID           = var from GitHub secret
  #   ARM_SUBSCRIPTION_ID     = var from GitHub secret
  #   ARM_TENANT_ID           = var from GitHub secret
}

# ── Resource Group ────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = "module4-order-pipeline"
    managed_by  = "terraform"
  }
}

# ── Service Bus Namespace ─────────────────────────────────────────────────────

resource "azurerm_servicebus_namespace" "main" {
  name                = "${var.prefix}-sb-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.servicebus_sku

  # local_auth_enabled controls whether SAS-based connection strings are allowed.
  # Set to true for homework (connection-string auth); in production prefer
  # local_auth_enabled = false and use managed identity only.
  local_auth_enabled = true

  tags = azurerm_resource_group.main.tags
}

# ── Primary Orders Queue ──────────────────────────────────────────────────────

resource "azurerm_servicebus_queue" "orders" {
  name         = "orders"
  namespace_id = azurerm_servicebus_namespace.main.id

  # Broker automatically creates orders/$DeadLetterQueue alongside this queue.
  # No separate resource is needed.

  max_delivery_count = var.queue_max_delivery_count  # 3 → after 3 failed attempts, move to DLQ

  # Move messages to the DLQ when the TTL expires, not just on delivery failure.
  dead_lettering_on_message_expiration = true

  # Message TTL: 5 minutes is sufficient for homework testing; increase for production.
  default_message_ttl = "PT5M"  # ISO 8601 duration

  # Lock duration: how long a receiver holds the lock before the broker re-enqueues.
  # 30 s gives the consumer enough time to process even slow messages.
  lock_duration = "PT30S"

  # Enable duplicate detection to prevent reprocessing the same order_id twice.
  # Requires a detection history window.
  requires_duplicate_detection          = false  # Set true if idempotency is required
  # duplicate_detection_history_time_window = "PT10M"  # Uncomment if above is true

  enable_partitioning = false  # Not needed at homework scale; required for >1 GB queues
}

# ── Authorization Rule: Producer (Send only) ──────────────────────────────────

resource "azurerm_servicebus_queue_authorization_rule" "producer_send" {
  name     = "producer-send"
  queue_id = azurerm_servicebus_queue.orders.id

  send   = true
  listen = false
  manage = false
}

# ── Authorization Rule: Consumer + DLQ Handler (Listen only) ─────────────────

resource "azurerm_servicebus_queue_authorization_rule" "consumer_listen" {
  name     = "consumer-listen"
  queue_id = azurerm_servicebus_queue.orders.id

  send   = false
  listen = true
  manage = false
}

# NOTE: The DLQ handler connects to the same queue entity but uses the sub-queue
# path "orders/$DeadLetterQueue". The consumer-listen authorization rule grants
# access to both the primary queue AND its DLQ sub-queue — no second rule is needed.
```

### `outputs.tf`

```hcl
output "servicebus_namespace_name" {
  description = "Name of the Service Bus namespace."
  value       = azurerm_servicebus_namespace.main.name
}

output "producer_connection_string" {
  description = "Connection string for the Producer (Send rights on the orders queue)."
  value       = azurerm_servicebus_queue_authorization_rule.producer_send.primary_connection_string
  sensitive   = true  # Marked sensitive: will not print in plan output; use `terraform output -raw`
}

output "consumer_connection_string" {
  description = "Connection string for the Consumer and DLQ Handler (Listen rights on the orders queue)."
  value       = azurerm_servicebus_queue_authorization_rule.consumer_listen.primary_connection_string
  sensitive   = true
}

output "orders_queue_name" {
  description = "Name of the primary orders queue."
  value       = azurerm_servicebus_queue.orders.name
}

output "dlq_entity_path" {
  description = "Full entity path of the dead-letter sub-queue. Pass this to the DLQ Handler as SERVICE_BUS_DLQ_ENTITY_PATH."
  value       = "${azurerm_servicebus_queue.orders.name}/$DeadLetterQueue"
}

output "resource_group_name" {
  description = "Resource group containing all provisioned resources."
  value       = azurerm_resource_group.main.name
}
```

### `terraform.tfvars.example`

```hcl
# Copy this file to terraform.tfvars and fill in your values.
# Do NOT commit terraform.tfvars — it is excluded by .gitignore.

location    = "westeurope"
prefix      = "orderpipeline"     # Must be globally unique in the namespace name
environment = "dev"
```

---

## Deployment walkthrough

### 1. Authenticate to Azure

```bash
# Interactive login (developer workstation)
az login
az account set --subscription "<your-subscription-id>"

# Verify the active account
az account show --query "{name:name, id:id}"
```

### 2. Initialise and validate Terraform

```bash
cd homeworks/module4/terraform/azure

# Install provider plugins
terraform init

# Validate syntax and provider schema
terraform validate
# Expected: "Success! The configuration is valid."

# Copy example vars and edit
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set prefix to something unique (e.g. your initials + "orderpipeline")
```

### 3. Plan and apply

```bash
# Preview what will be created (should list exactly 5 resources)
terraform plan

# Expected resources:
#   azurerm_resource_group.main
#   azurerm_servicebus_namespace.main
#   azurerm_servicebus_queue.orders
#   azurerm_servicebus_queue_authorization_rule.producer_send
#   azurerm_servicebus_queue_authorization_rule.consumer_listen

# Apply (creates resources; ~2 min)
terraform apply
# Type "yes" when prompted
```

### 4. Export connection strings to `.env`

```bash
# Read sensitive outputs (never printed automatically)
terraform output -raw producer_connection_string
terraform output -raw consumer_connection_string
terraform output -raw dlq_entity_path
```

Create `homeworks/module4/monitoring/.env` (git-ignored):

```dotenv
# Producer
SERVICE_BUS_PRODUCER_CONNECTION_STRING="Endpoint=sb://...your string..."
SERVICE_BUS_QUEUE_NAME=orders

# Consumer
SERVICE_BUS_CONSUMER_CONNECTION_STRING="Endpoint=sb://...your string..."

# DLQ Handler
SERVICE_BUS_DLQ_CONNECTION_STRING="Endpoint=sb://...your string..."
SERVICE_BUS_DLQ_ENTITY_PATH=orders/$DeadLetterQueue
```

> ⚠️ NEEDS USER INPUT: The Azure Service Bus SDK for Python (`azure-servicebus`) uses the connection string directly. Confirm whether the Consumer should use `ServiceBusClient.from_connection_string()` or a managed identity credential (`DefaultAzureCredential`). The Terraform above outputs SAS connection strings; the managed-identity path requires additional `azurerm_role_assignment` resources (see Security section).

### 5. Start all services with Docker Compose

```bash
cd homeworks/module4/monitoring
docker compose up --build
```

Expected startup sequence:

1. Prometheus starts, waits for scrape targets.
2. Grafana starts, auto-provisions the Prometheus data source.
3. Producer starts on port 8000.
4. Consumer starts on port 8001 — begins polling the `orders` queue.
5. DLQ Handler starts on port 8002 — begins polling `orders/$DeadLetterQueue`.

### 6. Submit a test order (happy path)

```bash
curl -s -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"order_id":"ord-001","sku":"WIDGET-42","quantity":2,"email":"test@example.com"}' \
  | jq .
# Expected: {"message_id": "<guid>"}  HTTP 202
```

Within ~10 s, check Consumer logs:

```bash
docker compose logs consumer | grep ord-001
# Expected line: {"event": "order_received", "order_id": "ord-001"}
```

### 7. Trigger and observe the dead-letter path

```bash
# Use the /orders/poison endpoint (sku is null → Consumer raises ValueError → no ack)
curl -s -X POST http://localhost:8000/orders/poison \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
```

Wait ~30 s (3 delivery attempts × up to 10 s lock expiry). Then:

```bash
# Check DLQ Handler logs
docker compose logs dlq_handler
# Expected: {"event": "dlq_received", "order_id": "...", "reason": "MaxDeliveryCountExceeded"}

# Check Prometheus counter
curl -s http://localhost:8002/metrics | grep dlq_messages_total
# Expected: dlq_messages_total{reason="MaxDeliveryCountExceeded"} 1.0
```

> ❓ OPEN QUESTION: The homework spec says the Consumer should NOT acknowledge on failure and lets the broker retry. Azure Service Bus uses a **peek-lock** model: the Consumer must call `receiver.abandon_message(msg)` (or let the lock expire) to trigger a retry. If the Consumer simply does not call `complete_message()`, the lock expires after `lock_duration` (set to 30 s above) and the broker re-enqueues. This means the effective retry cadence is controlled by `lock_duration`, not by an application-level back-off timer. Should the Consumer explicitly call `abandon_message()` with immediate re-enqueue, or rely on lock expiry? Explicit `abandon_message()` is faster and cleaner — recommend clarifying this in `TESTING.md`.

### 8. Tear down

```bash
cd homeworks/module4/terraform/azure
terraform destroy
# Type "yes" when prompted
# Expected final line: "Destroy complete! Resources: 5 destroyed."
```

Save the console output (with secrets redacted) as `homeworks/module4/terraform_destroy.txt`.

---

## Testing strategy

### Happy path

```
POST /orders  →  202 + message_id
Consumer log  →  {"event": "order_received", "order_id": "<id>"}
/metrics      →  orders_processed_total increments by 1
```

```bash
# Automated check
ORDER_ID="ord-$(date +%s)"
curl -s -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d "{\"order_id\":\"$ORDER_ID\",\"sku\":\"WIDGET-1\",\"quantity\":1,\"email\":\"a@b.com\"}"
sleep 15
curl -s http://localhost:8001/metrics | grep orders_processed_total
```

### Validation error (HTTP 422)

```bash
curl -s -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"order_id":"x","sku":"y","email":"not-valid@x.com"}'
  # quantity field is missing
# Expected: HTTP 422 Unprocessable Entity
```

### Poison message / DLQ path

```bash
curl -s -X POST http://localhost:8000/orders/poison -H "Content-Type: application/json" -d '{}'
sleep 30  # allow 3 lock-expiry cycles (3 × 10 s with room to spare)
COUNTER=$(curl -s http://localhost:8002/metrics | grep '^dlq_messages_total' | awk '{print $2}')
echo "DLQ counter: $COUNTER"   # Expected >= 1
```

### Prometheus scrape check

```bash
curl -s http://localhost:8001/metrics | grep -E "orders_processed_total|order_processing_duration_seconds_bucket"
curl -s http://localhost:8002/metrics | grep dlq_messages_total
```

Both commands must return at least one matching line for the acceptance criteria to pass.

### Grafana dashboard verification

1. Open `http://localhost:3000` (admin / admin).
2. Navigate to Dashboards → order_pipeline.
3. Confirm exactly three panels exist with titles: **"Queue Depth"**, **"Processing Rate"**, **"DLQ Messages"**.
4. Verify that "Processing Rate" shows a non-zero value after sending a valid order.
5. Export the dashboard JSON: Dashboard settings → JSON Model → Copy to clipboard → save to `monitoring/grafana/dashboards/order_pipeline.json`.

Validate the JSON file programmatically:

```bash
python3 -c "
import json, sys
with open('monitoring/grafana/dashboards/order_pipeline.json') as f:
    d = json.load(f)
titles = {p['title'] for p in d.get('panels', [])}
required = {'Queue Depth', 'Processing Rate', 'DLQ Messages'}
missing = required - titles
if missing:
    print('MISSING PANELS:', missing); sys.exit(1)
print('OK — all required panels found')
"
```

---

## Security and architecture notes

### Managed identity vs. SAS connection strings

The Terraform above outputs **SAS-based connection strings** for simplicity in a homework context. For any environment beyond local development, replace SAS keys with managed identity:

1. Remove `local_auth_enabled = true` from the namespace (or set it to `false`).
2. Add an `azurerm_role_assignment` for each workload identity:

```hcl
# Producer needs to send messages
resource "azurerm_role_assignment" "producer_sender" {
  scope                = azurerm_servicebus_queue.orders.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = "<managed-identity-or-service-principal-object-id>"
}

# Consumer and DLQ Handler need to receive messages
resource "azurerm_role_assignment" "consumer_receiver" {
  scope                = azurerm_servicebus_queue.orders.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = "<managed-identity-or-service-principal-object-id>"
}
```

3. In Python, replace `ServiceBusClient.from_connection_string(...)` with:

```python
from azure.identity import DefaultAzureCredential
from azure.servicebus import ServiceBusClient

credential = DefaultAzureCredential()
client = ServiceBusClient(
    fully_qualified_namespace="<namespace>.servicebus.windows.net",
    credential=credential,
)
```

> ⚠️ NEEDS USER INPUT: Managed identity is only available when containers run on Azure (ACI, AKS, App Service). For local Docker Compose development, `DefaultAzureCredential` falls back to `az login` credentials — this requires `azure-identity` and the developer to be logged in. Confirm whether the homework expects SAS strings (simpler) or managed identity (more realistic). The guide above supports both; just switch the Python credential instantiation.

### RBAC roles for Service Bus (built-in)

| Role | Purpose |
|---|---|
| `Azure Service Bus Data Sender` | Send messages to a queue or topic |
| `Azure Service Bus Data Receiver` | Receive and complete/abandon/dead-letter messages |
| `Azure Service Bus Data Owner` | Full control (use only for admin scripts, not application identities) |

### Secret management

- **Connection strings in `.env`**: acceptable for homework only. `.env` must be in `.gitignore`.
- **Key Vault** (optional improvement): store the connection string as a Key Vault secret and read it at container startup via the Key Vault references feature in ACI or App Service.
- **Never** hardcode connection strings in `main.tf`, `docker-compose.yml`, or application source files.

### Azure Well-Architected Framework notes

| Pillar | Note |
|---|---|
| **Reliability** | `max_delivery_count = 3` protects against runaway retry storms. Consider setting `default_message_ttl` to a value that reflects your SLA (5 minutes is fine for homework). |
| **Security** | Scope authorization rules to the queue level, not the namespace level. Use Send-only keys for the Producer so a compromised Producer cannot read messages. |
| **Cost optimization** | Service Bus Standard tier is billed per operation (first 10 million operations/month free). For homework volume (< 1000 messages), cost is effectively zero. Destroy resources after each session. |
| **Operational excellence** | All resources are tagged (`environment`, `project`, `managed_by`). This enables cost filtering in Azure Cost Management and makes `terraform destroy` safe to run against a specific environment tag. |
| **Performance efficiency** | `enable_partitioning = false` is correct at homework scale. If the queue needs to handle >1 GB of messages or requires higher throughput, partitioning must be enabled at creation time (cannot be changed later). |

---

## Known limitations and open questions

1. **Queue depth metric in Grafana**: The homework spec requires a "Queue Depth" panel. Azure Monitor exposes `ActiveMessages` for a Service Bus queue, but scraping Azure Monitor from Prometheus requires either the [azure-metrics-exporter](https://github.com/webdevops/azure-metrics-exporter) sidecar or a custom gauge updated by the Consumer. The spec suggests a `queue_depth_approx` Prometheus gauge updated by the Consumer — this is the simplest approach for homework but requires the Consumer to periodically query the Service Bus management API for queue metadata.

   > ❓ OPEN QUESTION: Should the Consumer update `queue_depth_approx` by calling the Service Bus management API (requires `azure-mgmt-servicebus` SDK and additional RBAC), or should the panel be left as a placeholder with a note that full Azure Monitor integration is out of scope for this homework?

2. **DLQ connection string**: The Consumer and DLQ Handler both use the `consumer_listen` authorization rule. However, the entity path for the DLQ is `orders/$DeadLetterQueue`. Ensure the Python SDK call uses this full path:

   ```python
   receiver = client.get_queue_receiver(queue_name="orders/$DeadLetterQueue")
   ```

   Verify this works with the `azure-servicebus` Python SDK version in use — some versions require the sub-queue to be passed as a separate `sub_queue` parameter.

   > ⚠️ NEEDS USER INPUT: Confirm the exact Python SDK call for receiving from the DLQ sub-queue in `azure-servicebus >= 7.0`. The parameter is `ServiceBusClient.get_queue_receiver(queue_name="orders", sub_queue=ServiceBusSubQueue.DEAD_LETTER)` in SDK 7.x — verify this against the SDK version pinned in `requirements.txt`.

3. **Service Bus namespace name uniqueness**: The name `${var.prefix}-sb-${var.environment}` must be globally unique across all Azure subscriptions (it forms a DNS hostname: `<name>.servicebus.windows.net`). If `terraform apply` fails with a name conflict, change `prefix` in `terraform.tfvars`.

4. **Local Docker Compose vs. ACI**: The Terraform only provisions the Service Bus infrastructure. Running the five containers (Producer, Consumer, DLQ Handler, Prometheus, Grafana) locally with Docker Compose is the primary delivery mode. The ACI option in the service mapping table is listed as "optional" and is not wired up in the Terraform above. If ACI deployment is required, add `azurerm_container_group` resources for each service and pass the connection string outputs as secure environment variables.

   > ❓ OPEN QUESTION: The homework spec marks container hosting as "(optional)". Should a complete ACI configuration be provided, or is Docker Compose sufficient for full marks?

5. **`terraform plan` resource count**: The acceptance criterion states that `terraform plan` should show "exactly the resources listed in the Cloud resources to provision table and no others." The Terraform above creates 5 resources (resource group, namespace, queue, 2 authorization rules). If Key Vault is added for secret storage, that count increases. Stick to the 5-resource plan unless the instructor explicitly allows Key Vault.

6. **Retry behaviour and lock expiry**: With `lock_duration = "PT30S"` and `max_delivery_count = 3`, the worst-case time before a message reaches the DLQ is ~90 seconds (3 lock expiry cycles). The acceptance criterion requires the DLQ counter to increment within 30 seconds of calling `POST /orders/poison`. To satisfy this, either reduce `lock_duration` (e.g., `"PT10S"`) or have the Consumer explicitly call `abandon_message()` after each failure rather than waiting for lock expiry.

   > ❓ OPEN QUESTION: Should `lock_duration` be reduced from 30 s to 10 s in the Terraform to meet the 30 s acceptance criterion? This change affects how long a real Consumer has to process a message before the broker retries, which is a reliability trade-off.
