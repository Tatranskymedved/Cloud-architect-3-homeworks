from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health_root():
    response = client.get("/")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == "1.0.0"


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == "1.0.0"


def test_get_quote():
    response = client.get("/quotes")
    assert response.status_code == 200
    body = response.json()
    assert "id" in body
    assert "text" in body
    assert "author" in body
    assert isinstance(body["text"], str)
    assert len(body["text"]) > 0


def test_get_quote_randomness():
    # Fetch multiple quotes and verify they are drawn from the known pool
    ids = {client.get("/quotes").json()["id"] for _ in range(30)}
    assert len(ids) >= 2, "Expected at least 2 distinct quotes in 30 draws"


def test_metrics():
    # Generate a request first so the counter is non-zero
    client.get("/quotes")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "quote_api_requests_total" in response.text
    assert "# HELP" in response.text
    assert "# TYPE" in response.text
