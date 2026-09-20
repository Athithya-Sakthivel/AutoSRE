"""Global pytest configuration and fixtures for AutoSRE test suite.

This module provides:
- Test database session (async PostgreSQL via testcontainers)
- Mock Kubernetes client
- Mock LiteLLM router with scripted responses
- Environment isolation (monkeypatched settings)
- Common test utilities
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Iterator
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from testcontainers.community.postgres import PostgresContainer

from autosre.config import get_settings
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import SREContext

# ============================================================================
# Event Loop Fixture
# ============================================================================


@pytest.fixture(scope="session")
def event_loop() -> Iterator[asyncio.AbstractEventLoop]:
    """Create a session-scoped event loop for async tests."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


# ============================================================================
# Environment Isolation
# ============================================================================


@pytest.fixture(autouse=True)
def _isolated_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide deterministic settings values and clear cached settings."""
    # Set minimal required environment variables
    monkeypatch.setenv("LLM_API_KEY", "test-key-for-unit-tests")
    monkeypatch.setenv("LLM_BASE_URL", "https://api.groq.com/openai/v1")
    monkeypatch.setenv("LLM_PROVIDER", "groq")
    monkeypatch.setenv("LLM_MODEL_COORDINATOR", "qwen/qwen3.8-27b")
    monkeypatch.setenv("LLM_MODEL_WORKER", "groq/compound")

    monkeypatch.setenv("POSTGRES_HOST", "localhost")
    monkeypatch.setenv("POSTGRES_PORT", "5432")
    monkeypatch.setenv("POSTGRES_USER", "test_user")
    monkeypatch.setenv("POSTGRES_PASSWORD", "test_password")
    monkeypatch.setenv("POSTGRES_DB", "test_db")

    monkeypatch.setenv("OPENOBSERVE_EMAIL", "test@example.com")
    monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test_password")
    monkeypatch.setenv("OPENOBSERVE_URL", "http://localhost:5080")

    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
    monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "autosre-agent-test")

    monkeypatch.setenv("MAX_RISK_TIER_AUTONOMOUS", "1")
    monkeypatch.setenv("MAX_ACTIONS_PER_INCIDENT", "10")
    monkeypatch.setenv("MAX_WALL_CLOCK_SECONDS", "600")

    monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "test-webhook-secret")

    # Clear cached settings (only if get_settings uses @lru_cache)
    if hasattr(get_settings, "cache_clear"):
        get_settings.cache_clear()

    yield

    # Clear cached settings after test
    if hasattr(get_settings, "cache_clear"):
        get_settings.cache_clear()


# ============================================================================
# Test Database
# ============================================================================


@pytest.fixture(scope="session")
def postgres_container() -> Iterator[PostgresContainer]:
    """Start a PostgreSQL container for integration tests."""
    with PostgresContainer(
        image="postgres:16-alpine",
        dbname="test_autosre",
        username="test_user",
        password="test_password",
    ) as postgres:
        yield postgres


@pytest_asyncio.fixture
async def test_db_session(postgres_container: PostgresContainer) -> AsyncIterator[Any]:
    """Provide an async database session for integration tests."""
    from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
    from sqlalchemy.orm import sessionmaker

    # Build connection string
    host = postgres_container.get_container_host_ip()
    port = postgres_container.get_exposed_port(5432)
    connection_string = f"postgresql+asyncpg://test_user:test_password@{host}:{port}/test_autosre"

    # Create engine and session
    engine = create_async_engine(connection_string, echo=False)
    async_session_maker = sessionmaker(
        engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )

    async with async_session_maker() as session:
        yield session

    await engine.dispose()


# ============================================================================
# Mock Clients
# ============================================================================


@pytest.fixture
def mock_k8s_client() -> MagicMock:
    """Provide a mock Kubernetes client."""
    client = MagicMock()

    # Mock common operations
    client.list_pods = AsyncMock(return_value=[])
    client.get_pod_logs = AsyncMock(return_value="Mock log output")
    client.get_deployment = AsyncMock(
        return_value={
            "metadata": {"name": "test-deployment"},
            "spec": {"replicas": 3},
            "status": {"availableReplicas": 3},
        }
    )

    return client


@pytest.fixture
def mock_valkey_client() -> MagicMock:
    """Provide a mock Valkey/Redis client."""
    client = MagicMock()

    # Mock common operations
    client.get = AsyncMock(return_value=None)
    client.set = AsyncMock(return_value=True)
    client.delete = AsyncMock(return_value=1)
    client.keys = AsyncMock(return_value=[])

    return client


@pytest.fixture
def mock_llm_router() -> MagicMock:
    """Provide a mock LLM router with scripted responses."""
    router = MagicMock(spec=TokenVelocityRouter)

    # Mock acompletion
    mock_response = MagicMock()
    mock_response.choices = [
        MagicMock(
            message=MagicMock(
                content='{"tool_name": "get_pod_logs", "tool_args": {"namespace": "default", "pod_name": "test-pod"}}'
            )
        )
    ]

    router.acompletion = AsyncMock(return_value=mock_response)

    return router


@pytest.fixture
def mock_openobserve_client() -> MagicMock:
    """Provide a mock OpenObserve client."""
    client = MagicMock()

    # Mock search operation
    client.search = AsyncMock(
        return_value={"hits": [{"timestamp": "2026-01-01T00:00:00Z", "message": "Test log entry"}]}
    )

    return client


# ============================================================================
# SREContext Fixture
# ============================================================================


@pytest_asyncio.fixture
async def sre_context(
    test_db_session: Any,
    mock_k8s_client: MagicMock,
    mock_valkey_client: MagicMock,
    mock_llm_router: MagicMock,
    mock_openobserve_client: MagicMock,
) -> SREContext:
    """Provide a fully configured SREContext with mocked clients."""
    return SREContext(
        db_session=test_db_session,
        k8s_client=mock_k8s_client,
        valkey_client=mock_valkey_client,
        llm_router=mock_llm_router,
        openobserve_client=mock_openobserve_client,
    )


# ============================================================================
# Utility Fixtures
# ============================================================================


@pytest.fixture
def sample_alert_metadata() -> dict[str, Any]:
    """Provide sample alert metadata for testing."""
    return {
        "incident_id": "test-incident-001",
        "alert_name": "HighLatency",
        "service": "api-gateway",
        "namespace": "production",
        "severity": "sev2",
        "started_at": "2026-01-15T10:30:00Z",
        "fingerprint": "test-fingerprint-123",
    }


@pytest.fixture
def sample_tool_registry() -> MagicMock:
    """Provide a mock tool registry with sample tools."""
    registry = MagicMock()

    # Mock tools
    mock_tools = [
        MagicMock(
            name="get_pod_logs",
            description="Fetch logs from a pod",
            risk_tier=0,
            input_model=MagicMock(model_json_schema=lambda: {"type": "object"}),
        ),
        MagicMock(
            name="restart_deployment",
            description="Restart a deployment",
            risk_tier=1,
            input_model=MagicMock(model_json_schema=lambda: {"type": "object"}),
        ),
    ]

    registry.list_tools = AsyncMock(return_value=mock_tools)
    registry.get = AsyncMock(
        side_effect=lambda name: next((t for t in mock_tools if t.name == name), None)
    )

    return registry


@pytest.fixture
def sample_policy_engine() -> MagicMock:
    """Provide a mock policy engine."""
    engine = MagicMock()

    # Mock decision
    mock_decision = MagicMock()
    mock_decision.risk_tier = 1
    mock_decision.requires_approval = False

    engine.classify_action = AsyncMock(return_value=mock_decision)

    return engine


@pytest.fixture
def sample_safe_executor() -> MagicMock:
    """Provide a mock safe executor."""
    executor = MagicMock()

    # Mock execution result
    mock_result = MagicMock()
    mock_result.success = True
    mock_result.verified = True
    mock_result.output = {"status": "success"}

    executor.execute = AsyncMock(return_value=mock_result)

    return executor


# ============================================================================
# Test Markers
# ============================================================================


def pytest_configure(config: pytest.Config) -> None:
    """Register custom pytest markers."""
    config.addinivalue_line("markers", "unit: marks tests as unit tests (fast)")
    config.addinivalue_line(
        "markers", "integration: marks tests as integration tests (requires containers)"
    )
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
