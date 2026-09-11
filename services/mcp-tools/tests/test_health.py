"""Smoke tests for the MCP server's health and readiness endpoints."""


def test_health_endpoint_returns_ok(test_client):
    response = test_client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["service"] == "mcp-tools"
    assert data["mode"] == "development"
    assert data["telemetry"]["azure_monitor"] is False


def test_ready_endpoint_returns_ready(test_client):
    response = test_client.get("/ready")
    assert response.status_code == 200
    assert response.text == "ready"
