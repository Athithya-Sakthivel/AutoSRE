"""Integration tests for the FastAPI application.

The webhook `/alerts` handler is non-blocking: it dispatches via
``runner.schedule_incident`` and returns 202 immediately. The tests
therefore assert against ``schedule_incident``, not ``run_incident``.

Module-level state in ``autosre.api.routes`` (the fingerprint dedup
index and the rate limiter) persists across tests in one process, so an
autouse fixture resets both before every test to prevent cross-test
contamination.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from collections.abc import AsyncIterator, Iterator
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
    """Skip all production initialization (OTel, DB pools, LLM router)."""
    yield


# ---------------------------------------------------------------------------
# Module-level state reset
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_route_module_state() -> Iterator[None]:
    """Reset the fingerprint index and rate limiter before each test.

    These are module-level singletons in ``autosre.api.routes``. Without
    this reset, a fingerprint reserved by one test would be deduplicated
    away in the next, causing the handler to skip ``schedule_incident``
    and the assertions to fail intermittently.
    """
    from autosre.api.routes import _alerts_limiter, _fingerprint_index

    _alerts_limiter.reset()
    _fingerprint_index.reset()

    yield

    _alerts_limiter.reset()
    _fingerprint_index.reset()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def settings() -> Settings:
    """Create test settings with valid, self-contained values."""
    return Settings(
        llm={
            "api_key": "test-key-for-ci",
            "provider": "groq",
            "model_coordinator": "qwen/qwen3.8-27b",
            "model_worker": "openai/gpt-oss-20b",
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
    """Create a test app with a no-op lifespan."""
    test_app = create_app(settings)
    test_app.router.lifespan_context = noop_lifespan
    return test_app


@pytest.fixture
def mock_pg_pool_healthy() -> MagicMock:
    """Mock Postgres pool that responds to a single SELECT 1."""
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
    """Mock Postgres pool whose connection() raises."""
    pool = MagicMock()
    pool.connection = MagicMock(side_effect=Exception("Connection failed"))
    return pool


@pytest.fixture
def mock_runner() -> AsyncMock:
    """Mock LangGraphRunner implementing RunnerProtocol.

    Both ``run_incident`` (blocking) and ``schedule_incident``
    (non-blocking) are set, because the test suite exercises both the
    webhook path (schedule_incident) and direct-run scenarios.
    """
    runner = AsyncMock()
    runner.run_incident = AsyncMock(return_value="test-incident-id")
    runner.schedule_incident = AsyncMock(return_value="test-incident-id")
    runner.approve_incident = AsyncMock(return_value=True)
    runner.get_incident_state = AsyncMock(return_value=None)
    runner.list_incidents = AsyncMock(return_value=[])
    runner.shutdown = AsyncMock(return_value=None)
    return runner


@pytest.fixture
async def client_healthy(
    app: FastAPI,
    mock_pg_pool_healthy: MagicMock,
    mock_runner: AsyncMock,
) -> AsyncIterator[tuple[AsyncClient, AsyncMock]]:
    """AsyncClient with healthy dependencies and no-op lifespan."""
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
    """AsyncClient with an unhealthy Postgres pool."""
    app.state.pg_pool = mock_pg_pool_unhealthy
    app.state.runner = mock_runner

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


# ---------------------------------------------------------------------------
# Health & readiness
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health_endpoint(
    app: FastAPI,
    mock_pg_pool_healthy: MagicMock,
    mock_runner: AsyncMock,
) -> None:
    """`/healthz` returns 200 with status and version."""
    app.state.pg_pool = mock_pg_pool_healthy
    app.state.runner = mock_runner

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/healthz")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert "version" in data
        # `paused` was added in the kill-switch release; assert it exists
        # and is a bool so the UI contract holds.
        assert isinstance(data.get("paused"), bool)


@pytest.mark.asyncio
async def test_readiness_check_postgres_healthy(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/readyz` returns 200 when Postgres responds."""
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
    """`/readyz` returns 503 when Postgres fails."""
    response = await client_unhealthy.get("/readyz")

    assert response.status_code == 503
    data = response.json()
    assert data["status"] == "not_ready"


# ---------------------------------------------------------------------------
# Webhook: /alerts
# ---------------------------------------------------------------------------


