"""Integration tests for FastAPI API surface."""

from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from autosre.api.main import create_app
from autosre.api.runner import StubIncidentRunner
from autosre.config import Settings, get_settings

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def test_settings(monkeypatch: pytest.MonkeyPatch) -> Settings:
    """Create deterministic test settings via environment variables."""
    # LLM
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.setenv("LLM_BASE_URL", "https://api.groq.com/openai/v1")
    monkeypatch.setenv("LLM_PROVIDER", "groq")
    monkeypatch.setenv("LLM_MODEL_COORDINATOR", "qwen/qwen3.8-27b")
    monkeypatch.setenv("LLM_MODEL_WORKER", "openai/gpt-oss-20b")

    # Postgres
    monkeypatch.setenv("POSTGRES_HOST", "localhost")
    monkeypatch.setenv("POSTGRES_PORT", "5432")
    monkeypatch.setenv("POSTGRES_DB", "autosre_test")
    monkeypatch.setenv("POSTGRES_USER", "autosre_test")
    monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")

    # OpenObserve
    monkeypatch.setenv("OPENOBSERVE_EMAIL", "test@example.com")
    monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
    monkeypatch.setenv("OPENOBSERVE_URL", "http://localhost:5080")

    # OTel
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "autosre-agent-test")
    monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "")

    # Safety
    monkeypatch.setenv("MAX_RISK_TIER_AUTONOMOUS", "1")
    monkeypatch.setenv("MAX_ACTIONS_PER_INCIDENT", "10")
    monkeypatch.setenv("MAX_WALL_CLOCK_SECONDS", "600")

    # Alert
    monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "test-secret")

    # Environment
    monkeypatch.setenv("DEPLOYMENT_ENVIRONMENT", "test")

    # Valkey (read directly from env in main.py)
    monkeypatch.setenv("VALKEY_HOST", "localhost")
    monkeypatch.setenv("VALKEY_PORT", "6379")
    monkeypatch.setenv("VALKEY_PASSWORD", "test-pass")
    monkeypatch.setenv("VALKEY_TLS", "false")

    return get_settings()


class _FakeCursor:
    """Minimal async cursor for readiness tests."""

    async def __aenter__(self) -> _FakeCursor:
        return self

    async def __aexit__(self, *_args: Any) -> None:
        return None

    async def execute(self, query: str) -> None:
        pass


class _FakeConnection:
    """Minimal async connection for readiness tests."""

    def cursor(self) -> _FakeCursor:
        return _FakeCursor()

    async def __aenter__(self) -> _FakeConnection:
        return self

    async def __aexit__(self, *_args: Any) -> None:
        return None


class _FakePool:
    """Minimal psycopg-style async connection pool."""

    def connection(self) -> _FakeConnection:
        return _FakeConnection()


@pytest.fixture
def app(test_settings: Settings) -> Any:
    """Create the app with route-level dependencies injected."""
    application = create_app(test_settings)

    # Inject route-level dependencies (lifespan is not entered in tests)
    application.state.runner = StubIncidentRunner()
    application.state.pg_pool = _FakePool()

    return application


