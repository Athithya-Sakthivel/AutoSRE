"""Valkey diagnostic and narrowly-scoped remediation tools."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

from autosre.core.state import SREContext
from autosre.tools.registry import Tool, ToolExecutionError, ToolInputModel, ToolRegistry

_FEATURE_PREFIX = "feature:"


class GetValkeyStatsInput(ToolInputModel):
    """No parameters."""


class ValkeyStats(BaseModel):
    used_memory_bytes: int
    maxmemory_bytes: int
    used_memory_pct: float
    evicted_keys_total: int
    connected_clients: int
    keyspace_hits: int
    keyspace_misses: int
    hit_rate: float


class GetValkeyStatsOutput(BaseModel):
    stats: ValkeyStats


class DeleteValkeyKeyInput(ToolInputModel):
    key: str = Field(
        min_length=1,
        max_length=500,
    )
    reason: str = Field(
        min_length=1,
        max_length=500,
    )

    @field_validator("key")
    @classmethod
    def validate_key(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("key must not be blank")

        if any(
            token in value
            for token in (
                "*",
                "?",
                "[",
                "]",
            )
        ):
            raise ValueError("wildcard or pattern keys are not permitted")

        if any(ord(char) < 32 for char in value):
            raise ValueError("control characters are not permitted in keys")

        return value

    @field_validator("reason")
    @classmethod
    def validate_reason(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("reason must not be blank")

        return value


class DeleteValkeyKeyOutput(BaseModel):
    key: str
    deleted: bool
    reason: str


class SetFeatureFlagInput(ToolInputModel):
    key: str = Field(
        min_length=len(_FEATURE_PREFIX) + 1,
        max_length=500,
    )
    value: Literal["true", "false"]
    ttl_seconds: int = Field(
        default=3600,
        ge=60,
        le=86_400,
    )

    @field_validator("key")
    @classmethod
    def validate_key(cls, value: str) -> str:
        value = value.strip()

        if not value.startswith(_FEATURE_PREFIX):
            raise ValueError("only keys prefixed with 'feature:' are permitted")

        if not value[len(_FEATURE_PREFIX) :].strip():
            raise ValueError("feature key must include a non-empty name")

        if any(ord(char) < 32 for char in value):
            raise ValueError("control characters are not permitted in keys")

        return value


class SetFeatureFlagOutput(BaseModel):
    key: str
    value: str
    ttl_seconds: int


def _redis(context: SREContext) -> Any:
    client = getattr(
        context,
        "valkey_client",
        None,
    )

    if client is None:
        raise ToolExecutionError(
            "valkey._redis",
            RuntimeError("SREContext.valkey_client is not initialised"),
        )

    for method in (
        "info",
        "delete",
        "set",
    ):
        if not callable(getattr(client, method, None)):
            raise ToolExecutionError(
                "valkey._redis",
                TypeError(f"context.valkey_client does not implement {method}()"),
            )

    return client


async def _get_valkey_stats(
    args: GetValkeyStatsInput,
    context: SREContext,
) -> GetValkeyStatsOutput:
    del args

    client = _redis(context)
    info = await client.info()

    if not isinstance(info, dict):
        raise ToolExecutionError(
            "get_valkey_stats",
            RuntimeError("Valkey INFO response is not a mapping"),
        )

    try:
        used = int(info.get("used_memory") or 0)
        maxmemory = int(info.get("maxmemory") or 0)
        evicted = int(info.get("evicted_keys") or 0)
        connected_clients = int(info.get("connected_clients") or 0)
        hits = int(info.get("keyspace_hits") or 0)
        misses = int(info.get("keyspace_misses") or 0)
    except (TypeError, ValueError) as exc:
        raise ToolExecutionError(
            "get_valkey_stats",
            RuntimeError("Valkey INFO contains non-numeric statistics"),
        ) from exc

    total_lookups = hits + misses

    hit_rate = hits / total_lookups if total_lookups else 0.0

    used_pct = used / maxmemory * 100.0 if maxmemory else 0.0

    return GetValkeyStatsOutput(
        stats=ValkeyStats(
            used_memory_bytes=used,
            maxmemory_bytes=maxmemory,
            used_memory_pct=round(
                used_pct,
                2,
            ),
            evicted_keys_total=evicted,
            connected_clients=connected_clients,
            keyspace_hits=hits,
            keyspace_misses=misses,
            hit_rate=round(
                hit_rate,
                4,
            ),
        )
    )


async def _delete_valkey_key(
    args: DeleteValkeyKeyInput,
    context: SREContext,
) -> DeleteValkeyKeyOutput:
    client = _redis(context)

    try:
        deleted_count = int(await client.delete(args.key))
    except (TypeError, ValueError) as exc:
        raise ToolExecutionError(
            "delete_valkey_key",
            RuntimeError("Valkey DELETE returned a non-numeric result"),
        ) from exc

    return DeleteValkeyKeyOutput(
        key=args.key,
        deleted=deleted_count > 0,
        reason=args.reason,
    )


async def _set_feature_flag(
    args: SetFeatureFlagInput,
    context: SREContext,
) -> SetFeatureFlagOutput:
    client = _redis(context)

    result = await client.set(
        args.key,
        args.value,
        ex=args.ttl_seconds,
    )

    if result is not True and result != "OK":
        raise ToolExecutionError(
            "set_feature_flag",
            RuntimeError("Valkey did not acknowledge the SET operation"),
        )

    return SetFeatureFlagOutput(
        key=args.key,
        value=args.value,
        ttl_seconds=args.ttl_seconds,
    )


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all Valkey tools."""

    registry.register(
        Tool(
            name="get_valkey_stats",
            description=(
                "Return Valkey memory utilisation, eviction count, client count, "
                "and cache hit rate."
            ),
            input_model=GetValkeyStatsInput,
            output_model=GetValkeyStatsOutput,
            handler=_get_valkey_stats,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="delete_valkey_key",
            description=(
                "Delete one exact Valkey key; wildcard and pattern syntax "
                "are rejected. Tier-1 action."
            ),
            input_model=DeleteValkeyKeyInput,
            output_model=DeleteValkeyKeyOutput,
            handler=_delete_valkey_key,
            risk_tier=1,
        )
    )

    registry.register(
        Tool(
            name="set_feature_flag",
            description=(
                "Set a feature flag under the feature: namespace to true or false "
                "with a bounded TTL. Tier-1 action."
            ),
            input_model=SetFeatureFlagInput,
            output_model=SetFeatureFlagOutput,
            handler=_set_feature_flag,
            risk_tier=1,
        )
    )
