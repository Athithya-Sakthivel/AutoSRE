"""Integration tests for the FastAPI application."""

from __future__ import annotations

import hashlib
import hmac
import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from autosre.api.main import create_app
from autosre.config import Settings

# ---------------------------------------------------------------------------
# No-op lifespan for tests
# ---------------------------------------------------------------------------


@asynccontextmanager
async def noop_lifespan(app: FastAPI) -> AsyncIterator[None]:
    """No-op lifespan that skips all production initialization.

    This prevents:
    - OpenTelemetry reinitialization errors (once-per-process guard)
    - Real Postgres/Valkey connections in tests
    - Real LLM router construction
    """
    yield


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def settings() -> Settings:
    """Create test settings with valid model names."""
    return Settings(
        llm={
            "api_key": "test-key-for-ci",
            "provider": "groq",
            "model_coordinator": "groq/test-coordinator",
            "model_worker": "groq/test-worker",
        },
        postgres={
            "host": "localhost",
            "port": 5432,
            "db": "test",
            "user": "test",
            "password": "test",
        },
        alert={"webhook_secret": "test-secret"},
        openobserve={
            "email": "test@example.com",
            "password": "test-pass",
            "url": "http://localhost:5080",
        },
    )


@pytest.fixture
def app(settings: Settings) -> FastAPI:
    """Create test app with no-op lifespan to skip production initialization."""
    test_app = create_app(settings)
    # Override lifespan to prevent telemetry init, DB connections, etc.
    test_app.router.lifespan_context = noop_lifespan
    return test_app


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
def mock_runner() -> AsyncMock:
    """Create mock LangGraphRunner."""
    runner = AsyncMock()
    runner.run_incident = AsyncMock(return_value="test-incident-id")
    runner.approve_incident = AsyncMock(return_value=True)
    runner.get_incident_state = AsyncMock(return_value=None)
    runner.list_incidents = AsyncMock(return_value=[])
    return runner


@pytest.fixture
async def client_healthy(
    app: FastAPI,
    mock_pg_pool_healthy: MagicMock,
    mock_runner: AsyncMock,
) -> AsyncIterator[tuple[AsyncClient, AsyncMock]]:
    """Create async test client with healthy dependencies.

    No TestClient — uses AsyncClient with ASGITransport directly,
    which does NOT trigger lifespan startup/shutdown.
    """
    app.state.pg_pool = mock_pg_pool_healthy
    app.state.runner = mock_runner

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client, mock_runner


@pytest.fixture
async def client_unhealthy(
    app: FastAPI,
    mock_pg_pool_unhealthy: MagicMock,
    mock_runner: AsyncMock,
) -> AsyncIterator[AsyncClient]:
    """Create async test client with unhealthy Postgres."""
    app.state.pg_pool = mock_pg_pool_unhealthy
    app.state.runner = mock_runner

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


# ---------------------------------------------------------------------------
# Health & Readiness Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health_endpoint(
    app: FastAPI,
    mock_pg_pool_healthy: MagicMock,
    mock_runner: AsyncMock,
) -> None:
    """Test the /healthz endpoint."""
    app.state.pg_pool = mock_pg_pool_healthy
    app.state.runner = mock_runner

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/healthz")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert "version" in data


