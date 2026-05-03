# Module 4 — Async Order Processing Pipeline (Azure)

Implements a three-service order processing pipeline on Azure Service Bus with Prometheus + Grafana monitoring.

```
Client → Producer (FastAPI :8000)
            │ publish
            ▼
    Azure Service Bus
    Queue: orders  (max_delivery_count=3)
    └── DLQ: orders/$DeadLetterQueue
            │                │
            ▼                ▼
    Consumer (:8001)   DLQ Handler (:8002)
            │                │
            └────────────────┘
                   scrape
                     ▼
             Prometheus (:9090)
                     │
                   query
                     ▼
              Grafana (:3000)
```

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Azure CLI (`az`) | 2.50 |
| Terraform | 1.5 |
| Docker + Docker Compose | Docker 24 |
| Python | 3.10 (for test scripts) |

---

## Part 1 — Provision Azure infrastructure

### 1. Authenticate

```powershell
az login
az account set --subscription "<your-subscription-id>"
az account show --query "{name:name, id:id}"
```

### 2. Initialise Terraform

```powershell
cd homeworks\module4\terraform_az
terraform init
terraform validate
# Expected: "Success! The configuration is valid."
```

### 3. Configure variables

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — change `prefix` to something globally unique (the Service Bus namespace name must be unique across all Azure subscriptions):

```hcl
location    = "westeurope"
prefix      = "juorders"   # your initials + "orders" works well
environment = "dev"
```

### 4. Plan and apply

```powershell
terraform plan
# Expected: 5 resources to add
#   azurerm_resource_group.main
#   azurerm_servicebus_namespace.main
#   azurerm_servicebus_queue.orders
#   azurerm_servicebus_queue_authorization_rule.producer_send
#   azurerm_servicebus_queue_authorization_rule.consumer_listen

terraform apply
# Type "yes" when prompted (~2 min)
```

### 5. Export connection strings

```powershell
terraform output -raw producer_connection_string
terraform output -raw consumer_connection_string
```

---

## Part 2 — Configure the application

```powershell
cd ..\monitoring
Copy-Item .env.example .env
```

Open `.env` and paste the connection strings (replace `<CHANGE_ME>` part) from the previous step:

```dotenv
SERVICE_BUS_PRODUCER_CONNECTION_STRING="Endpoint=sb://...your string..."
SERVICE_BUS_CONSUMER_CONNECTION_STRING="Endpoint=sb://...your string..."
SERVICE_BUS_QUEUE_NAME=orders
```

**Never commit `.env` — it is git-ignored.**

---

## Part 3 — Start all services

```powershell
# From homeworks\module4\monitoring\
docker compose up --build
```

Expected startup order:
1. Prometheus starts
2. Grafana starts (auto-provisions the Prometheus data source and the dashboard)
3. Producer starts on port 8000
4. Consumer starts on port 8001 — begins polling `orders`
5. DLQ Handler starts on port 8002 — begins polling `orders/$DeadLetterQueue`

Verify services are reachable:

```powershell
curl.exe -s http://localhost:8000/        # {"service":"producer","status":"ok"}
curl.exe -s http://localhost:8001/health  # {"status":"ok"}
```

---

## Part 4 — Test

See [TESTING.md](TESTING.md) for full test scenarios including:

- Happy path (valid order → Consumer processes → metrics increment)
- Validation error (missing field → HTTP 422)
- Poison message (null SKU → 3 retries → DLQ → counter increments)

Quick smoke test:

```powershell
# Send a valid order (Invoke-RestMethod handles JSON bodies reliably in PowerShell)
Invoke-RestMethod -Method POST -Uri http://localhost:8000/orders `
  -ContentType "application/json" `
  -Body '{"order_id":"test-1","sku":"WIDGET-1","quantity":1,"email":"test@example.com"}'
# Expected: message_id = <guid>

# Wait and check Consumer processed it
Start-Sleep -Seconds 15
curl.exe -s http://localhost:8001/metrics | Select-String "orders_processed_total"
```

---

## Part 5 — Grafana dashboard

Open `http://localhost:3000` (admin / admin) → Dashboards → **order_pipeline**.

Three panels:

| Panel | Metric | Type |
|---|---|---|
| Queue Depth | `queue_depth_approx` | Stat (sampled via peek every 15 s) |
| Processing Rate | `rate(orders_processed_total[1m])` | Time series |
| DLQ Messages | `sum(dlq_messages_total)` | Stat |

---

## Part 6 — Tear down

```powershell
# Stop containers
cd homeworks\module4\monitoring
docker compose down

# Destroy Azure resources
cd ..\terraform_az
terraform destroy
# Type "yes" when prompted
# Expected: "Destroy complete! Resources: 5 destroyed."
```

Save the destroy output (secrets redacted) to `terraform_destroy.txt`.

---

## File structure

```
homeworks/module4/
├── src/
│   ├── producer/          FastAPI — POST /orders, POST /orders/poison
│   ├── consumer/          Service Bus worker + Prometheus metrics (:8001)
│   └── dlq_handler/       DLQ worker + Prometheus metrics (:8002)
├── monitoring/
│   ├── docker-compose.yml All five services
│   ├── prometheus.yml     Scrape config (15 s interval)
│   └── grafana/           Dashboard + data source provisioning
├── terraform_az/          Azure Service Bus infrastructure (5 resources)
├── TESTING.md             Test scenarios and expected outputs
└── README.md              This file
```
