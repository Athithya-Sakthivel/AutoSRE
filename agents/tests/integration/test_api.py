"""Integration tests for the FastAPI application."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from collections.abc import Iterator
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from autosre.api.runner import LangGraphRunner
from autosre.config import Settings, reset_settings_cache


@pytest.fixture
def mock_settings(monkeypatch: pytest.MonkeyPatch) -> Iterator[Settings]:
    """Create real Settings object with AUTOSRE_ prefixed env vars."""
    # Strip all existing AUTOSRE_ vars to prevent leakage
    for key in list(os.environ):
        if key.startswith("AUTOSRE_"):
            monkeypatch.delenv(key, raising=False)

    # Set env vars with AUTOSRE_ prefix and __ nested delimiter
    monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "test-key")
    monkeypatch.setenv("AUTOSRE_LLM__BASE_URL", "https://api.groq.com/openai/v1")
    monkeypatch.setenv("AUTOSRE_LLM__PROVIDER", "groq")
    monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "test-pass")
    monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "test@example.com")
    monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "test-pass")

    reset_settings_cache()
    settings = Settings()

    yield settings

    reset_settings_cache()


@pytest.fixture
def mock_runner() -> AsyncMock:
    """Create mock LangGraphRunner."""
    runner = AsyncMock(spec=LangGraphRunner)
    runner.run_incident = AsyncMock(return_value=None)
    runner.approve_incident = AsyncMock(return_value=True)
    return runner


@pytest.fixture
def mock_checkpointer() -> AsyncMock:
    """Create mock checkpointer."""
    checkpointer = AsyncMock()
    checkpointer.aget_tuple = AsyncMock(return_value=None)
    return checkpointer


@pytest.fixture
def mock_pg_pool_healthy() -> MagicMock:
    """Create mock Postgres connection pool (healthy)."""
    pool = MagicMock()
    conn = AsyncMock()
    cursor = AsyncMock()

    cursor.execute = AsyncMock()
    conn.cursor = MagicMock(return_value=cursor)
    conn.__aenter__ = AsyncMock(return_value=conn)
    conn.__aexit__ = AsyncMock(return_value=None)
    cursor.__aenter__ = AsyncMock(return_value=cursor)
    cursor.__aexit__ = AsyncMock(return_value=None)

    pool.connection = MagicMock(return_value=conn)

    return pool


@pytest.fixture
def mock_pg_pool_unhealthy() -> MagicMock:
    """Create mock Postgres connection pool (unhealthy)."""
    pool = MagicMock()
    pool.connection = MagicMock(side_effect=Exception("Connection failed"))
    return pool


@pytest.fixture
def app_healthy(
    mock_settings: Settings,
    mock_runner: AsyncMock,
    mock_checkpointer: AsyncMock,
    mock_pg_pool_healthy: MagicMock,
) -> FastAPI:
    """Create FastAPI app with healthy dependencies."""
    test_app = FastAPI()

    mock_graph = AsyncMock()
    mock_graph.aget_state = AsyncMock(return_value=None)
    mock_runner.graph = mock_graph

    test_app.state.settings = mock_settings
    test_app.state.runner = mock_runner
    test_app.state.checkpointer = mock_checkpointer
    test_app.state.pg_pool = mock_pg_pool_healthy

    from autosre.api.routes import router, webhook_router

    test_app.include_router(router)
    test_app.include_router(webhook_router)

    return test_app


@pytest.fixture
def app_unhealthy(
    mock_settings: Settings,
    mock_runner: AsyncMock,
    mock_checkpointer: AsyncMock,
    mock_pg_pool_unhealthy: MagicMock,
) -> FastAPI:
    """Create FastAPI app with unhealthy Postgres."""
    test_app = FastAPI()

    test_app.state.settings = mock_settings
    test_app.state.runner = mock_runner
    test_app.state.checkpointer = mock_checkpointer
    test_app.state.pg_pool = mock_pg_pool_unhealthy

    from autosre.api.routes import router, webhook_router

    test_app.include_router(router)
    test_app.include_router(webhook_router)

    return test_app


@pytest.fixture
async def client_healthy(app_healthy: FastAPI) -> Iterator[AsyncClient]:
    """Create async test client for healthy app."""
    transport = ASGITransport(app=app_healthy)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
async def client_unhealthy(app_unhealthy: FastAPI) -> Iterator[AsyncClient]:
    """Create async test client for unhealthy app."""
    transport = ASGITransport(app=app_unhealthy)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _sign_payload(payload_bytes: bytes, secret: str) -> str:
    """Compute HMAC-SHA256 signature for webhook verification."""
    return hmac.new(
        secret.encode("utf-8"),
        payload_bytes,
        hashlib.sha256,
    ).hexdigest()


# ---------------------------------------------------------------------------
# Health & Readiness Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health_endpoint(client_healthy: AsyncClient) -> None:
    """Test the /healthz endpoint."""
    response = await client_healthy.get("/healthz")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "version" in data


@pytest.mark.asyncio
async def test_readiness_check_postgres_healthy(
    client_healthy: AsyncClient,
) -> None:
    """Test readiness check when Postgres is healthy."""
    response = await client_healthy.get("/readyz")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ready"
    assert "postgres" in data["checks"]


@pytest.mark.asyncio
async def test_readiness_check_postgres_unhealthy(
    client_unhealthy: AsyncClient,
) -> None:
    """Test readiness check when Postgres is unhealthy."""
    response = await client_unhealthy.get("/readyz")

    assert response.status_code == 503
    data = response.json()
    assert data["status"] == "not_ready"


# ---------------------------------------------------------------------------
# Webhook Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_alert_webhook_invalid_signature(
    client_healthy: AsyncClient,
) -> None:
    """Test alert webhook with invalid signature."""
    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint",
    }

    response = await client_healthy.post(
        "/alerts",
        json=payload,
        headers={"X-Webhook-Signature": "invalid-signature"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_alert_webhook_valid_signature(
    client_healthy: AsyncClient,
    mock_runner: AsyncMock,
) -> None:
    """Test alert webhook with valid signature."""
    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint",
    }

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = _sign_payload(payload_bytes, "test-secret")

    response = await client_healthy.post(
        "/alerts",
        content=payload_bytes,
        headers={
            "X-Webhook-Signature": f"sha256={signature}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 202
    data = response.json()
    assert "incident_id" in data

    mock_runner.run_incident.assert_called_once()


@pytest.mark.asyncio
async def test_approve_webhook_invalid_signature(
    client_healthy: AsyncClient,
) -> None:
    """Test approval webhook with invalid signature."""
    response = await client_healthy.post(
        "/incidents/test-incident-id/approve",
        json={"approved": True, "comment": "test"},
        headers={"X-Webhook-Signature": "invalid-signature"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_approve_webhook_valid_signature(
    client_healthy: AsyncClient,
    mock_runner: AsyncMock,
) -> None:
    """Test approval webhook with valid signature."""
    incident_id = "test-incident-123"
    payload = {"approved": True, "comment": "Looks good"}

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = _sign_payload(payload_bytes, "test-secret")

    response = await client_healthy.post(
        f"/incidents/{incident_id}/approve",
        content=payload_bytes,
        headers={
            "X-Webhook-Signature": f"sha256={signature}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 200

    mock_runner.approve_incident.assert_called_once_with(
        incident_id,
        True,
        "Looks good",
    )


# ---------------------------------------------------------------------------
# Incident Report Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_incident_report_not_found(
    client_healthy: AsyncClient,
    app_healthy: FastAPI,
) -> None:
    """Test incident report endpoint when incident not found."""
    app_healthy.state.runner.graph.aget_state = AsyncMock(return_value=None)

    response = await client_healthy.get("/incidents/nonexistent-id/report")

    assert response.status_code == 404
    assert "not found" in response.json()["detail"].lower()


@pytest.mark.asyncio
async def test_incident_report_found(
    client_healthy: AsyncClient,
    app_healthy: FastAPI,
) -> None:
    """Test incident report endpoint when incident exists."""
    mock_snapshot = MagicMock()
    mock_snapshot.values = {
        "current_phase": "complete",
        "incident_metadata": {
            "incident_id": "test-incident-123",
            "alert_name": "TestAlert",
            "service": "api-gateway",
            "namespace": "rivulet",
            "severity": "high",
            "started_at": "2026-01-09T10:00:00Z",
            "fingerprint": "test-fp",
        },
        "hypotheses": [
            {
                "id": "H1",
                "description": "Database connection pool exhausted",
                "confidence": 0.9,
                "evidence": ["High connection count"],
                "status": "confirmed",
            }
        ],
        "proposed_actions": [],
        "executed_actions": [
            {
                "tool_name": "restart_deployment",
                "success": True,
                "verification_passed": True,
            }
        ],
        "tokens_used": 1500,
        "cost_usd": 0.05,
        "wall_clock_seconds": 45.2,
        "iteration_count": 3,
    }

    app_healthy.state.runner.graph.aget_state = AsyncMock(return_value=mock_snapshot)

    response = await client_healthy.get("/incidents/test-incident-123/report")

    assert response.status_code == 200
    data = response.json()

    assert data["status"] == "resolved"
    assert data["phase"] == "complete"
    assert len(data["hypotheses"]) == 1
    assert data["tokens_used"] == 1500
    assert data["cost_usd"] == 0.05
    assert data["wall_clock_seconds"] == 45.2
    assert data["iterations"] == 3


@pytest.mark.asyncio
async def test_incident_report_awaiting_approval(
    client_healthy: AsyncClient,
    app_healthy: FastAPI,
) -> None:
    """Test incident report when awaiting human approval."""
    mock_snapshot = MagicMock()
    mock_snapshot.values = {
        "current_phase": "propose",
        "incident_metadata": {
            "incident_id": "test-incident-456",
            "alert_name": "ScaleUp",
            "service": "api-gateway",
            "namespace": "rivulet",
            "severity": "medium",
            "started_at": "2026-01-09T10:00:00Z",
            "fingerprint": "test-fp-2",
        },
        "hypotheses": [],
        "proposed_actions": [
            {
                "tool_name": "scale_deployment",
                "tool_args": {"deployment": "api-gateway", "replicas": 5},
                "risk_tier": 2,
                "rationale": "Scale up to handle load",
                "requires_approval": True,
            }
        ],
        "executed_actions": [],
        "requires_human_approval": True,
        "approval_granted": None,
        "tokens_used": 800,
        "cost_usd": 0.02,
        "wall_clock_seconds": 30.5,
        "iteration_count": 2,
    }

    app_healthy.state.runner.graph.aget_state = AsyncMock(return_value=mock_snapshot)

    response = await client_healthy.get("/incidents/test-incident-456/report")

    assert response.status_code == 200
    data = response.json()

    assert data["status"] == "awaiting_approval"
    assert data["phase"] == "propose"
    assert len(data["proposed_actions"]) == 1
    assert data["proposed_actions"][0]["requires_approval"] is True
