"""Tests for /api/query endpoint."""

import time


def test_query_normal(client):
    response = client.get("/api/query")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert len(data["items"]) == 2


def test_query_with_latency(client):
    # Query endpoint also respects latency
    client.post("/chaos/latency", params={"ms": 50})
    start = time.time()
    response = client.get("/api/query")
    elapsed = time.time() - start
    assert response.status_code == 200
    assert elapsed >= 0.05
