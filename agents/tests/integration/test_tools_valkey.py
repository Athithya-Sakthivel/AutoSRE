"""Integration tests for Valkey (Redis-compatible) tools."""

from __future__ import annotations

from typing import Any

import pytest

from autosre.core.state import SREContext
from autosre.tools.registry import (
    ToolExecutionError,
    ToolNotFoundError,
    ToolRegistry,
)
from autosre.tools.valkey import register

# ---------------------------------------------------------------------------
# Fake Valkey client
# ---------------------------------------------------------------------------


class FakeValkeyClient:
    """In-memory Valkey client for testing."""

    def __init__(self) -> None:
        self._data: dict[str, str] = {}
        self._delete_return: int = 1
        self._info_memory: dict[str, Any] = {
            "used_memory": 104857600,  # 100 MB
            "maxmemory": 1073741824,  # 1 GB
        }
        self._info_clients: dict[str, Any] = {
            "connected_clients": 5,
        }
        self._info_keyspace: dict[str, Any] = {
            "db0": {"keys": 42},
        }
        self._info_stats: dict[str, Any] = {
            "evicted_keys": 10,
            "keyspace_hits": 900,
            "keyspace_misses": 100,
        }
        self._xlen_return: int = 100
        self._xinfo_groups_return: list[dict[str, Any]] = [
            {
                "name": "ingestion-workers",
                "consumers": 3,
                "pending": 50,
                "last-delivered-id": "1234567890-0",
                "lag": 25,
            }
        ]

    async def info(self, section: str) -> dict[str, Any]:
        if section == "memory":
            return self._info_memory
        if section == "clients":
            return self._info_clients
        if section == "keyspace":
            return self._info_keyspace
        if section == "stats":
            return self._info_stats
        return {}

    async def xlen(self, key: str) -> int:
        return self._xlen_return

    async def xinfo_groups(self, key: str) -> list[dict[str, Any]]:
        return self._xinfo_groups_return

    async def delete(self, key: str) -> int:
        if key in self._data:
            del self._data[key]
            return 1
        return self._delete_return


