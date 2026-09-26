"""Global pytest configuration and fixtures for the AutoSRE test suite.

Environment isolation uses the same env-var convention as
``autosre.config.Settings``: ``AUTOSRE_<SECTION>__<FIELD>`` (double
underscore nested delimiter). Any fixture that touches Settings must
either use these names or call ``reset_settings_cache()`` before use.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest

from autosre.config import get_settings, reset_settings_cache
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import SREContext

# ============================================================================
# Environment isolation
# ============================================================================


@pytest.fixture(autouse=True)
def _isolated_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide deterministic settings values and clear the settings cache.

    Uses AUTOSRE_ prefixed names with ``__`` nested delimiter so that
    ``Settings()`` reads the values without additional mapping.
    """
    values = {
        # LLM
        "AUTOSRE_LLM__API_KEY": "test-key-for-unit-tests",
        "AUTOSRE_LLM__BASE_URL": "https://api.groq.com/openai/v1",
        "AUTOSRE_LLM__PROVIDER": "groq",
        "AUTOSRE_LLM__MODEL_COORDINATOR": "qwen/qwen3.8-27b",
        "AUTOSRE_LLM__MODEL_WORKER": "openai/gpt-oss-20b",
        # Postgres
        "AUTOSRE_POSTGRES__HOST": "localhost",
        "AUTOSRE_POSTGRES__PORT": "5432",
        "AUTOSRE_POSTGRES__USER": "test_user",
        "AUTOSRE_POSTGRES__PASSWORD": "test_password",
        "AUTOSRE_POSTGRES__DB": "test_db",
        # OpenObserve
        "AUTOSRE_OPENOBSERVE__EMAIL": "test@example.com",
        "AUTOSRE_OPENOBSERVE__PASSWORD": "test_password",
        "AUTOSRE_OPENOBSERVE__URL": "http://localhost:5080",
        # OTel
        "AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
        "AUTOSRE_OTEL__EXPORTER_OTLP_HEADERS": "",
        "AUTOSRE_OTEL__SERVICE_NAME": "autosre-agent-test",
        "AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT": "test",
        # Safety
        "AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS": "1",
        "AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT": "10",
        "AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS": "600",
        # Alert
        "AUTOSRE_ALERT__WEBHOOK_SECRET": "test-webhook-secret",
    }

    for key, value in values.items():
        monkeypatch.setenv(key, value)

    reset_settings_cache()
    yield
    reset_settings_cache()


# ============================================================================
# Mock clients
# ============================================================================


@pytest.fixture
def mock_k8s_client() -> MagicMock:
    """Mock kr8s.asyncio.Api with the surface our tools actually use.

    The k8s tools call ``client.get("pods", namespace=..., raw=True)`` which
    returns an async iterable, and ``Pod.get(name, namespace=..., api=client)``.
    """
    client = MagicMock()

    async def _empty_iter() -> Any:
        return
        yield  # pragma: no cover -- async generator shape only

    client.get = MagicMock(return_value=_empty_iter())
    client.version = AsyncMock(return_value={"gitVersion": "v1.31.0"})
    return client


@pytest.fixture
def mock_valkey_client() -> MagicMock:
    """Mock redis.asyncio.Redis with the surface our tools actually use."""
    client = MagicMock()

    client.info = AsyncMock(return_value={})
    client.xlen = AsyncMock(return_value=0)
    client.xinfo_groups = AsyncMock(return_value=[])
    client.delete = AsyncMock(return_value=0)
    client.aclose = AsyncMock(return_value=None)
    return client


@pytest.fixture
def mock_llm_router() -> MagicMock:
    """Mock TokenVelocityRouter with a scripted tool-selection response."""
    router = MagicMock(spec=TokenVelocityRouter)

    response = MagicMock()
    response.choices = [
        MagicMock(
            message=MagicMock(
                content=(
                    '{"tool_name": "get_pod_logs", '
                    '"tool_args": {"namespace": "rivulet", "pod_name": "test-pod"}}'
                )
            )
        )
    ]
    response.usage = None

    router.acompletion = AsyncMock(return_value=response)
    router.coordinator_call = AsyncMock(return_value=response)
    return router


