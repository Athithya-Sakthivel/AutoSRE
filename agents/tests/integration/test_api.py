"""Integration tests for the FastAPI application."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from autosre.api.runner import LangGraphRunner
from autosre.config import Settings


@pytest.fixture
def mock_settings() -> Settings:
    """Create real Settings object for testing."""
    import os

    # Set environment variables for Settings to load
    os.environ["LLM_API_KEY"] = "test-key"
    os.environ["POSTGRES_PASSWORD"] = "test-pass"
    os.environ["OPENOBSERVE_EMAIL"] = "test@example.com"
    os.environ["OPENOBSERVE_PASSWORD"] = "test-pass"
    os.environ["ALERT_WEBHOOK_SECRET"] = "test-secret"

    from autosre.config import get_settings

    settings = get_settings()

    # Clean up
    for key in [
        "LLM_API_KEY",
        "POSTGRES_PASSWORD",
        "OPENOBSERVE_EMAIL",
        "OPENOBSERVE_PASSWORD",
        "ALERT_WEBHOOK_SECRET",
    ]:
        os.environ.pop(key, None)

    return settings


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
    # connection() returns an async context manager directly (not a coroutine)
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
):
    """Create FastAPI app with healthy dependencies."""
    from fastapi import FastAPI

    test_app = FastAPI()

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
):
    """Create FastAPI app with unhealthy Postgres."""
    from fastapi import FastAPI

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
async def client_healthy(app_healthy: FastAPI):
    """Create async test client for healthy app."""
    transport = ASGITransport(app=app_healthy)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
async def client_unhealthy(app_unhealthy: FastAPI):
    """Create async test client for unhealthy app."""
    transport = ASGITransport(app=app_unhealthy)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ---------------------------------------------------------------------------
# Health & Readiness Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health_endpoint(client_healthy: AsyncClient):
    """Test the /healthz endpoint."""
    response = await client_healthy.get("/healthz")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "version" in data


@pytest.mark.asyncio
async def test_readiness_check_postgres_healthy(client_healthy: AsyncClient):
    """Test readiness check when Postgres is healthy."""
    response = await client_healthy.get("/readyz")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ready"
    assert "postgres" in data["checks"]


@pytest.mark.asyncio
async def test_readiness_check_postgres_unhealthy(client_unhealthy: AsyncClient):
    """Test readiness check when Postgres is unhealthy."""
    response = await client_unhealthy.get("/readyz")

    assert response.status_code == 503
    data = response.json()
    assert data["status"] == "not_ready"


# ---------------------------------------------------------------------------
# Webhook Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_alert_webhook_invalid_signature(client_healthy: AsyncClient):
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
    assert (
        "Invalid" in response.json()["detail"] or "signature" in response.json()["detail"].lower()
    )


@pytest.mark.asyncio
async def test_alert_webhook_valid_signature(
    client_healthy: AsyncClient,
    mock_runner: AsyncMock,
):
    """Test alert webhook with valid signature."""
    import hashlib
    import hmac
    import json

    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint",
    }

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = hmac.new(
        b"test-secret",
        payload_bytes,
        hashlib.sha256,
    ).hexdigest()

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

    # Verify runner was called
    mock_runner.run_incident.assert_called_once()


@pytest.mark.asyncio
async def test_approve_webhook_invalid_signature(client_healthy: AsyncClient):
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
):
    """Test approval webhook with valid signature."""
    import hashlib
    import hmac
    import json

    incident_id = "test-incident-123"
    payload = {"approved": True, "comment": "Looks good"}

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = hmac.new(
        b"test-secret",
        payload_bytes,
        hashlib.sha256,
    ).hexdigest()

    response = await client_healthy.post(
        f"/incidents/{incident_id}/approve",
        content=payload_bytes,
        headers={
            "X-Webhook-Signature": f"sha256={signature}",
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 200

    # Verify runner.approve_incident was called
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
    mock_checkpointer: AsyncMock,
):
    """Test incident report endpoint when incident not found."""
    mock_checkpointer.aget_tuple = AsyncMock(return_value=None)

    response = await client_healthy.get("/incidents/nonexistent-id/report")

    assert response.status_code == 404
    assert (
        "not found" in response.json()["detail"].lower() or "Incident" in response.json()["detail"]
    )


@pytest.mark.asyncio
async def test_incident_report_found(
    client_healthy: AsyncClient,
    mock_checkpointer: AsyncMock,
):
    """Test incident report endpoint when incident exists."""
    mock_checkpoint = MagicMock()
    mock_checkpoint.channel_values = {
        "current_phase": "complete",
        "hypotheses": [
            {
                "id": "H1",
                "description": "Database connection pool exhausted",
                "confidence": 0.9,
                "evidence": ["High connection count", "Slow queries"],
                "status": "confirmed",
            }
        ],
        "proposed_actions": [],
        "executed_actions": [],
        "tokens_used": 1500,
        "cost_usd": 0.05,
        "wall_clock_seconds": 45.2,
        "iteration_count": 3,
    }

    mock_checkpointer.aget_tuple = AsyncMock(return_value=mock_checkpoint)

    response = await client_healthy.get("/incidents/test-incident-123/report")

    assert response.status_code == 200
    data = response.json()

    assert data["status"] == "complete"
    assert data["phase"] == "complete"
    assert len(data["hypotheses"]) == 1
    assert data["tokens_used"] == 1500
    assert data["cost_usd"] == 0.05
    assert data["wall_clock_seconds"] == 45.2
    assert data["iterations"] == 3


@pytest.mark.asyncio
async def test_incident_report_awaiting_approval(
    client_healthy: AsyncClient,
    mock_checkpointer: AsyncMock,
):
    """Test incident report when awaiting human approval."""
    mock_checkpoint = MagicMock()
    mock_checkpoint.channel_values = {
        "current_phase": "propose",
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

    mock_checkpointer.aget_tuple = AsyncMock(return_value=mock_checkpoint)

    response = await client_healthy.get("/incidents/test-incident-456/report")

    assert response.status_code == 200
    data = response.json()

    assert data["status"] == "awaiting_approval"
    assert data["phase"] == "propose"
    assert len(data["proposed_actions"]) == 1
    assert data["proposed_actions"][0]["requires_approval"] is True
