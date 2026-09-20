"""Integration tests for Valkey tools against a real Valkey container."""

from __future__ import annotations

import warnings
from collections.abc import AsyncIterator
from typing import Any

import pytest
import pytest_asyncio
from redis.asyncio import Redis
from testcontainers.core.container import DockerContainer
from testcontainers.core.waiting_utils import wait_for_logs

from autosre.core.state import SREContext
from autosre.tools import valkey as valkey_tools
from autosre.tools.registry import ToolExecutionError, ToolRegistry

_VALKEY_IMAGE = "docker.io/valkey/valkey:9.1.2-alpine@sha256:a0dbf4c1d5708782907c10e2c72deff317518518b5288a58416981d9db95d30b"


@pytest.fixture(scope="session")
def valkey_container() -> Any:
    """Run a pinned Valkey 9 container for the test session.

    Uses ``wait_for_logs`` which is the only wait-strategy API exported by
    the installed testcontainers version. The deprecation warning is
    suppressed because no structured alternative exists in this release.
    """
    container = DockerContainer(_VALKEY_IMAGE).with_exposed_ports(6379)

    with container:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            wait_for_logs(container, "Ready to accept connections", timeout=30)
        yield container


@pytest_asyncio.fixture
async def valkey_client(valkey_container: Any) -> AsyncIterator[Redis]:
    """Create and close an async Redis-compatible client."""
    client = Redis(
        host=valkey_container.get_container_host_ip(),
        port=int(valkey_container.get_exposed_port(6379)),
        decode_responses=True,
    )

    # Belt-and-braces: ping loop in case the log-ready signal fires before
    # the socket is fully accepting.
    for _ in range(20):
        try:
            await client.ping()
            break
        except Exception:
            import asyncio

            await asyncio.sleep(0.25)
    else:
        await client.aclose()
        raise RuntimeError("Valkey container did not respond to PING")

    await client.flushdb()

    try:
        yield client
    finally:
        await client.aclose()


@pytest_asyncio.fixture
async def context(valkey_client: Redis) -> SREContext:
    """Build an SREContext carrying the Valkey client."""
    from unittest.mock import AsyncMock

    ctx = SREContext(db_session=AsyncMock())  # type: ignore[arg-type]
    ctx.valkey_client = valkey_client  # type: ignore[attr-defined]
    return ctx


@pytest_asyncio.fixture
async def registry(context: SREContext) -> ToolRegistry:
    """Registry with only the Valkey tools registered."""
    reg = ToolRegistry()
    valkey_tools.register(reg, context)
    return reg


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_valkey_stats_returns_shape(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    result = await registry.execute("get_valkey_stats", {}, context=context)
    stats = result["stats"]
    assert stats["used_memory_bytes"] >= 0
    assert stats["connected_clients"] >= 1
    assert 0.0 <= stats["hit_rate"] <= 1.0


@pytest.mark.asyncio
async def test_delete_valkey_key_deletes_exact_key(
    registry: ToolRegistry,
    context: SREContext,
    valkey_client: Redis,
) -> None:
    await valkey_client.set("poison:test", "1")  # type: ignore[attr-defined]

    result = await registry.execute(
        "delete_valkey_key",
        {"key": "poison:test", "reason": "integration test"},
        context=context,
    )
    assert result["deleted"] is True
    assert await valkey_client.exists("poison:test") == 0  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_delete_valkey_key_rejects_pattern_syntax(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    with pytest.raises(ToolExecutionError, match="pattern keys"):
        await registry.execute(
            "delete_valkey_key",
            {"key": "poison:*", "reason": "must not pattern match"},
            context=context,
        )


@pytest.mark.asyncio
async def test_set_feature_flag_sets_value_and_ttl(
    registry: ToolRegistry,
    context: SREContext,
    valkey_client: Redis,
) -> None:
    result = await registry.execute(
        "set_feature_flag",
        {"key": "feature:checkout", "value": "true", "ttl_seconds": 300},
        context=context,
    )
    assert result["value"] == "true"
    assert await valkey_client.get("feature:checkout") == "true"  # type: ignore[attr-defined]

    ttl = await valkey_client.ttl("feature:checkout")  # type: ignore[attr-defined]
    assert 0 < ttl <= 300


@pytest.mark.asyncio
async def test_set_feature_flag_rejects_non_feature_key(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    with pytest.raises(ToolExecutionError, match="feature:"):
        await registry.execute(
            "set_feature_flag",
            {"key": "cache:checkout", "value": "true"},
            context=context,
        )