@pytest_asyncio.fixture
async def client(app: Any) -> Any:
    """Create an async HTTPX client against the ASGI application."""
    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport,
        base_url="http://testserver",
    ) as ac:
        yield ac


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def signed_json(
    payload: dict[str, Any],
    secret: str,
) -> tuple[bytes, dict[str, str]]:
    """Serialize JSON once and sign those exact bytes."""
    body = json.dumps(
        payload,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")

    digest = hmac.new(
        secret.encode("utf-8"),
        body,
        hashlib.sha256,
    ).hexdigest()

    return body, {
        "Content-Type": "application/json",
        "X-Webhook-Signature": f"sha256={digest}",
    }


def _valid_alert_payload() -> dict[str, Any]:
    """Return a minimal valid alert payload."""
    return {
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "sev2",
        "started_at": "2026-01-15T10:30:00Z",
        "fingerprint": "latency-456",
        "description": "P99 latency exceeded threshold",
        "labels": {"team": "platform"},
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_healthz(client: Any) -> None:
    """Liveness endpoint returns 200 without lifespan."""
    response = await client.get("/healthz")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["version"] == "0.1.0"


@pytest.mark.asyncio
async def test_alert_ingress_valid_signature(
    client: Any,
    app: Any,
    test_settings: Settings,
) -> None:
    """A correctly signed alert is accepted and recorded."""
    alert_payload = _valid_alert_payload()

    secret = test_settings.alert.webhook_secret.get_secret_value()
    body, headers = signed_json(alert_payload, secret)

    response = await client.post("/alerts", content=body, headers=headers)

    assert response.status_code == 202
    data = response.json()
    incident_id = data["incident_id"]

    assert data["status"] == "accepted"
    assert data["message"] == "Investigation started"
    assert len(incident_id) == 36  # UUID format

    # Verify the stub runner recorded the incident
    incident = app.state.runner.get_incident(incident_id)
    assert incident is not None
    assert incident["phase"] == "awaiting_approval"
    assert incident["alert"]["alert_name"] == "HighLatency"
    assert incident["alert"]["service"] == "api-gateway"


@pytest.mark.asyncio
async def test_alert_ingress_invalid_signature(
    client: Any,
    test_settings: Settings,
) -> None:
    """A forged signature is rejected with 401."""
    alert_payload = _valid_alert_payload()

    body = json.dumps(alert_payload).encode("utf-8")

    response = await client.post(
        "/alerts",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-Webhook-Signature": "sha256=invalid",
        },
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid webhook signature"


@pytest.mark.asyncio
async def test_alert_ingress_missing_signature(
    client: Any,
    test_settings: Settings,
) -> None:
    """A missing signature header is rejected with 401."""
    # Use a VALID payload body so FastAPI body validation passes.
    # The 401 must come from our signature check, not from 422 body validation.
    alert_payload = _valid_alert_payload()
    body = json.dumps(alert_payload).encode("utf-8")

    response = await client.post(
        "/alerts",
        content=body,
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid webhook signature"


@pytest.mark.asyncio
async def test_alert_ingress_valid_signature_then_invalid_payload(
    client: Any,
    test_settings: Settings,
) -> None:
    """A valid signature with an invalid body returns 422 (validation error)."""
    # Valid signature, but body is missing required fields
    payload = {"alert_name": "HighLatency"}

    secret = test_settings.alert.webhook_secret.get_secret_value()
    body, headers = signed_json(payload, secret)

    response = await client.post("/alerts", content=body, headers=headers)

    assert response.status_code == 422
    assert "detail" in response.json()


@pytest.mark.asyncio
async def test_hitl_approval_endpoint(
    client: Any,
    app: Any,
    test_settings: Settings,
) -> None:
    """A signed approval moves a paused incident to approved."""
    secret = test_settings.alert.webhook_secret.get_secret_value()

    # Step 1: Create an incident via alert ingress
    alert_body, alert_headers = signed_json(
        _valid_alert_payload(),
        secret,
    )

    alert_response = await client.post("/alerts", content=alert_body, headers=alert_headers)
    assert alert_response.status_code == 202
    incident_id = alert_response.json()["incident_id"]

    # Step 2: Approve the incident
    approval_body, approval_headers = signed_json(
        {"approved": True, "comment": "Approved by on-call engineer"},
        secret,
    )

    response = await client.post(
        f"/incidents/{incident_id}/approve",
        content=approval_body,
        headers=approval_headers,
    )

    assert response.status_code == 200
    data = response.json()
    assert data["incident_id"] == incident_id
    assert data["approved"] is True
    assert data["status"] == "approved"

    # Verify the stub recorded the approval
    incident = app.state.runner.get_incident(incident_id)
    assert incident is not None
    assert incident["phase"] == "approved"
    assert incident["approval"] is not None
    assert incident["approval"]["approved"] is True
    assert incident["approval"]["comment"] == "Approved by on-call engineer"


@pytest.mark.asyncio
async def test_hitl_rejection_endpoint(
    client: Any,
    app: Any,
    test_settings: Settings,
) -> None:
    """A signed rejection records the decision."""
    secret = test_settings.alert.webhook_secret.get_secret_value()

    # Create incident
    alert_body, alert_headers = signed_json(_valid_alert_payload(), secret)
    alert_response = await client.post("/alerts", content=alert_body, headers=alert_headers)
    incident_id = alert_response.json()["incident_id"]

    # Reject it
    rejection_body, rejection_headers = signed_json(
        {"approved": False, "comment": "False positive, ignoring"},
        secret,
    )

    response = await client.post(
        f"/incidents/{incident_id}/approve",
        content=rejection_body,
        headers=rejection_headers,
    )

    assert response.status_code == 200
    assert response.json()["approved"] is False
    assert response.json()["status"] == "rejected"

    incident = app.state.runner.get_incident(incident_id)
    assert incident is not None
    assert incident["phase"] == "rejected"


@pytest.mark.asyncio
async def test_hitl_approval_requires_signature(client: Any) -> None:
    """The HITL webhook cannot be invoked without a signature."""
    approval_body = json.dumps({"approved": True, "comment": "Approved"}).encode("utf-8")

    response = await client.post(
        "/incidents/nonexistent-id/approve",
        content=approval_body,
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_hitl_approval_unknown_incident(
    client: Any,
    test_settings: Settings,
) -> None:
    """A signed approval for an unknown incident returns 404."""
    secret = test_settings.alert.webhook_secret.get_secret_value()

    body, headers = signed_json(
        {"approved": True, "comment": "Approved"},
        secret,
    )

    response = await client.post(
        "/incidents/nonexistent-id/approve",
        content=body,
        headers=headers,
    )

    assert response.status_code == 404
    assert "not found" in response.json()["detail"]


@pytest.mark.asyncio
async def test_hitl_duplicate_approval_is_rejected(
    client: Any,
    test_settings: Settings,
) -> None:
    """An incident accepts only one HITL decision."""
    secret = test_settings.alert.webhook_secret.get_secret_value()

    # Create incident
    alert_body, alert_headers = signed_json(_valid_alert_payload(), secret)
    alert_response = await client.post("/alerts", content=alert_body, headers=alert_headers)
    incident_id = alert_response.json()["incident_id"]

    # First approval
    approval_body, approval_headers = signed_json(
        {"approved": True, "comment": "Approved"},
        secret,
    )
    first = await client.post(
        f"/incidents/{incident_id}/approve",
        content=approval_body,
        headers=approval_headers,
    )
    assert first.status_code == 200

    # Second approval (should fail — incident no longer awaiting)
    rejection_body, rejection_headers = signed_json(
        {"approved": False, "comment": "Changed mind"},
        secret,
    )
    second = await client.post(
        f"/incidents/{incident_id}/approve",
        content=rejection_body,
        headers=rejection_headers,
    )
    assert second.status_code == 404


@pytest.mark.asyncio
async def test_readyz(client: Any) -> None:
    """Readiness reports Postgres connectivity."""
    response = await client.get("/readyz")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ready",
        "checks": {"postgres": "ok"},
    }
