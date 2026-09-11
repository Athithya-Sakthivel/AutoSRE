"""Distributed rate limiter backed by Cosmos DB."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Any

from azure.cosmos import CosmosClient
from azure.cosmos.exceptions import CosmosHttpResponseError
from infra.config import Settings, load_settings


@dataclass(frozen=True, slots=True)
class RateLimitDecision:
    allowed: bool
    count: int
    threshold: int
    window_minutes: int
    bucket_count: int
    bucket_id: str


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _minute_bucket_start(moment: datetime | None = None) -> datetime:
    moment = moment or _utc_now()
    return moment.astimezone(UTC).replace(second=0, microsecond=0)


def _bucket_id(resource_id: str, bucket_start: datetime) -> str:
    return f"{resource_id}:{bucket_start.strftime('%Y%m%dT%H%M')}"


def _cutoff_for_window(bucket_start: datetime, window_minutes: int) -> datetime:
    return bucket_start - timedelta(minutes=window_minutes - 1)


@lru_cache(maxsize=1)
def _cosmos_client() -> CosmosClient:
    settings = load_settings()
    return CosmosClient(settings.cosmos_endpoint, credential=settings.cosmos_key)


@lru_cache(maxsize=1)
def _rate_limit_container() -> Any:
    settings = load_settings()
    client = _cosmos_client()
    database = client.get_database_client(settings.cosmos_database)
    return database.get_container_client(settings.rate_limit_container)


def _sum_recent_counts(resource_id: str, cutoff: datetime) -> int:
    container = _rate_limit_container()
    query = (
        "SELECT * FROM c "
        "WHERE c.resource_id = @resource_id "
        "AND c.bucket_start >= @cutoff "
        "ORDER BY c.bucket_start ASC"
    )
    parameters = [
        {"name": "@resource_id", "value": resource_id},
        {"name": "@cutoff", "value": cutoff.strftime("%Y-%m-%dT%H:%M:%S.%fZ")},
    ]
    total = 0
    for item in container.query_items(
        query=query, parameters=parameters, partition_key=resource_id
    ):
        try:
            total += int(item.get("count", 0))
        except TypeError, ValueError:
            continue
    return total


def _upsert_current_bucket(
    resource_id: str, settings: Settings, now: datetime | None = None
) -> RateLimitDecision:
    container = _rate_limit_container()
    now = now or _utc_now()
    bucket_start = _minute_bucket_start(now)
    bucket_id = _bucket_id(resource_id, bucket_start)
    ttl_seconds = settings.rate_limit_ttl_seconds

    try:
        updated = container.patch_item(
            item=bucket_id,
            partition_key=resource_id,
            patch_operations=[{"op": "incr", "path": "/count", "value": 1}],
        )
    except CosmosHttpResponseError as exc:
        status_code = getattr(exc, "status_code", None)
        if status_code not in {404, 409}:
            raise
        try:
            updated = container.create_item(
                body={
                    "id": bucket_id,
                    "resource_id": resource_id,
                    "bucket_start": bucket_start.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
                    "count": 1,
                    "ttl": ttl_seconds,
                }
            )
        except CosmosHttpResponseError as create_exc:
            create_status = getattr(create_exc, "status_code", None)
            if create_status not in {409, 412}:
                raise
            updated = container.patch_item(
                item=bucket_id,
                partition_key=resource_id,
                patch_operations=[{"op": "incr", "path": "/count", "value": 1}],
            )

    if "ttl" not in updated:
        updated["ttl"] = ttl_seconds

    cutoff = _cutoff_for_window(bucket_start, settings.rate_limit_window_minutes)
    total = _sum_recent_counts(resource_id, cutoff)
    allowed = total <= settings.rate_limit_threshold

    return RateLimitDecision(
        allowed=allowed,
        count=total,
        threshold=settings.rate_limit_threshold,
        window_minutes=settings.rate_limit_window_minutes,
        bucket_count=int(updated.get("count", 0)),
        bucket_id=bucket_id,
    )


def check_rate_limit(resource_id: str, *, now: datetime | None = None) -> RateLimitDecision:
    if not resource_id:
        raise ValueError("resource_id must be non‑empty")
    return _upsert_current_bucket(resource_id, load_settings(), now=now)


async def async_check_rate_limit(
    resource_id: str, *, now: datetime | None = None
) -> RateLimitDecision:
    return await asyncio.to_thread(check_rate_limit, resource_id, now=now)


def reset_rate_limiter_cache() -> None:
    _cosmos_client.cache_clear()
    _rate_limit_container.cache_clear()


__all__ = [
    "RateLimitDecision",
    "async_check_rate_limit",
    "check_rate_limit",
    "reset_rate_limiter_cache",
]
