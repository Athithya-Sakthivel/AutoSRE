"""Valkey (Redis-compatible) diagnostic and targeted remediation tools.

## Tools Registered

### Tier 0 — Read-Only Diagnostics (2 tools)
- `get_valkey_stats`: Memory usage, key count, hit rate, connected clients,
  and eviction count
- `get_valkey_stream_info`: Stream length plus consumer-group pending entries
  and server-reported lag

### Tier 1 — Targeted Mutation (1 tool)
- `delete_valkey_key`: Delete one specific Valkey key (never use FLUSHALL)

## Contracts

### Output Contract
Every Tier-1 tool output model includes:
- `success: bool` — True if the tool executed without error
- `verification_passed: bool | None` — True if output indicates root cause
  resolved, None if indeterminate

### SREContext Contract
The Valkey client is accessed via `context.valkey_client`. It must expose an
asyncio-compatible Valkey/Redis API (e.g., valkey-py or redis-py). If None,
tools raise ToolExecutionError.

### Error Handling Contract
All Valkey client calls are wrapped in `_valkey_call()` which catches
exceptions and re-raises as ToolExecutionError with the tool name and original
exception.

### Graceful Degradation Contract
The `get_valkey_stream_info` tool returns an empty groups list if the stream
key doesn't exist instead of failing. This allows the agent to handle missing
streams gracefully.

### Safety Contract (delete_valkey_key)
The delete_valkey_key tool only deletes ONE specific key. The tool description
explicitly warns against using FLUSHALL or FLUSHDB. The policy engine in
executor.py also blocks these commands.
"""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Awaitable, Mapping
from typing import Any

from pydantic import BaseModel, Field, field_validator

from autosre.core.state import SREContext
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Input / Output Models
# ---------------------------------------------------------------------------


class GetValkeyStatsInput(ToolInputModel):
    """Input for Valkey stats (no parameters)."""


class ValkeyStats(BaseModel):
    """Aggregate Valkey statistics."""

    used_memory_mb: float
    maxmemory_mb: float
    memory_usage_pct: float
    connected_clients: int
    total_keys: int
    hit_rate_pct: float
    evicted_keys: int


class GetValkeyStatsOutput(BaseModel):
    """Output for get_valkey_stats tool."""

    stats: ValkeyStats


class GetValkeyStreamInfoInput(ToolInputModel):
    """Input for getting Valkey stream consumer-group state."""

    stream_key: str = Field(
        min_length=1,
        max_length=500,
    )

    @field_validator("stream_key")
    @classmethod
    def validate_stream_key(cls, value: str) -> str:
        """Reject whitespace-only stream keys."""
        value = value.strip()
        if not value:
            raise ValueError("stream_key must not be blank")
        return value


class ConsumerGroupInfo(BaseModel):
    """Consumer group state for a Valkey stream."""

    group_name: str
    consumers: int
    pending_messages: int
    lag_messages: int | None = None
    last_delivered_id: str


class GetValkeyStreamInfoOutput(BaseModel):
    """Output for get_valkey_stream_info tool."""

    stream_key: str
    stream_length: int
    groups: list[ConsumerGroupInfo]


class DeleteValkeyKeyInput(ToolInputModel):
    """Input for deleting a Valkey key."""

    key: str = Field(min_length=1, max_length=500)
    reason: str = Field(min_length=1, max_length=500)

    @field_validator("key", "reason")
    @classmethod
    def validate_non_blank(cls, value: str) -> str:
        """Reject values that contain only whitespace."""
        value = value.strip()
        if not value:
            raise ValueError("value must not be blank")
        return value


class DeleteValkeyKeyOutput(BaseModel):
    """Output for delete_valkey_key tool."""

    key: str
    deleted: bool
    reason: str
    success: bool = True
    verification_passed: bool | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _valkey_client(context: SREContext) -> Any:
    """Return the Valkey client from SREContext.

    Raises:
        ToolExecutionError: If valkey_client is not initialized.
    """
    client = getattr(context, "valkey_client", None)

    if client is None:
        raise ToolExecutionError(
            "valkey._valkey_client",
            RuntimeError("SREContext.valkey_client is not initialised"),
        )

    return client