def _sign(payload_bytes: bytes, secret: bytes = b"test-secret") -> str:
    """Return the `sha256=<hex>` header value for a body."""
    digest = hmac.new(secret, payload_bytes, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


@pytest.mark.asyncio
async def test_alert_webhook_invalid_signature(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Invalid signature returns 401 before any dispatch."""
    client, mock_runner = client_healthy
    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint-invalid",
    }

    response = await client.post(
        "/alerts",
        json=payload,
        headers={"X-Webhook-Signature": "invalid-signature"},
    )

    assert response.status_code == 401
    detail = response.json()["detail"].lower()
    assert "invalid" in detail or "signature" in detail
    mock_runner.schedule_incident.assert_not_called()


@pytest.mark.asyncio
async def test_alert_webhook_valid_signature(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Valid signature returns 202 and schedules the incident.

    The handler uses ``schedule_incident`` (non-blocking), not
    ``run_incident``. The assertion is on the former.
    """
    client, mock_runner = client_healthy

    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint-valid",
    }

    payload_bytes = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()

    response = await client.post(
        "/alerts",
        content=payload_bytes,
        headers={
            "X-Webhook-Signature": _sign(payload_bytes),
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 202
    data = response.json()
    assert data.get("incident_id") == "test-incident-id"
    assert data.get("status") == "accepted"

    mock_runner.schedule_incident.assert_awaited_once()


@pytest.mark.asyncio
async def test_alert_webhook_dedup_on_duplicate_fingerprint(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """A duplicate fingerprint within the TTL is deduplicated.

    The handler returns 202 with the existing incident_id and does NOT
    schedule a second graph.
    """
    client, mock_runner = client_healthy

    payload = {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "high",
        "started_at": "2026-01-09T10:00:00Z",
        "fingerprint": "test-fingerprint-dedup",
    }

    payload_bytes = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    headers = {
        "X-Webhook-Signature": _sign(payload_bytes),
        "Content-Type": "application/json",
    }

    first = await client.post("/alerts", content=payload_bytes, headers=headers)
    assert first.status_code == 202
    assert first.json()["status"] == "accepted"
    mock_runner.schedule_incident.assert_awaited_once()

    # Reset the mock's call count but not the fingerprint index.
    mock_runner.schedule_incident.reset_mock()

    second = await client.post("/alerts", content=payload_bytes, headers=headers)
    assert second.status_code == 202
    assert second.json()["status"] == "already_investigating"
    assert second.json()["incident_id"] == "test-incident-id"

    # Second delivery must NOT schedule a new graph.
    mock_runner.schedule_incident.assert_not_called()


# ---------------------------------------------------------------------------
# Webhook: /incidents/{id}/approve
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_approve_webhook_invalid_signature(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Invalid signature returns 401 before touching the runner."""
    client, mock_runner = client_healthy
    response = await client.post(
        "/incidents/test-incident-id/approve",
        json={"approved": True, "comment": "test"},
        headers={"X-Webhook-Signature": "invalid-signature"},
    )

    assert response.status_code == 401
    mock_runner.approve_incident.assert_not_called()


@pytest.mark.asyncio
async def test_approve_webhook_valid_signature(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """Valid signature resumes the runner."""
    client, mock_runner = client_healthy

    incident_id = "test-incident-123"
    payload = {"approved": True, "comment": "Looks good"}

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()

    response = await client.post(
        f"/incidents/{incident_id}/approve",
        content=payload_bytes,
        headers={
            "X-Webhook-Signature": _sign(payload_bytes),
            "Content-Type": "application/json",
        },
    )

    assert response.status_code == 200

    mock_runner.approve_incident.assert_awaited_once_with(
        incident_id,
        True,
        "Looks good",
    )


# ---------------------------------------------------------------------------
# Incident report
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_incident_report_not_found(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/incidents/{id}/report` returns 404 when state is None."""
    client, mock_runner = client_healthy
    mock_runner.get_incident_state.return_value = None

    response = await client.get("/incidents/nonexistent-id/report")

    assert response.status_code == 404
    assert "not found" in response.json()["detail"].lower()


@pytest.mark.asyncio
async def test_incident_report_found(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/incidents/{id}/report` returns the full report."""
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
        "active_seconds": 40.0,
        "backoff_seconds": 5.5,
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
    assert data["active_seconds"] == 40.0
    assert data["backoff_seconds"] == 5.5


@pytest.mark.asyncio
async def test_incident_report_awaiting_approval(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/incidents/{id}/report` surfaces a paused HITL incident."""
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
        "status": "running",
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
        "active_seconds": 30.0,
        "backoff_seconds": 0.0,
        "iteration_count": 2,
        "requires_human_approval": True,
        "approval_granted": None,
    }

    mock_runner.get_incident_state.return_value = mock_state

    response = await client.get("/incidents/test-incident-456/report")

    assert response.status_code == 200
    data = response.json()

    assert data["incident_id"] == "test-incident-456"
    assert data["requires_human_approval"] is True
    assert data["approval_granted"] is None
    assert len(data["proposed_actions"]) == 1
    assert data["proposed_actions"][0]["risk_tier"] == 2


# ---------------------------------------------------------------------------
# Incident list
# ---------------------------------------------------------------------------


def _make_state(incident_id: str, status: str, *, approval: bool = False) -> MagicMock:
    """Build a MagicMock state snapshot for list tests."""
    state = MagicMock()
    state.values = {
        "incident_metadata": {
            "incident_id": incident_id,
            "alert_name": f"Alert-{incident_id}",
            "service": "svc",
            "namespace": "ns",
            "severity": "high",
            "started_at": "2026-01-01T10:00:00Z",
        },
        "status": status,
        "current_phase": "complete" if status == "resolved" else "approve",
        "requires_human_approval": approval,
        "approval_granted": None,
        "tokens_used": 5000,
        "cost_usd": 0.005,
        "wall_clock_seconds": 20.0,
        "active_seconds": 20.0,
        "backoff_seconds": 0.0,
        "iteration_count": 2,
    }
    return state


@pytest.mark.asyncio
async def test_list_incidents_empty(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/incidents` returns an empty list when no incidents exist."""
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
    """`/incidents` returns every incident with derived statuses."""
    client, mock_runner = client_healthy

    s1 = _make_state("inc-1", "resolved")
    s2 = _make_state("inc-2", "running", approval=True)

    mock_runner.list_incidents.return_value = [
        ("inc-1", s1),
        ("inc-2", s2),
    ]

    response = await client.get("/incidents")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 2
    assert len(data["items"]) == 2
    assert data["items"][0]["incident_id"] == "inc-1"
    assert data["items"][0]["status"] == "resolved"
    assert data["items"][1]["incident_id"] == "inc-2"
    # awaiting_approval is a derived status: requires_human_approval=True
    # and approval_granted is None and raw status is "running".
    assert data["items"][1]["status"] == "awaiting_approval"


@pytest.mark.asyncio
async def test_list_incidents_with_status_filter(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/incidents?status=resolved` filters to resolved only."""
    client, mock_runner = client_healthy

    s1 = _make_state("inc-1", "resolved")
    s2 = _make_state("inc-2", "running", approval=True)

    mock_runner.list_incidents.return_value = [
        ("inc-1", s1),
        ("inc-2", s2),
    ]

    response = await client.get("/incidents?status=resolved")
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 1
    assert len(data["items"]) == 1
    assert data["items"][0]["status"] == "resolved"


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_metrics_summary_contract(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/metrics/summary` exposes every field the UI reads."""
    client, mock_runner = client_healthy
    mock_runner.list_incidents.return_value = []

    response = await client.get("/metrics/summary")
    assert response.status_code == 200
    data = response.json()

    required = {
        "total_incidents",
        "resolved_count",
        "awaiting_approval_count",
        "failed_count",
        "no_action_count",
        "avg_mttr_seconds",
        "avg_wall_clock_seconds",
        "avg_backoff_seconds",
        "baseline_mttr_seconds",
        "mttr_reduction_pct",
        "total_cost_usd",
        "total_tokens",
        "safety_violations",
        "incidents_by_category",
    }
    missing = required - set(data.keys())
    assert not missing, f"missing fields: {sorted(missing)}"


@pytest.mark.asyncio
async def test_metrics_timeseries_ordered(
    client_healthy: tuple[AsyncClient, AsyncMock],
) -> None:
    """`/metrics/timeseries` returns chronological buckets."""
    client, mock_runner = client_healthy
    mock_runner.list_incidents.return_value = []

    response = await client.get("/metrics/timeseries?range=24h")
    assert response.status_code == 200
    data = response.json()
    timestamps = [b["timestamp"] for b in data["buckets"]]
    assert timestamps == sorted(timestamps)
