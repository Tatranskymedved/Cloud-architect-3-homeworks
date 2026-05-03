"""DLQ Handler worker — drains the orders dead-letter queue.

Metrics exposed on :8002/metrics (Prometheus text format).
"""

import json
import os
import threading
import time

import uvicorn
from azure.servicebus import ServiceBusClient, ServiceBusSubQueue
from fastapi import FastAPI
from prometheus_client import Counter, make_asgi_app

CONNECTION_STRING = os.environ["SERVICE_BUS_CONNECTION_STRING"]
QUEUE_NAME = os.environ.get("SERVICE_BUS_QUEUE_NAME", "orders")

# ── Prometheus metrics ────────────────────────────────────────────────────────

dlq_messages_total = Counter(
    "dlq_messages_total",
    "Number of messages received from the dead-letter queue",
    ["reason"],
)

# ── HTTP app (metrics only) ───────────────────────────────────────────────────

http_app = FastAPI(title="DLQ Handler metrics")
http_app.mount("/metrics", make_asgi_app())


# ── Message body decoder ──────────────────────────────────────────────────────

def _decode_body(msg) -> str:
    raw = msg.body
    if isinstance(raw, (bytes, bytearray)):
        return raw.decode("utf-8")
    if isinstance(raw, str):
        return raw
    return b"".join(raw).decode("utf-8")


# ── DLQ polling loop ──────────────────────────────────────────────────────────

def _poll_loop():
    while True:
        try:
            with ServiceBusClient.from_connection_string(CONNECTION_STRING) as client:
                with client.get_queue_receiver(
                    QUEUE_NAME,
                    sub_queue=ServiceBusSubQueue.DEAD_LETTER,
                ) as receiver:
                    while True:
                        messages = receiver.receive_messages(max_message_count=1, max_wait_time=5)
                        for msg in messages:
                            try:
                                receiver.renew_message_lock(msg)
                            except Exception as exc:
                                print(json.dumps({"event": "dlq_lock_renew_error", "error": str(exc)}), flush=True)
                                continue
                            reason = "Unknown"
                            try:
                                if msg.dead_letter_reason:
                                    reason = msg.dead_letter_reason
                                elif msg.application_properties:
                                    reason = msg.application_properties.get(
                                        b"DeadLetterReason", b"Unknown"
                                    ).decode()
                            except Exception:
                                pass

                            order_id = "unknown"
                            try:
                                body = json.loads(_decode_body(msg))
                                order_id = body.get("order_id", "unknown")
                            except Exception:
                                pass

                            print(
                                json.dumps({"event": "dlq_received", "order_id": order_id, "reason": reason}),
                                flush=True,
                            )

                            try:
                                dlq_messages_total.labels(reason=reason).inc()
                                receiver.complete_message(msg)
                            except Exception as exc:
                                print(json.dumps({"event": "dlq_settlement_error", "error": str(exc)}), flush=True)
        except Exception as exc:
            print(json.dumps({"event": "dlq_receiver_error", "error": str(exc)}), flush=True)
            time.sleep(5)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    threading.Thread(target=_poll_loop, daemon=True).start()
    uvicorn.run(http_app, host="0.0.0.0", port=8002, log_level="warning")
