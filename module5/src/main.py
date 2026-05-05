"""
Product Catalog API — Module 5 homework (Azure)

Three-tier storage stack:
  1. Redis cache (cache-aside, TTL 60 s) — checked first on every GET
  2. PostgreSQL read replica — fallback for cache misses and all SELECT queries
  3. PostgreSQL primary — all INSERT / UPDATE / DELETE statements
  4. Azure Blob Storage — images/{id}.jpg and datasheets/{id}.pdf served via SAS tokens

Environment variables (see .env.example):
  PG_PRIMARY_HOST, PG_REPLICA_HOST, PG_USER, PG_PASSWORD, PG_DB, PG_SSLMODE
  REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
  AZURE_STORAGE_ACCOUNT, AZURE_STORAGE_KEY
"""

import decimal
import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg
import redis.asyncio as aioredis
from azure.storage.blob import BlobSasPermissions, BlobServiceClient, generate_blob_sas
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ── Configuration ──────────────────────────────────────────────────────────────

PG_PRIMARY_HOST = os.environ["PG_PRIMARY_HOST"]
PG_REPLICA_HOST = os.environ["PG_REPLICA_HOST"]
PG_USER = os.environ["PG_USER"]
PG_PASSWORD = os.environ["PG_PASSWORD"]
PG_DB = os.environ.get("PG_DB", "catalog")
PG_SSLMODE = os.environ.get("PG_SSLMODE", "require")
PG_PORT = int(os.environ.get("PG_PORT", "5432"))

REDIS_HOST = os.environ.get("REDIS_HOST")          # optional — omit to disable cache
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6380"))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
REDIS_TLS = os.environ.get("REDIS_TLS", "true").lower() == "true"

AZURE_STORAGE_ACCOUNT = os.environ["AZURE_STORAGE_ACCOUNT"]
AZURE_STORAGE_KEY = os.environ["AZURE_STORAGE_KEY"]

CACHE_TTL = 60  # seconds
SAS_EXPIRY_MINUTES = 15

# ── Connection pools ───────────────────────────────────────────────────────────

_primary_pool: Optional[asyncpg.Pool] = None
_replica_pool: Optional[asyncpg.Pool] = None
_redis: Optional[aioredis.Redis] = None


@retry(
    retry=retry_if_exception_type((OSError, asyncpg.PostgresConnectionError)),
    wait=wait_exponential(multiplier=2, min=2, max=32),
    stop=stop_after_attempt(5),
    reraise=True,
)
async def _create_pool(host: str) -> asyncpg.Pool:
    import asyncio, socket, ssl

    # ── Debug: confirm the exact host value and test DNS from asyncio context ──
    log.info("DEBUG _create_pool: host=%r port=%r user=%r db=%r sslmode=%r",
             host, PG_PORT, PG_USER, PG_DB, PG_SSLMODE)
    loop = asyncio.get_running_loop()
    try:
        addrs = await loop.getaddrinfo(host, PG_PORT,
                                       family=socket.AF_UNSPEC,
                                       type=socket.SOCK_STREAM)
        log.info("DEBUG DNS OK: %r", addrs[0] if addrs else "empty")
    except Exception as dns_err:
        log.error("DEBUG DNS FAILED: host=%r error=%r", host, dns_err)

    # Use explicit kwargs instead of a DSN string to avoid URL-encoding issues
    # with special characters in the password (e.g. '@' in 'PostgreSQL@Module5').
    ssl_ctx = ssl.create_default_context() if PG_SSLMODE == "require" else None
    log.info("DEBUG ssl_ctx=%r", ssl_ctx)
    return await asyncpg.create_pool(
        host=host,
        port=PG_PORT,
        user=PG_USER,
        password=PG_PASSWORD,
        database=PG_DB,
        ssl=ssl_ctx,
        min_size=1,
        max_size=5,
    )