async def _valkey_call(
    awaitable: Awaitable[Any],
    tool_name: str,
) -> Any:
    """Await a Valkey client call and wrap errors in ToolExecutionError."""
    try:
        return await awaitable
    except Exception as exc:
        raise ToolExecutionError(tool_name, exc) from exc


def _map_get(
    mapping: Mapping[Any, Any] | Any,
    key: str,
    default: Any = None,
) -> Any:
    """Read a string key from mappings that may use bytes keys."""
    if not isinstance(mapping, Mapping):
        return default

    if key in mapping:
        return mapping[key]

    byte_key = key.encode()

    if byte_key in mapping:
        return mapping[byte_key]

    return default


def _as_text(
    value: Any,
    default: str = "",
) -> str:
    """Convert a value to text, handling bytes."""
    if value is None:
        return default

    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")

    return str(value)


def _as_int(
    value: Any,
    default: int = 0,
) -> int:
    """Convert a value to int, with fallback to default."""
    try:
        return int(_as_text(value))
    except TypeError, ValueError:
        return default


def _keyspace_keys(value: Any) -> int:
    """Extract key count from Valkey keyspace info."""
    if isinstance(value, Mapping):
        return _as_int(
            _map_get(value, "keys", 0),
            0,
        )

    text = _as_text(value)
    match = re.search(
        r"(?:^|,)keys=(\d+)(?:,|$)",
        text,
    )

    return int(match.group(1)) if match else 0


def _missing_stream_error(exc: Exception) -> bool:
    """Check if an exception indicates a missing stream key."""
    message = str(exc).lower()

    return "no such key" in message or ("xinfo groups" in message and "does not exist" in message)


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _get_valkey_stats(
    args: GetValkeyStatsInput,
    context: SREContext,
) -> GetValkeyStatsOutput:
    """Get Valkey memory usage, key count, hit rate, and eviction count."""
    del args

    client = _valkey_client(context)

    # These INFO sections are independent. Gather them concurrently to avoid
    # four sequential network round-trips on a hot diagnostic path.
    memory_info, clients_info, keyspace_info, stats_info = await asyncio.gather(
        _valkey_call(
            client.info("memory"),
            "get_valkey_stats",
        ),
        _valkey_call(
            client.info("clients"),
            "get_valkey_stats",
        ),
        _valkey_call(
            client.info("keyspace"),
            "get_valkey_stats",
        ),
        _valkey_call(
            client.info("stats"),
            "get_valkey_stats",
        ),
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
    """Get stream length, pending entries, and consumer lag."""
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
                    last_delivered_id=_as_text(
                        _map_get(
                            group,
                            "last-delivered-id",
                            "",
                        )
                    ),
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
    """Delete one specific Valkey key and verify the desired end state.

    DEL returning zero means the key was already absent, which is a successful
    outcome for the requested desired state. After DEL, EXISTS is checked so
    the verification result reflects the actual current state rather than the
    raw DEL return value alone.
    """
    client = _valkey_client(context)

    deleted_count = await _valkey_call(
        client.delete(args.key),
        "delete_valkey_key",
    )

    deleted = _as_int(deleted_count) > 0

    try:
        remaining = await _valkey_call(
            client.exists(args.key),
            "delete_valkey_key",
        )
    except ToolExecutionError:
        logger.warning(
            "Key '%s' deletion succeeded but post-delete verification failed",
            args.key,
        )

        return DeleteValkeyKeyOutput(
            key=args.key,
            deleted=deleted,
            reason=args.reason,
            success=True,
            verification_passed=None,
        )

    verification_passed = _as_int(remaining) == 0

    logger.info(
        "Key '%s' deletion requested: deleted=%s verified=%s",
        args.key,
        deleted,
        verification_passed,
    )

    return DeleteValkeyKeyOutput(
        key=args.key,
        deleted=deleted,
        reason=args.reason,
        success=True,
        verification_passed=verification_passed,
    )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all Valkey tools with the given registry."""
    del context

    # Tier 0: Read-only diagnostics
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

    # Tier 1: Targeted remediation
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
