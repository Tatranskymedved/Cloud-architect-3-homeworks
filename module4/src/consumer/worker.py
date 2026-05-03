"""Consumer worker — polls the orders queue and processes messages.

Metrics exposed on :8001/metrics (Prometheus text format).
Health check available at :8001/health.
"""

import datetime
import json
import os
import random
import threading
import time

import uvicorn
from azure.servicebus import ServiceBusClient
from fastapi import FastAPI
from prometheus_client import Counter, Gauge, Histogram, make_asgi_app

CONNECTION_STRING = os.environ["SERVICE_BUS_CONNECTION_STRING"]
QUEUE_NAME = os.environ.get("SERVICE_BUS_QUEUE_NAME", "orders")

# ── Prometheus metrics ────────────────────────────────────────────────────────

orders_processed = Counter(
    "orders_processed_total",
    "Number of orders successfully processed",
)
processing_duration = Histogram(
    "order_processing_duration_seconds",
    "Time spent processing a single order message",
    buckets=[0.05, 0.1, 0.2, 0.5, 1.0],
)
queue_depth = Gauge(
    "queue_depth_approx",
    "Approximate number of active messages in the orders queue (sampled via peek)",
)

# ── HTTP app (health + metrics) ───────────────────────────────────────────────

http_app = FastAPI(title="Consumer metrics")
http_app.mount("/metrics", make_asgi_app())


@http_app.get("/health")
def health():
    return {"status": "ok"}


# ── Queue-depth sampler ───────────────────────────────────────────────────────

def _sample_queue_depth():
    while True:
        try:
            with ServiceBusClient.from_connection_string(CONNECTION_STRING) as client:
                with client.get_queue_receiver(QUEUE_NAME) as receiver:
                    msgs = receiver.peek_messages(max_message_count=100)
                    queue_depth.set(len(msgs))
        except Exception:
            pass
        time.sleep(15)


# ── Message processing ────────────────────────────────────────────────────────

def _decode_body(msg) -> str:
    """Return the message body as a str regardless of how the SDK wraps it."""
    raw = msg.body
    if isinstance(raw, (bytes, bytearray)):
        return raw.decode("utf-8")
    if isinstance(raw, str):
        return raw
    # Generator of bytes chunks (AMQP DATA sections)
    return b"".join(raw).decode("utf-8")


def _process(body: dict) -> None:
    sku = body.get("sku")
    if sku is None:
        raise ValueError(f"sku is null for order_id={body.get('order_id')}")
    print(json.dumps({"event": "order_received", "order_id": body.get("order_id")}), flush=True)
    time.sleep(random.uniform(0.05, 0.2))


def _poll_loop():
    while True:
        try:
            with ServiceBusClient.from_connection_string(CONNECTION_STRING) as client:
                with client.get_queue_receiver(QUEUE_NAME) as receiver:
                    while True:
                        messages = receiver.receive_messages(max_message_count=1, max_wait_time=5)
                        for msg in messages:
                            # Renew immediately: the AMQP link can lock the message
                            # during receiver setup (before receive_messages() returns),
                            # leaving locked_until_utc stale or expired by the time
                            # application code runs. renew_message_lock() bypasses the
                            # local clock check and resets the expiry from the broker.
                            try:
                                _now = datetime.datetime.now(datetime.timezone.utc)
                                print(json.dumps({
                                    "event": "lock_debug_before",
                                    "locked_until_utc": str(msg.locked_until_utc),
                                    "container_now_utc": str(_now),
                                    "remaining_s": round((msg.locked_until_utc - _now).total_seconds(), 2) if msg.locked_until_utc else None,
                                    "delivery_count": msg.delivery_count,
                                }), flush=True)
                                receiver.renew_message_lock(msg)
                                _now = datetime.datetime.now(datetime.timezone.utc)
                                print(json.dumps({
                                    "event": "lock_debug_after",
                                    "locked_until_utc": str(msg.locked_until_utc),
                                    "container_now_utc": str(_now),
                                    "remaining_s": round((msg.locked_until_utc - _now).total_seconds(), 2) if msg.locked_until_utc else None,
                                    "delivery_count": msg.delivery_count,
                                }), flush=True)
                            except Exception as exc:
                                print(json.dumps({"event": "lock_renew_error", "error": str(exc)}), flush=True)
                                continue  # genuinely expired server-side; skip, will be re-queued
                            start = time.monotonic()
                            processing_ok = False
                            try:
                                body = json.loads(_decode_body(msg))
                                _process(body)
                                processing_ok = True
                            except Exception as exc:
                                print(json.dumps({"event": "processing_error", "error": str(exc)}), flush=True)

                            try:
                                if processing_ok:
                                    receiver.complete_message(msg)
                                    orders_processed.inc()
                                    processing_duration.observe(time.monotonic() - start)
                                else:
                                    receiver.abandon_message(msg)
                            except Exception as exc:
                                print(json.dumps({"event": "settlement_error", "error": str(exc)}), flush=True)
        except Exception as exc:
            print(json.dumps({"event": "receiver_error", "error": str(exc)}), flush=True)
            time.sleep(5)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    threading.Thread(target=_sample_queue_depth, daemon=True).start()
    threading.Thread(target=_poll_loop, daemon=True).start()
    uvicorn.run(http_app, host="0.0.0.0", port=8001, log_level="warning")
