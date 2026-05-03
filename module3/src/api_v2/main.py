from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from typing import List, Dict, Any

app = FastAPI(title="Items API v2")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ITEMS: List[Dict[str, Any]] = [
    {"id": 1, "name": "Widget",    "price": 9.99,  "category": "tools"},
    {"id": 2, "name": "Gadget",    "price": 24.99, "category": "electronics"},
    {"id": 3, "name": "Doohickey", "price": 4.99,  "category": "tools"},
]


def paginated_response(
    items: List[Dict[str, Any]], page: int, page_size: int
) -> Dict[str, Any]:
    start = (page - 1) * page_size
    return {
        "_version": "v2",
        "data": items[start : start + page_size],
        "total": len(items),
        "page": page,
        "page_size": page_size,
    }


@app.get("/v2/items")
@app.get("/items")
async def get_items(
    page: int = Query(1, ge=1),
    page_size: int = Query(10, ge=1, le=100),
):
    """Returns a paginated JSON object with _version:"v2" — v2 response shape."""
    return paginated_response(ITEMS, page, page_size)


@app.get("/health")
async def health():
    return {"status": "ok", "version": "v2"}