@pytest.mark.asyncio
async def test_readiness_check_postgres_healthy(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test readiness check when Postgres is healthy."""
    client, _ = client_healthy
    response = await client.get("/readyz")

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
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test alert webhook with invalid signature."""
    client, _ = client_healthy
    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint",
    }

    response = await client.post(
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
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test alert webhook with valid signature."""
    client, mock_runner = client_healthy

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

    response = await client.post(
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
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test approval webhook with invalid signature."""
    client, _ = client_healthy
    response = await client.post(
        "/incidents/test-incident-id/approve",
        json={"approved": True, "comment": "test"},
        headers={"X-Webhook-Signature": "invalid-signature"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_approve_webhook_valid_signature(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test approval webhook with valid signature."""
    client, mock_runner = client_healthy

    incident_id = "test-incident-123"
    payload = {"approved": True, "comment": "Looks good"}

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = hmac.new(
        b"test-secret",
        payload_bytes,
        hashlib.sha256,
    ).hexdigest()

    response = await client.post(
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
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test incident report endpoint when incident not found."""
    client, mock_runner = client_healthy

    mock_runner.get_incident_state.return_value = None

    response = await client.get("/incidents/nonexistent-id/report")

    assert response.status_code == 404
    assert "not found" in response.json()["detail"].lower()


@pytest.mark.asyncio
async def test_incident_report_found(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test incident report endpoint when incident exists."""
    client, mock_runner = client_healthy

    mock_state = MagicMock()
    mock_state.values = {
        "incident_metadata": {
            "incident_id": "test-incident-123",
            "alert_name": "HighCPU",
            "service": "api-gateway",
            "namespace": "production",
            "severity": "high",
            "started_at": "2026-01-01T10:00:00Z",
            "labels": {"category": "cpu_saturation"},
        },
        "status": "resolved",
        "current_phase": "complete",
        "hypotheses": [
            {
                "id": "H1",
                "description": "CPU saturation",
                "confidence": 0.95,
                "evidence": ["CPU at 92%"],
            }
        ],
        "proposed_actions": [
            {
                "tool_name": "scale_deployment",
                "tool_args": {"replicas": 4},
                "risk_tier": 2,
            }
        ],
        "executed_actions": [
            {
                "tool_name": "scale_deployment",
                "tool_args": {"replicas": 4},
                "success": True,
                "executed_at": "2026-01-01T10:01:00Z",
            }
        ],
        "tokens_used": 15000,
        "cost_usd": 0.012,
        "wall_clock_seconds": 45.5,
        "iteration_count": 3,
        "requires_human_approval": False,
        "approval_granted": None,
    }

    mock_runner.get_incident_state.return_value = mock_state

    response = await client.get("/incidents/test-incident-123/report")

    assert response.status_code == 200
    data = response.json()

    assert data["incident_id"] == "test-incident-123"
    assert data["status"] == "resolved"
    assert data["alert_name"] == "HighCPU"
    assert data["service"] == "api-gateway"
    assert len(data["hypotheses"]) == 1
    assert len(data["executed_actions"]) == 1
    assert data["tokens_used"] == 15000
    assert data["cost_usd"] == 0.012


@pytest.mark.asyncio
async def test_incident_report_awaiting_approval(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test incident report when awaiting human approval."""
    client, mock_runner = client_healthy

    mock_state = MagicMock()
    mock_state.values = {
        "incident_metadata": {
            "incident_id": "test-incident-456",
            "alert_name": "DatabaseConnectionPoolExhausted",
            "service": "api-gateway",
            "namespace": "production",
            "severity": "critical",
            "started_at": "2026-01-01T11:00:00Z",
        },
        "status": "awaiting_approval",
        "current_phase": "approve",
        "hypotheses": [],
        "proposed_actions": [
            {
                "tool_name": "scale_deployment",
                "tool_args": {"replicas": 10},
                "risk_tier": 2,
                "rationale": "Scale to handle connection pool exhaustion",
            }
        ],
        "executed_actions": [],
        "tokens_used": 8000,
        "cost_usd": 0.008,
        "wall_clock_seconds": 30.0,
        "iteration_count": 2,
        "requires_human_approval": True,
        "approval_granted": None,
    }

    mock_runner.get_incident_state.return_value = mock_state

    response = await client.get("/incidents/test-incident-456/report")

    assert response.status_code == 200
    data = response.json()

    assert data["incident_id"] == "test-incident-456"
    assert data["status"] == "awaiting_approval"
    assert data["requires_human_approval"] is True
    assert data["approval_granted"] is None
    assert len(data["proposed_actions"]) == 1
    assert data["proposed_actions"][0]["risk_tier"] == 2


# ---------------------------------------------------------------------------
# Incident List Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_incidents_empty(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test /incidents returns empty list when no incidents exist."""
    client, mock_runner = client_healthy

    mock_runner.list_incidents.return_value = []

    response = await client.get("/incidents")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 0
    assert data["items"] == []


@pytest.mark.asyncio
async def test_list_incidents_with_data(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test /incidents returns list of incidents."""
    client, mock_runner = client_healthy

    mock_state1 = MagicMock()
    mock_state1.values = {
        "incident_metadata": {
            "incident_id": "inc-1",
            "alert_name": "Alert1",
            "service": "svc1",
            "namespace": "ns1",
            "severity": "high",
            "started_at": "2026-01-01T10:00:00Z",
        },
        "status": "resolved",
        "current_phase": "complete",
        "requires_human_approval": False,
        "approval_granted": None,
        "tokens_used": 5000,
        "cost_usd": 0.005,
        "wall_clock_seconds": 20.0,
        "iteration_count": 2,
    }

    mock_state2 = MagicMock()
    mock_state2.values = {
        "incident_metadata": {
            "incident_id": "inc-2",
            "alert_name": "Alert2",
            "service": "svc2",
            "namespace": "ns2",
            "severity": "critical",
            "started_at": "2026-01-01T11:00:00Z",
        },
        "status": "awaiting_approval",
        "current_phase": "approve",
        "requires_human_approval": True,
        "approval_granted": None,
        "tokens_used": 8000,
        "cost_usd": 0.008,
        "wall_clock_seconds": 30.0,
        "iteration_count": 3,
    }

    mock_runner.list_incidents.return_value = [
        ("inc-1", mock_state1),
        ("inc-2", mock_state2),
    ]

    response = await client.get("/incidents")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 2
    assert len(data["items"]) == 2
    assert data["items"][0]["incident_id"] == "inc-1"
    assert data["items"][1]["incident_id"] == "inc-2"


@pytest.mark.asyncio
async def test_list_incidents_with_status_filter(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Test /incidents?status=resolved filters correctly."""
    client, mock_runner = client_healthy

    mock_state1 = MagicMock()
    mock_state1.values = {
        "incident_metadata": {
            "incident_id": "inc-1",
            "alert_name": "Alert1",
            "service": "svc1",
            "namespace": "ns1",
            "severity": "high",
            "started_at": "2026-01-01T10:00:00Z",
        },
        "status": "resolved",
        "current_phase": "complete",
        "requires_human_approval": False,
        "approval_granted": None,
        "tokens_used": 5000,
        "cost_usd": 0.005,
        "wall_clock_seconds": 20.0,
        "iteration_count": 2,
    }

    mock_state2 = MagicMock()
    mock_state2.values = {
        "incident_metadata": {
            "incident_id": "inc-2",
            "alert_name": "Alert2",
            "service": "svc2",
            "namespace": "ns2",
            "severity": "critical",
            "started_at": "2026-01-01T11:00:00Z",
        },
        "status": "awaiting_approval",
        "current_phase": "approve",
        "requires_human_approval": True,
        "approval_granted": None,
        "tokens_used": 8000,
        "cost_usd": 0.008,
        "wall_clock_seconds": 30.0,
        "iteration_count": 3,
    }

    mock_runner.list_incidents.return_value = [
        ("inc-1", mock_state1),
        ("inc-2", mock_state2),
    ]

    response = await client.get("/incidents?status=resolved")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 1
    assert len(data["items"]) == 1
    assert data["items"][0]["status"] == "resolved"
