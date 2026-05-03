import json
import os

from azure.servicebus import ServiceBusClient, ServiceBusMessage
from fastapi import FastAPI
from pydantic import BaseModel, EmailStr, field_validator
from starlette.responses import JSONResponse

app = FastAPI(title="Order Producer")

_CONNECTION_STRING = os.environ["SERVICE_BUS_CONNECTION_STRING"]
_QUEUE_NAME = os.environ.get("SERVICE_BUS_QUEUE_NAME", "orders")


class OrderRequest(BaseModel):
    order_id: str
    sku: str
    quantity: int
    email: EmailStr

    @field_validator("quantity")
    @classmethod
    def quantity_positive(cls, v: int) -> int:
        if v < 1:
            raise ValueError("quantity must be >= 1")
        return v


def _send(payload: dict) -> str:
    with ServiceBusClient.from_connection_string(_CONNECTION_STRING) as client:
        with client.get_queue_sender(_QUEUE_NAME) as sender:
            msg = ServiceBusMessage(json.dumps(payload))
            sender.send_messages(msg)
            return str(msg.message_id)


@app.get("/")
def root():
    return {"service": "producer", "status": "ok"}


@app.post("/orders", status_code=202)
def create_order(order: OrderRequest):
    message_id = _send(order.model_dump())
    return JSONResponse(status_code=202, content={"message_id": message_id})


@app.post("/orders/poison", status_code=202)
def create_poison_order():
    """Publishes a message with sku=null to trigger Consumer failure and DLQ routing."""
    message_id = _send({"order_id": "poison-test", "sku": None, "quantity": 1, "email": "poison@test.com"})
    return JSONResponse(status_code=202, content={"message_id": message_id})
