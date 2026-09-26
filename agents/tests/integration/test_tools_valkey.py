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


class FakeValkeyClient:
    """In-memory Valkey client for testing."""

    def __init__(self) -> None:
        self._data: dict[str, str] = {}
        self._info_memory: dict[str, Any] = {
            "used_memory": 104857600,
            "maxmemory": 1073741824,
        }
        self._info_clients: dict[str, Any] = {"connected_clients": 5}
        self._info_keyspace: dict[str, Any] = {"db0": {"keys": 42}}
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
        return {
            "memory": self._info_memory,
            "clients": self._info_clients,
            "keyspace": self._info_keyspace,
            "stats": self._info_stats,
        }.get(section, {})

    async def xlen(self, key: str) -> int:
        return self._xlen_return

    async def xinfo_groups(self, key: str) -> list[dict[str, Any]]:
        return self._xinfo_groups_return

    async def delete(self, key: str) -> int:
        if key in self._data:
            del self._data[key]
            return 1
        return 0

    async def exists(self, key: str) -> int:
        return 1 if key in self._data else 0


def _make_context(valkey_client: FakeValkeyClient | None = None) -> SREContext:
    return SREContext(valkey_client=valkey_client)


@pytest.fixture
def fake_valkey_client() -> FakeValkeyClient:
    return FakeValkeyClient()


@pytest.fixture
def registry(fake_valkey_client: FakeValkeyClient) -> ToolRegistry:
    reg = ToolRegistry()
    register(reg, _make_context(valkey_client=fake_valkey_client))
    return reg


# ---------------------------------------------------------------------------
# get_valkey_stats
# ---------------------------------------------------------------------------


class TestGetValkeyStats:
    @pytest.mark.asyncio
    async def test_returns_shape(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
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
    async def test_computes_hit_rate(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        fake_valkey_client._info_stats["keyspace_hits"] = 900
        fake_valkey_client._info_stats["keyspace_misses"] = 100
        result = await registry.execute(
            "get_valkey_stats",
            {},
            _make_context(valkey_client=fake_valkey_client),
        )
        assert result["stats"]["hit_rate_pct"] == 90.0

    @pytest.mark.asyncio
    async def test_zero_operations_no_div_error(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        fake_valkey_client._info_stats["keyspace_hits"] = 0
        fake_valkey_client._info_stats["keyspace_misses"] = 0
        result = await registry.execute(
            "get_valkey_stats",
            {},
            _make_context(valkey_client=fake_valkey_client),
        )
        assert result["stats"]["hit_rate_pct"] == 0.0


# ---------------------------------------------------------------------------
# get_valkey_stream_info
# ---------------------------------------------------------------------------


class TestGetValkeyStreamInfo:
    @pytest.mark.asyncio
    async def test_returns_shape(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
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
    async def test_no_groups(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        fake_valkey_client._xinfo_groups_return = []
        result = await registry.execute(
            "get_valkey_stream_info",
            {"stream_key": "empty-stream"},
            _make_context(valkey_client=fake_valkey_client),
        )
        assert result["groups"] == []

    @pytest.mark.asyncio
    async def test_missing_stream(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        original = fake_valkey_client.xinfo_groups

        async def raise_missing(key: str) -> list[dict[str, Any]]:
            raise Exception("no such key")

        fake_valkey_client.xinfo_groups = raise_missing  # type: ignore[assignment]
        try:
            result = await registry.execute(
                "get_valkey_stream_info",
                {"stream_key": "nonexistent"},
                _make_context(valkey_client=fake_valkey_client),
            )
            assert result["groups"] == []
        finally:
            fake_valkey_client.xinfo_groups = original  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# delete_valkey_key
# ---------------------------------------------------------------------------


class TestDeleteValkeyKey:
    @pytest.mark.asyncio
    async def test_deletes_existing_key(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        fake_valkey_client._data["cache:session:abc123"] = "value"

        result = await registry.execute(
            "delete_valkey_key",
            {"key": "cache:session:abc123", "reason": "poison key removal"},
            _make_context(valkey_client=fake_valkey_client),
        )

        assert result["deleted"] is True
        assert result["key"] == "cache:session:abc123"
        assert result["reason"] == "poison key removal"
        assert "cache:session:abc123" not in fake_valkey_client._data

    @pytest.mark.asyncio
    async def test_missing_key_reports_not_deleted(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        result = await registry.execute(
            "delete_valkey_key",
            {"key": "nonexistent:key", "reason": "cleanup"},
            _make_context(valkey_client=fake_valkey_client),
        )
        # The key was not present; deleted reflects that.
        assert result["deleted"] is False
        assert result["key"] == "nonexistent:key"

    @pytest.mark.asyncio
    async def test_requires_non_empty_reason(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        with pytest.raises(ToolExecutionError):
            await registry.execute(
                "delete_valkey_key",
                {"key": "some:key", "reason": ""},
                _make_context(valkey_client=fake_valkey_client),
            )

    @pytest.mark.asyncio
    async def test_requires_non_empty_key(
        self, registry: ToolRegistry, fake_valkey_client: FakeValkeyClient
    ) -> None:
        with pytest.raises(ToolExecutionError):
            await registry.execute(
                "delete_valkey_key",
                {"key": "", "reason": "test"},
                _make_context(valkey_client=fake_valkey_client),
            )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


class TestRegistration:
    def test_all_tools_registered(self, registry: ToolRegistry) -> None:
        assert "get_valkey_stats" in registry
        assert "get_valkey_stream_info" in registry
        assert "delete_valkey_key" in registry

    def test_set_feature_flag_not_registered(self, registry: ToolRegistry) -> None:
        assert "set_feature_flag" not in registry

    def test_missing_tool_raises(self, registry: ToolRegistry) -> None:
        with pytest.raises(ToolNotFoundError):
            registry.get("nonexistent_tool")
