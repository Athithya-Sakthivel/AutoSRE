"""Tests for /health and /ready endpoints."""

from __future__ import annotations


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready_returns_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_ready_when_graph_not_available(client, mock_graph):
    # Remove graph from app state
    client.app.state.graph = None
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "not ready"