@pytest.fixture
def mock_openobserve_client() -> MagicMock:
    """Mock OpenObserveClient with the surface our tools actually use."""
    client = MagicMock()

    client.query = AsyncMock(return_value={"hits": [], "total": 0})
    client.close = AsyncMock(return_value=None)
    return client


# ============================================================================
# SREContext
# ============================================================================


@pytest.fixture
def sre_context(
    mock_k8s_client: MagicMock,
    mock_valkey_client: MagicMock,
    mock_llm_router: MagicMock,
    mock_openobserve_client: MagicMock,
) -> SREContext:
    """Fully populated SREContext with mocked external dependencies.

    ``pg_pool`` and ``llm_config`` are left as None; tools that require them
    will raise ToolExecutionError, which is the expected behavior in tests
    that don't wire Postgres.
    """
    return SREContext(
        db_session=None,
        k8s_client=mock_k8s_client,
        valkey_client=mock_valkey_client,
        llm_router=mock_llm_router,
        openobserve_client=mock_openobserve_client,
        pg_pool=None,
        llm_config=get_settings().llm,
    )


# ============================================================================
# Sample data
# ============================================================================


@pytest.fixture
def sample_alert_metadata() -> dict[str, Any]:
    """Sample alert metadata for graph and API tests."""
    return {
        "incident_id": "test-incident-001",
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "rivulet",
        "severity": "sev2",
        "started_at": "2026-09-25T10:30:00Z",
        "fingerprint": "test-fingerprint-123",
        "description": "p99 latency above SLO",
        "labels": {"category": "high_latency"},
        "annotations": {},
    }


@pytest.fixture
def sample_tool_registry() -> MagicMock:
    """Mock ToolRegistry with two tools (one read-only, one Tier-1)."""
    registry = MagicMock()

    read_tool = MagicMock(
        name="get_pod_logs",
        description="Fetch logs from a pod",
        risk_tier=0,
        input_model=MagicMock(model_json_schema=lambda: {"type": "object"}),
        to_openai_schema=MagicMock(return_value={"type": "function", "function": {}}),
    )
    write_tool = MagicMock(
        name="restart_deployment",
        description="Restart a deployment",
        risk_tier=1,
        input_model=MagicMock(model_json_schema=lambda: {"type": "object"}),
        to_openai_schema=MagicMock(return_value={"type": "function", "function": {}}),
    )

    registry.list_tools = MagicMock(return_value=[read_tool, write_tool])
    registry.get = MagicMock(
        side_effect=lambda name: next((t for t in (read_tool, write_tool) if t.name == name), None)
    )
    return registry


@pytest.fixture
def sample_policy_engine() -> MagicMock:
    """Mock PolicyEngine.

    Uses the real method name ``classify`` (not ``classify_action``) and
    returns a decision matching the real PolicyDecision shape.
    """
    from autosre.safety.policy import PolicyDecision, RiskTier

    engine = MagicMock()
    engine.classify = MagicMock(
        return_value=PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_LOW,
            requires_approval=False,
            reason="mock classification",
        )
    )
    return engine


@pytest.fixture
def sample_safe_executor() -> MagicMock:
    """Mock SafeExecutor returning a successful ExecutionResult shape."""
    from autosre.safety.executor import ExecutionResult

    executor = MagicMock()

    def _build_result(action, decision):
        return ExecutionResult(
            action=action,
            decision=decision,
            executed=True,
            verified=True,
            rolled_back=False,
            error=None,
            output={"status": "success"},
        )

    executor.execute = AsyncMock(side_effect=_build_result)
    return executor


# ============================================================================
# Markers
# ============================================================================


def pytest_configure(config: pytest.Config) -> None:
    """Register custom pytest markers."""
    config.addinivalue_line("markers", "unit: marks tests as unit tests (fast)")
    config.addinivalue_line(
        "markers",
        "integration: marks tests as integration tests (requires containers)",
    )
    config.addinivalue_line(
        "markers",
        "slow: marks tests as slow (deselect with '-m \"not slow\"')",
    )
