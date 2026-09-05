"""Tests for /api/process under normal and chaos conditions."""

import time


def test_process_normal(client):
    response = client.post("/api/process")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_process_with_latency(client):
    # Set 100ms latency
    client.post("/chaos/latency", params={"ms": 100})
    start = time.time()
    response = client.post("/api/process")
    elapsed = time.time() - start
    assert response.status_code == 200
    # The sleep is async, but the test should take at least the latency
    assert elapsed >= 0.1


def test_process_with_error_rate(client):
    # Set 100% error rate
    client.post("/chaos/error-rate", params={"rate": 1.0})
    response = client.post("/api/process")
    assert response.status_code == 500
    assert "Chaos: random error injected" in response.text


def test_process_with_oom(client):
    client.post("/chaos/oom")
    response = client.post("/api/process")
    assert response.status_code == 500
    assert "Chaos: simulated OOM" in response.text


def test_process_with_db_deadlock(client):
    client.post("/chaos/db-deadlock")
    response = client.post("/api/process")
    assert response.status_code == 500
    assert "Chaos: simulated database deadlock" in response.text


def test_process_multiple_chaos_flags(client):
    # Activate both OOM and deadlock – OOM is checked first, so we get OOM
    client.post("/chaos/oom")
    client.post("/chaos/db-deadlock")
    response = client.post("/api/process")
    assert response.status_code == 500
    assert "Chaos: simulated OOM" in response.text
