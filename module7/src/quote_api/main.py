import json
import os
import random
import time

from fastapi import FastAPI, Response
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="Quote of the Day API", version="1.0.0")

# Load quotes at startup
_quotes_path = os.path.join(os.path.dirname(__file__), "quotes.json")
with open(_quotes_path) as f:
    _quotes = json.load(f)

# Prometheus counter — incremented in middleware for every request
_request_counter = Counter(
    "quote_api_requests_total",
    "Total HTTP requests",
    ["path"],
)

# Application Insights telemetry — conditional on env var
_az_exporter = None
_az_sampler = None
_connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
if _connection_string:
    from opencensus.ext.azure.trace_exporter import AzureExporter
    from opencensus.trace.samplers import AlwaysOnSampler

    _az_exporter = AzureExporter(connection_string=_connection_string)
    _az_sampler = AlwaysOnSampler()


@app.middleware("http")
async def telemetry_middleware(request, call_next):
    path = request.url.path
    _request_counter.labels(path=path).inc()

    if _az_exporter is not None:
        from opencensus.trace.tracer import Tracer

        tracer = Tracer(exporter=_az_exporter, sampler=_az_sampler)
        start = time.time()
        response = await call_next(request)
        duration_ms = (time.time() - start) * 1000
        with tracer.span(name=f"{request.method} {path}") as span:
            span.add_attribute("http.status_code", response.status_code)
            span.add_attribute("http.duration_ms", duration_ms)
        return response

    return await call_next(request)


@app.get("/")
async def health():
    return {"status": "ok", "version": "1.0.0"}


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "version": "1.0.0"}


@app.get("/quotes")
async def get_quote():
    return random.choice(_quotes)


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