async def _ensure_schema(pool: asyncpg.Pool) -> None:
    """Create the products table if it does not already exist."""
    async with pool.acquire() as conn:
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS products (
                id          SERIAL PRIMARY KEY,
                name        TEXT           NOT NULL,
                description TEXT,
                price       NUMERIC(10,2)  NOT NULL,
                stock_level INTEGER        NOT NULL DEFAULT 0
            )
            """
        )
    log.info("Schema ready (products table exists)")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _primary_pool, _replica_pool, _redis

    log.info("Connecting to PostgreSQL primary: %s", PG_PRIMARY_HOST)
    _primary_pool = await _create_pool(PG_PRIMARY_HOST)
    await _ensure_schema(_primary_pool)

    log.info("Connecting to PostgreSQL replica: %s", PG_REPLICA_HOST)
    _replica_pool = await _create_pool(PG_REPLICA_HOST)

    if REDIS_HOST:
        log.info("Connecting to Redis: %s:%d", REDIS_HOST, REDIS_PORT)
        _redis = aioredis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            password=REDIS_PASSWORD,
            ssl=REDIS_TLS,
            decode_responses=True,
        )
        await _redis.ping()
    else:
        log.warning("REDIS_HOST not set — cache disabled, all requests go to PostgreSQL")

    yield

    await _primary_pool.close()
    await _replica_pool.close()
    if _redis:
        await _redis.aclose()


app = FastAPI(title="Product Catalog API", lifespan=lifespan)

# ── Models ─────────────────────────────────────────────────────────────────────


class ProductIn(BaseModel):
    name: str
    description: Optional[str] = None
    price: float
    stock_level: int = 0


class ProductOut(BaseModel):
    id: int
    name: str
    description: Optional[str]
    price: float
    stock_level: int
    image_url: Optional[str] = None
    datasheet_url: Optional[str] = None


# ── Helpers ────────────────────────────────────────────────────────────────────


def build_asset_urls(product_id: int) -> tuple[Optional[str], Optional[str]]:
    """Generate 15-minute SAS tokens for the product image and datasheet."""
    expiry = datetime.now(timezone.utc) + timedelta(minutes=SAS_EXPIRY_MINUTES)
    permission = BlobSasPermissions(read=True)

    def _sas(container: str, blob: str, extension: str) -> Optional[str]:
        blob_name = f"{product_id}{extension}"
        try:
            token = generate_blob_sas(
                account_name=AZURE_STORAGE_ACCOUNT,
                container_name=container,
                blob_name=blob_name,
                account_key=AZURE_STORAGE_KEY,
                permission=permission,
                expiry=expiry,
            )
            return (
                f"https://{AZURE_STORAGE_ACCOUNT}.blob.core.windows.net"
                f"/{container}/{blob_name}?{token}"
            )
        except Exception as exc:
            log.warning("Could not generate SAS for %s/%s: %s", container, blob_name, exc)
            return None

    image_url = _sas("images", str(product_id), ".jpg")
    datasheet_url = _sas("datasheets", str(product_id), ".pdf")
    return image_url, datasheet_url


def _row_to_dict(row: asyncpg.Record) -> dict:
    # asyncpg returns NUMERIC columns as decimal.Decimal, which json.dumps
    # cannot serialize. Convert to float so Redis SET and JSON responses work.
    return {k: float(v) if isinstance(v, decimal.Decimal) else v for k, v in row.items()}


async def _fetch_from_db(product_id: int) -> Optional[dict]:
    """SELECT from the read replica and log which host was used."""
    log.info("[DB:%s] SELECT products WHERE id=%d", PG_REPLICA_HOST, product_id)
    async with _replica_pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, name, description, price, stock_level FROM products WHERE id = $1",
            product_id,
        )
    return _row_to_dict(row) if row else None


async def _invalidate_cache(product_id: int) -> None:
    if _redis:
        await _redis.delete(f"product:{product_id}")


# ── Routes ─────────────────────────────────────────────────────────────────────


@app.get("/products/{product_id}", response_model=ProductOut)
async def get_product(product_id: int, response: Response):
    cache_key = f"product:{product_id}"

    if _redis:
        cached = await _redis.get(cache_key)
        if cached:
            response.headers["X-Cache"] = "HIT"
            data = json.loads(cached)
            image_url, datasheet_url = build_asset_urls(product_id)
            return ProductOut(**data, image_url=image_url, datasheet_url=datasheet_url)

    data = await _fetch_from_db(product_id)
    if data is None:
        raise HTTPException(status_code=404, detail="Product not found")

    if _redis:
        await _redis.set(cache_key, json.dumps(data), ex=CACHE_TTL)
    response.headers["X-Cache"] = "MISS"

    image_url, datasheet_url = build_asset_urls(product_id)
    return ProductOut(**data, image_url=image_url, datasheet_url=datasheet_url)


@app.post("/products", response_model=ProductOut, status_code=201)
async def create_product(product: ProductIn):
    log.info("[DB:%s] INSERT INTO products", PG_PRIMARY_HOST)
    async with _primary_pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO products (name, description, price, stock_level)
            VALUES ($1, $2, $3, $4)
            RETURNING id, name, description, price, stock_level
            """,
            product.name,
            product.description,
            product.price,
            product.stock_level,
        )
    data = _row_to_dict(row)
    await _invalidate_cache(data["id"])
    image_url, datasheet_url = build_asset_urls(data["id"])
    return ProductOut(**data, image_url=image_url, datasheet_url=datasheet_url)


@app.put("/products/{product_id}", response_model=ProductOut)
async def update_product(product_id: int, product: ProductIn):
    log.info("[DB:%s] UPDATE products SET ... WHERE id=%d", PG_PRIMARY_HOST, product_id)
    async with _primary_pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            UPDATE products
            SET name=$1, description=$2, price=$3, stock_level=$4
            WHERE id=$5
            RETURNING id, name, description, price, stock_level
            """,
            product.name,
            product.description,
            product.price,
            product.stock_level,
            product_id,
        )
    if row is None:
        raise HTTPException(status_code=404, detail="Product not found")

    await _invalidate_cache(product_id)
    data = _row_to_dict(row)
    image_url, datasheet_url = build_asset_urls(product_id)
    return ProductOut(**data, image_url=image_url, datasheet_url=datasheet_url)


@app.delete("/products/{product_id}", status_code=204)
async def delete_product(product_id: int):
    log.info("[DB:%s] DELETE FROM products WHERE id=%d", PG_PRIMARY_HOST, product_id)
    async with _primary_pool.acquire() as conn:
        result = await conn.execute(
            "DELETE FROM products WHERE id = $1", product_id
        )
    if result == "DELETE 0":
        raise HTTPException(status_code=404, detail="Product not found")

    await _invalidate_cache(product_id)


@app.get("/healthz")
async def health():
    return {"status": "ok"}
