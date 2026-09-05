"""Tests for the /health and /ready endpoints."""


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["service"] == "target-system"
    assert "version" in data
    assert "telemetry_enabled" in data
    # By default no chaos is active
    assert data["chaos"]["active"] is False
    assert data["chaos"]["oom"] is False
    assert data["chaos"]["db_deadlock"] is False
    assert data["chaos"]["latency_ms"] == 0
    assert data["chaos"]["error_rate"] == 0.0


def test_health_reflects_active_chaos(client):
    # Enable OOM
    client.post("/chaos/oom")
    response = client.get("/health")
    data = response.json()
    assert data["chaos"]["active"] is True
    assert data["chaos"]["oom"] is True


def test_ready_returns_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
