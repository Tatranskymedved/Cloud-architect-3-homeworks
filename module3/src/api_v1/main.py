from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from typing import List, Dict, Any

app = FastAPI(title="Items API v1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ITEMS: List[Dict[str, Any]] = [
    {"id": 1, "name": "Widget",     "price": 9.99},
    {"id": 2, "name": "Gadget",     "price": 24.99},
    {"id": 3, "name": "Doohickey",  "price": 4.99},
]


@app.get("/v1/items", response_model=List[Dict[str, Any]])
@app.get("/items",    response_model=List[Dict[str, Any]])
async def get_items():
    """Returns a flat JSON array — v1 response shape."""
    return ITEMS


@app.get("/health")
async def health():
    return {"status": "ok", "version": "v1"}
