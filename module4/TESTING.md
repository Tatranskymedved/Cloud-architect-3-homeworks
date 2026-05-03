# Testing Guide — Module 4: Async Order Processing Pipeline

All tests run against the local Docker Compose stack (`monitoring/`).
Start the stack first:

```powershell
cd homeworks\module4\monitoring
docker compose up --build -d
```

---

## 1. Happy path — valid order

**Send a valid order:**

```powershell
Invoke-RestMethod -Method POST -Uri http://localhost:8000/orders `
  -ContentType "application/json" `
  -Body '{"order_id":"ord-001","sku":"WIDGET-42","quantity":2,"email":"test@example.com"}'
```

**Expected response (HTTP 202):**
```json
{"message_id": "<some-uuid>"}
```

**Within ~10 s, verify Consumer log:**

```powershell
docker compose logs consumer | Select-String "ord-001"
```

Expected output line:
```
{"event": "order_received", "order_id": "ord-001"}
```

**Verify Prometheus counter incremented:**

```powershell
curl.exe -s http://localhost:8001/metrics/ | Select-String "orders_processed_total"
```

Expected: at least `orders_processed_total 1.0`

---

## 2. Validation error — missing field

```powershell
try {
  Invoke-RestMethod -Method POST -Uri http://localhost:8000/orders `
    -ContentType "application/json" `
    -Body '{"order_id":"x","sku":"y","email":"valid@example.com"}'
} catch {
  $_.Exception.Response.StatusCode.value__
}
```

**Expected:** `422` (quantity field is missing)

---

## 3. Poison message — DLQ routing

### What happens

1. Producer publishes a message with `"sku": null`.
2. Consumer calls `_process()` which raises `ValueError` because `sku is None`.
3. Consumer calls `abandon_message()` — the broker immediately re-enqueues and increments the delivery counter.
4. After 3 failed deliveries (`max_delivery_count = 3`), the broker moves the message to `orders/$DeadLetterQueue`.
5. DLQ Handler receives it, logs the event, and increments `dlq_messages_total`.

### Steps

```powershell
# Step 1: send the poison message
Invoke-RestMethod -Method POST -Uri http://localhost:8000/orders/poison `
  -ContentType "application/json" -Body '{}'
```

Expected response: `{"message_id": "<uuid>"}` HTTP 202.

```powershell
# Step 2: wait ~30 s — consumer calls abandon_message() immediately on null SKU,
# so retries happen in seconds regardless of lock_duration
Start-Sleep -Seconds 30
```

```powershell
# Step 3: check DLQ Handler logs
docker compose logs dlq_handler
```

Expected log line:
```json
{"event": "dlq_received", "order_id": "poison-test", "reason": "MaxDeliveryCountExceeded"}
```

```powershell
# Step 4: confirm Prometheus counter
curl.exe -s http://localhost:8002/metrics/ | Select-String "dlq_messages_total"
```

Expected: `dlq_messages_total{reason="MaxDeliveryCountExceeded"} 1.0`

### Why the message reaches the DLQ

- `max_delivery_count = 3` is set in Terraform on `azurerm_servicebus_queue.orders`.
- `lock_duration = "PT5M"` — generous headroom for WSL2/Docker clock drift. The DLQ test still runs fast because `abandon_message()` re-queues immediately.
- The DLQ is the built-in `orders/$DeadLetterQueue` sub-queue; no separate Azure resource is needed.

---

## 4. Metrics endpoint checks

```powershell
# Consumer metrics
curl.exe -s http://localhost:8001/metrics/ | Select-String "orders_processed_total|order_processing_duration_seconds_bucket"

# DLQ Handler metrics
curl.exe -s http://localhost:8002/metrics/ | Select-String "dlq_messages_total"
```

Both must return at least one matching line.

---

## 5. Grafana dashboard verification

1. Open `http://localhost:3000` (admin / admin).
2. Go to **Dashboards** → **order_pipeline**.
3. Confirm three panels exist: **Queue Depth**, **Processing Rate**, **DLQ Messages**.
4. Verify "Processing Rate" shows a non-zero value after sending a valid order.

**Automated panel-title validation:**

```powershell
$script = @'
import json, sys
with open("monitoring/grafana/dashboards/order_pipeline.json") as f:
    d = json.load(f)
titles = {p["title"] for p in d.get("panels", [])}
required = {"Queue Depth", "Processing Rate", "DLQ Messages"}
missing = required - titles
if missing:
    print("MISSING PANELS:", missing); sys.exit(1)
print("OK - all required panels found")
'@
$script | python
```

---

## Cleanup

```powershell
docker compose down
cd ..\terraform_az
terraform destroy
```

Save the `terraform destroy` output (redacted) to `terraform_destroy.txt`.