def _make_context(
    valkey_client: FakeValkeyClient | None = None,
) -> SREContext:
    """Create a minimal SREContext for tool testing."""
    return SREContext(
        db_session=None,
        llm_config=None,
        k8s_client=None,
        llm_router=None,
        openobserve_client=None,
        pg_pool=None,
        valkey_client=valkey_client,
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_valkey_client() -> FakeValkeyClient:
    return FakeValkeyClient()


@pytest.fixture
def registry(fake_valkey_client: FakeValkeyClient) -> ToolRegistry:
    """Create a registry with all Valkey tools registered."""
    reg = ToolRegistry()
    register(reg, _make_context(valkey_client=fake_valkey_client))
    return reg


# ---------------------------------------------------------------------------
# get_valkey_stats tests
# ---------------------------------------------------------------------------


class TestGetValkeyStats:
    @pytest.mark.asyncio
    async def test_get_valkey_stats_returns_shape(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """get_valkey_stats returns memory, key count, hit rate, etc."""
        result = await registry.execute(
            "get_valkey_stats",
            {},
            _make_context(valkey_client=fake_valkey_client),
        )

        stats = result["stats"]
        assert stats["used_memory_mb"] >= 0
        assert stats["maxmemory_mb"] >= 0
        assert 0.0 <= stats["memory_usage_pct"] <= 100.0
        assert stats["connected_clients"] >= 0
        assert stats["total_keys"] >= 0
        assert 0.0 <= stats["hit_rate_pct"] <= 100.0
        assert stats["evicted_keys"] >= 0

    @pytest.mark.asyncio
    async def test_get_valkey_stats_computes_hit_rate(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """Hit rate is computed from keyspace_hits / (hits + misses)."""
        fake_valkey_client._info_stats["keyspace_hits"] = 900
        fake_valkey_client._info_stats["keyspace_misses"] = 100

        result = await registry.execute(
            "get_valkey_stats",
            {},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["stats"]["hit_rate_pct"] == 90.0

    @pytest.mark.asyncio
    async def test_get_valkey_stats_zero_operations(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """Zero hits + zero misses produces 0% hit rate, not division error."""
        fake_valkey_client._info_stats["keyspace_hits"] = 0
        fake_valkey_client._info_stats["keyspace_misses"] = 0

        result = await registry.execute(
            "get_valkey_stats",
            {},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["stats"]["hit_rate_pct"] == 0.0


# ---------------------------------------------------------------------------
# get_valkey_stream_info tests
# ---------------------------------------------------------------------------


class TestGetValkeyStreamInfo:
    @pytest.mark.asyncio
    async def test_get_valkey_stream_info_returns_shape(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """get_valkey_stream_info returns stream length and group info."""
        result = await registry.execute(
            "get_valkey_stream_info",
            {"stream_key": "rivulet.orders.in"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["stream_key"] == "rivulet.orders.in"
        assert result["stream_length"] == 100
        assert len(result["groups"]) == 1

        group = result["groups"][0]
        assert group["group_name"] == "ingestion-workers"
        assert group["consumers"] == 3
        assert group["pending_messages"] == 50
        assert group["lag_messages"] == 25
        assert group["last_delivered_id"] == "1234567890-0"

    @pytest.mark.asyncio
    async def test_get_valkey_stream_info_no_groups(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """Stream with no consumer groups returns empty groups list."""
        fake_valkey_client._xinfo_groups_return = []

        result = await registry.execute(
            "get_valkey_stream_info",
            {"stream_key": "empty-stream"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["stream_key"] == "empty-stream"
        assert result["groups"] == []

    @pytest.mark.asyncio
    async def test_get_valkey_stream_info_missing_stream(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """Missing stream returns empty groups, not an error."""
        original = fake_valkey_client.xinfo_groups

        async def raise_missing(key: str) -> list[dict[str, Any]]:
            raise Exception("no such key")

        fake_valkey_client.xinfo_groups = raise_missing  # type: ignore[assignment]

        result = await registry.execute(
            "get_valkey_stream_info",
            {"stream_key": "nonexistent"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["groups"] == []

        # Restore
        fake_valkey_client.xinfo_groups = original  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# delete_valkey_key tests
# ---------------------------------------------------------------------------


class TestDeleteValkeyKey:
    @pytest.mark.asyncio
    async def test_delete_valkey_key_deletes_existing(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """delete_valkey_key returns deleted=True for existing key."""
        fake_valkey_client._data["cache:session:abc123"] = "value"

        result = await registry.execute(
            "delete_valkey_key",
            {"key": "cache:session:abc123", "reason": "poison key removal"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["deleted"] is True
        assert result["key"] == "cache:session:abc123"
        assert result["reason"] == "poison key removal"

    @pytest.mark.asyncio
    async def test_delete_valkey_key_missing_key(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """delete_valkey_key returns deleted=False for missing key."""
        fake_valkey_client._delete_return = 0

        result = await registry.execute(
            "delete_valkey_key",
            {"key": "nonexistent:key", "reason": "cleanup"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["deleted"] is False
        assert result["key"] == "nonexistent:key"

    @pytest.mark.asyncio
    async def test_delete_valkey_key_requires_reason(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """delete_valkey_key rejects empty reason."""
        with pytest.raises(ToolExecutionError):
            await registry.execute(
                "delete_valkey_key",
                {"key": "some:key", "reason": ""},
                _make_context(valkey_client=fake_valkey_client),
            )

    @pytest.mark.asyncio
    async def test_delete_valkey_key_requires_key(
        self,
        registry: ToolRegistry,
        fake_valkey_client: FakeValkeyClient,
    ) -> None:
        """delete_valkey_key rejects empty key."""
        with pytest.raises(ToolExecutionError):
            await registry.execute(
                "delete_valkey_key",
                {"key": "", "reason": "test"},
                _make_context(valkey_client=fake_valkey_client),
            )


# ---------------------------------------------------------------------------
# Registration tests
# ---------------------------------------------------------------------------


class TestRegistration:
    def test_all_tools_registered(self, registry: ToolRegistry) -> None:
        """All 3 Valkey tools are registered."""
        assert "get_valkey_stats" in registry
        assert "get_valkey_stream_info" in registry
        assert "delete_valkey_key" in registry

    def test_no_set_feature_flag_tool(self, registry: ToolRegistry) -> None:
        """set_feature_flag is NOT registered (Phase B deferred)."""
        assert "set_feature_flag" not in registry

    def test_missing_tool_raises_not_found(self, registry: ToolRegistry) -> None:
        """Requesting an unregistered tool raises ToolNotFoundError."""
        with pytest.raises(ToolNotFoundError):
            registry.get("nonexistent_tool")
