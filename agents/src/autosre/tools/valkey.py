"""Valkey (Redis-compatible) diagnostic and targeted remediation tools.

Tools registered:
  Tier 0 (read-only): get_valkey_stats, get_valkey_stream_info
  Tier 1 (targeted mutation): delete_valkey_key

The client stored on ``SREContext.valkey_client`` must expose an
asyncio-compatible Valkey/Redis API (for example valkey-py or redis-py).
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any

from pydantic import BaseModel, Field

from autosre.core.state import SREContext
from autosre.tools.registry import Tool, ToolExecutionError, ToolInputModel, ToolRegistry

# ---------------------------------------------------------------------------
# Input / Output models
# ---------------------------------------------------------------------------


class GetValkeyStatsInput(ToolInputModel):
    """No parameters."""


class ValkeyStats(BaseModel):
    used_memory_mb: float
    maxmemory_mb: float
    memory_usage_pct: float
    connected_clients: int
    total_keys: int
    hit_rate_pct: float
    evicted_keys: int


class GetValkeyStatsOutput(BaseModel):
    stats: ValkeyStats


class GetValkeyStreamInfoInput(ToolInputModel):
    """Get consumer-group state for a Valkey stream."""

    stream_key: str = Field(min_length=1, max_length=500)


class ConsumerGroupInfo(BaseModel):
    group_name: str
    consumers: int
    pending_messages: int
    lag_messages: int | None = None
    last_delivered_id: str


class GetValkeyStreamInfoOutput(BaseModel):
    stream_key: str
    stream_length: int
    groups: list[ConsumerGroupInfo]


class DeleteValkeyKeyInput(ToolInputModel):
    key: str = Field(min_length=1, max_length=500)
    reason: str = Field(min_length=1, max_length=500)


class DeleteValkeyKeyOutput(BaseModel):
    key: str
    deleted: bool
    reason: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _valkey_client(context: SREContext) -> Any:
    """Return the Valkey client from SREContext."""
    client = getattr(context, "valkey_client", None)
    if client is None:
        raise ToolExecutionError(
            "valkey._valkey_client",
            RuntimeError("SREContext.valkey_client is not initialised"),
        )
    return client


async def _valkey_call(awaitable: Any, tool_name: str) -> Any:
    try:
        return await awaitable
    except Exception as exc:
        raise ToolExecutionError(tool_name, exc) from exc


def _map_get(
    mapping: Mapping[Any, Any] | Any,
    key: str,
    default: Any = None,
) -> Any:
    if not isinstance(mapping, Mapping):
        return default

    if key in mapping:
        return mapping[key]

    byte_key = key.encode()
    if byte_key in mapping:
        return mapping[byte_key]

    return default


def _as_text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(_as_text(value))
    except TypeError, ValueError:
        return default


def _keyspace_keys(value: Any) -> int:
    if isinstance(value, Mapping):
        return _as_int(_map_get(value, "keys", 0), 0)

    text = _as_text(value)
    match = re.search(r"(?:^|,)keys=(\d+)(?:,|$)", text)
    return int(match.group(1)) if match else 0


def _missing_stream_error(exc: Exception) -> bool:
    message = str(exc).lower()
    return "no such key" in message or ("xinfo groups" in message and "does not exist" in message)


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _get_valkey_stats(
    args: GetValkeyStatsInput,
    context: SREContext,
) -> GetValkeyStatsOutput:
    del args

    client = _valkey_client(context)

    memory_info = await _valkey_call(
        client.info("memory"),
        "get_valkey_stats",
    )
    clients_info = await _valkey_call(
        client.info("clients"),
        "get_valkey_stats",
    )
    keyspace_info = await _valkey_call(
        client.info("keyspace"),
        "get_valkey_stats",
    )
    stats_info = await _valkey_call(
        client.info("stats"),
        "get_valkey_stats",
    )

    used_memory = _as_int(_map_get(memory_info, "used_memory", 0))
    maxmemory = _as_int(_map_get(memory_info, "maxmemory", 0))
    connected_clients = _as_int(_map_get(clients_info, "connected_clients", 0))
    evicted_keys = _as_int(_map_get(stats_info, "evicted_keys", 0))

    keyspace_hits = _as_int(_map_get(stats_info, "keyspace_hits", 0))
    keyspace_misses = _as_int(_map_get(stats_info, "keyspace_misses", 0))

    total_operations = keyspace_hits + keyspace_misses
    hit_rate = keyspace_hits / total_operations * 100.0 if total_operations > 0 else 0.0

    total_keys = 0
    if isinstance(keyspace_info, Mapping):
        total_keys = sum(_keyspace_keys(db_info) for db_info in keyspace_info.values())

    used_mb = used_memory / (1024 * 1024)
    max_mb = maxmemory / (1024 * 1024) if maxmemory > 0 else 0.0
    usage_pct = used_memory / maxmemory * 100.0 if maxmemory > 0 else 0.0

    return GetValkeyStatsOutput(
        stats=ValkeyStats(
            used_memory_mb=round(used_mb, 2),
            maxmemory_mb=round(max_mb, 2),
            memory_usage_pct=round(usage_pct, 2),
            connected_clients=connected_clients,
            total_keys=total_keys,
            hit_rate_pct=round(hit_rate, 2),
            evicted_keys=evicted_keys,
        )
    )


async def _get_valkey_stream_info(
    args: GetValkeyStreamInfoInput,
    context: SREContext,
) -> GetValkeyStreamInfoOutput:
    """Get stream length, pending entries, and server-reported consumer lag."""
    client = _valkey_client(context)

    stream_length = await _valkey_call(
        client.xlen(args.stream_key),
        "get_valkey_stream_info",
    )

    try:
        groups_raw = await client.xinfo_groups(args.stream_key)
    except Exception as exc:
        if _missing_stream_error(exc):
            groups_raw = []
        else:
            raise ToolExecutionError(
                "get_valkey_stream_info",
                exc,
            ) from exc

    groups: list[ConsumerGroupInfo] = []

    if isinstance(groups_raw, list):
        for group in groups_raw:
            if not isinstance(group, Mapping):
                continue

            lag_raw = _map_get(group, "lag")
            lag = _as_int(lag_raw) if lag_raw is not None else None

            if lag is not None and lag < 0:
                lag = None

            groups.append(
                ConsumerGroupInfo(
                    group_name=_as_text(_map_get(group, "name", "")),
                    consumers=_as_int(_map_get(group, "consumers", 0)),
                    pending_messages=_as_int(_map_get(group, "pending", 0)),
                    lag_messages=lag,
                    last_delivered_id=_as_text(_map_get(group, "last-delivered-id", "")),
                )
            )

    return GetValkeyStreamInfoOutput(
        stream_key=args.stream_key,
        stream_length=_as_int(stream_length),
        groups=groups,
    )


# ---------------------------------------------------------------------------
# Tier 1: Targeted remediation
# ---------------------------------------------------------------------------


async def _delete_valkey_key(
    args: DeleteValkeyKeyInput,
    context: SREContext,
) -> DeleteValkeyKeyOutput:
    client = _valkey_client(context)

    deleted_count = await _valkey_call(
        client.delete(args.key),
        "delete_valkey_key",
    )

    return DeleteValkeyKeyOutput(
        key=args.key,
        deleted=_as_int(deleted_count) > 0,
        reason=args.reason,
    )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(registry: ToolRegistry, context: SREContext) -> None:
    """Register all Valkey tools."""
    del context

    registry.register(
        Tool(
            name="get_valkey_stats",
            description=(
                "Get Valkey memory usage, key count, hit rate, connected "
                "clients, and eviction count."
            ),
            input_model=GetValkeyStatsInput,
            output_model=GetValkeyStatsOutput,
            handler=_get_valkey_stats,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_valkey_stream_info",
            description=(
                "Get Valkey stream length plus consumer-group pending entries "
                "and server-reported lag. Useful for detecting consumer stalls."
            ),
            input_model=GetValkeyStreamInfoInput,
            output_model=GetValkeyStreamInfoOutput,
            handler=_get_valkey_stream_info,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="delete_valkey_key",
            description=(
                "Delete one specific Valkey key. Use only for targeted "
                "remediation; never use FLUSHALL or FLUSHDB from this tool."
            ),
            input_model=DeleteValkeyKeyInput,
            output_model=DeleteValkeyKeyOutput,
            handler=_delete_valkey_key,
            risk_tier=1,
        )
    )
