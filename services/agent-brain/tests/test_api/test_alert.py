"""Tests for POST /alert endpoint."""

from __future__ import annotations


def test_create_alert_returns_202_and_thread_id(client):
    payload = {"name": "Test Alert", "severity": "critical"}
    response = client.post("/alert", json=payload)
    assert response.status_code == 202
    data = response.json()
    assert "thread_id" in data
    assert data["status"] == "started"


def test_create_alert_requires_auth_when_enabled(client, mock_settings):
    mock_settings.require_auth = True
    # The TestClient does not automatically send auth headers, so expect 401
    response = client.post("/alert", json={})
    assert response.status_code == 401


def test_create_alert_with_auth_header(client, mock_settings):
    mock_settings.require_auth = True
    payload = {"name": "Auth Test", "severity": "warning"}
    response = client.post(
        "/alert",
        json=payload,
        headers={"Authorization": f"Bearer {mock_settings.mcp_api_key}"},
    )
    assert response.status_code == 202
