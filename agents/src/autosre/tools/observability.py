"""OpenObserve client and read-only observability tools.

Exports:
  OpenObserveClient — HTTP adapter for OpenObserve Search API
  query_openobserve — Tier-0 tool wrapping OpenObserveClient
  get_postgres_stats — Tier-0 tool for PostgreSQL stats

Tools registered:
  Tier 0 (read-only): query_openobserve, get_postgres_stats
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from typing import Any

from pydantic import BaseModel, Field

from autosre.core.state import SREContext
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# OpenObserve HTTP client
# ---------------------------------------------------------------------------


class OpenObserveClient:
    """Adapter for OpenObserve Search API queries.

    Wraps HTTP calls to OpenObserve with basic-auth and time-bounded queries.
    The client reads connection details from ``settings.openobserve``.
    """

    def __init__(self, settings: Any) -> None:
        self._settings = settings
        self._session: Any | None = None

    async def _ensure_session(self) -> Any:
        """Lazily create the httpx session."""
        if self._session is not None:
            return self._session

        import httpx

        o2 = getattr(self._settings, "openobserve", None)
        if o2 is None:
            raise RuntimeError("settings.openobserve not configured")

        base_url = str(getattr(o2, "url", "http://localhost:5080"))
        email = str(getattr(o2, "email", ""))
        password_secret = getattr(o2, "password", None)

        if password_secret is not None and hasattr(password_secret, "get_secret_value"):
            password = password_secret.get_secret_value()
        else:
            password = str(password_secret or "")

        self._session = httpx.AsyncClient(
            base_url=base_url,
            auth=(email, password),
            timeout=30.0,
        )
        return self._session

    async def query(
        self,
        *,
        query: str,
        stream: str = "logs",
        time_range_minutes: int = 30,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Execute a bounded SQL query against an OpenObserve stream."""
        session = await self._ensure_session()

        end_time = datetime.now(UTC)
        start_time = end_time - timedelta(minutes=time_range_minutes)

        payload: dict[str, Any] = {
            "query": {
                "sql": query,
                "start_time": int(start_time.timestamp() * 1_000_000),
                "end_time": int(end_time.timestamp() * 1_000_000),
            },
            "stream_name": stream,
            "size": limit,
        }

        try:
            response = await session.post("/api/default/_search", json=payload)
            response.raise_for_status()
            parsed: dict[str, Any] = response.json()
            return parsed
        except Exception as exc:
            logger.warning("OpenObserve query failed: %s", exc)
            return {"hits": [], "total": 0}

    async def close(self) -> None:
        """Close the HTTP session."""
        if self._session is not None:
            await self._session.aclose()
            self._session = None


# ---------------------------------------------------------------------------
# Input / Output models
# ---------------------------------------------------------------------------


class QueryOpenObserveInput(ToolInputModel):
    query: str = Field(
        min_length=1,
        max_length=5000,
        description="SQL-compatible OpenObserve query",
    )
    stream: str = Field(
        default="logs",
        min_length=1,
        max_length=200,
        description="OpenObserve stream name",
    )
    time_range_minutes: int = Field(
        default=30,
        ge=1,
        le=1440,
        description="Lookback window in minutes",
    )
    limit: int = Field(default=50, ge=1, le=500)


class QueryOpenObserveOutput(BaseModel):
    rows: list[dict[str, Any]]
    total: int
    truncated: bool


class GetPostgresStatsInput(ToolInputModel):
    """No parameters."""


class PostgresStats(BaseModel):
    total_connections: int
    active: int
    idle: int
    idle_in_transaction: int
    max_connections: int
    utilisation_pct: float
    database_size_mb: float


class GetPostgresStatsOutput(BaseModel):
    stats: PostgresStats


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _o11y_client(context: SREContext) -> Any:
    """Return the OpenObserve client from SREContext."""
    client = getattr(context, "openobserve_client", None)
    if client is None:
        raise ToolExecutionError(
            "observability._o11y_client",
            RuntimeError("SREContext.openobserve_client is not initialised"),
        )
    return client


def _normalise_openobserve_result(
    result: Any,
) -> tuple[list[dict[str, Any]], int | None]:
    """Normalise common OpenObserve adapter result shapes."""
    if isinstance(result, (bytes, bytearray, str)):
        try:
            result = json.loads(result)
        except TypeError, ValueError:
            return [], None

    if isinstance(result, list):
        rows = [dict(row) for row in result if isinstance(row, Mapping)]
        return rows, None

    if not isinstance(result, Mapping):
        return [], None

    hits = result.get("hits", [])

    if isinstance(hits, Mapping):
        hits = hits.get("hits", [])

    if not isinstance(hits, list):
        hits = []

    rows = [dict(row) for row in hits if isinstance(row, Mapping)]

    total_raw = result.get("total")
    try:
        total = int(total_raw) if total_raw is not None else None
    except TypeError, ValueError:
        total = None

    return rows, total


def _row_value(row: Any, key: str, index: int = 0) -> Any:
    """Read a column from tuple-like or dict-like DB rows."""
    if isinstance(row, Mapping):
        return row.get(key)
    try:
        return row[index]
    except IndexError, KeyError, TypeError:
        return None


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _query_openobserve(
    args: QueryOpenObserveInput,
    context: SREContext,
) -> QueryOpenObserveOutput:
    client = _o11y_client(context)

    query_method = getattr(client, "query", None)
    if not callable(query_method):
        raise ToolExecutionError(
            "query_openobserve",
            TypeError("SREContext.openobserve_client does not implement query()"),
        )

    try:
        result = await query_method(
            query=args.query,
            stream=args.stream,
            time_range_minutes=args.time_range_minutes,
            limit=args.limit,
        )
    except Exception as exc:
        raise ToolExecutionError("query_openobserve", exc) from exc

    rows, reported_total = _normalise_openobserve_result(result)

    total = max(reported_total, len(rows)) if reported_total is not None else len(rows)

    truncated = len(rows) >= args.limit or total > len(rows)

    return QueryOpenObserveOutput(
        rows=rows,
        total=total,
        truncated=truncated,
    )


async def _get_postgres_stats(
    args: GetPostgresStatsInput,
    context: SREContext,
) -> GetPostgresStatsOutput:
    del args

    pool = getattr(context, "pg_pool", None)
    if pool is None:
        raise ToolExecutionError(
            "get_postgres_stats",
            RuntimeError("SREContext.pg_pool is not initialised"),
        )

    connection_factory = getattr(pool, "connection", None)
    if not callable(connection_factory):
        raise ToolExecutionError(
            "get_postgres_stats",
            TypeError("SREContext.pg_pool does not implement connection()"),
        )

    try:
        async with connection_factory() as conn, conn.cursor() as cur:
            await cur.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    COUNT(*) FILTER (WHERE state = 'active') AS active,
                    COUNT(*) FILTER (WHERE state = 'idle') AS idle,
                    COUNT(*) FILTER (
                        WHERE state IN (
                            'idle in transaction',
                            'idle in transaction (aborted)'
                        )
                    ) AS idle_tx
                FROM pg_stat_activity
                WHERE backend_type = 'client backend'
                """
            )

            row = await cur.fetchone()
            if row is None:
                raise RuntimeError("pg_stat_activity returned no rows")

            total = int(_row_value(row, "total", 0) or 0)
            active = int(_row_value(row, "active", 1) or 0)
            idle = int(_row_value(row, "idle", 2) or 0)
            idle_tx = int(_row_value(row, "idle_tx", 3) or 0)

            await cur.execute("SELECT current_setting('max_connections')::int AS max_connections")
            max_row = await cur.fetchone()
            max_conn = int(_row_value(max_row, "max_connections", 0) or 0) if max_row else 0

            await cur.execute(
                "SELECT pg_database_size(current_database()) / 1048576.0 AS database_size_mb"
            )
            size_row = await cur.fetchone()
            db_size_mb = float(_row_value(size_row, "database_size_mb", 0) or 0.0)

    except ToolExecutionError:
        raise
    except Exception as exc:
        raise ToolExecutionError("get_postgres_stats", exc) from exc

    utilisation = total / max_conn * 100.0 if max_conn > 0 else 0.0

    return GetPostgresStatsOutput(
        stats=PostgresStats(
            total_connections=total,
            active=active,
            idle=idle,
            idle_in_transaction=idle_tx,
            max_connections=max_conn,
            utilisation_pct=round(utilisation, 2),
            database_size_mb=round(db_size_mb, 2),
        )
    )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(registry: ToolRegistry, context: SREContext) -> None:
    """Register all observability tools."""
    del context

    registry.register(
        Tool(
            name="query_openobserve",
            description=(
                "Run a SQL-compatible query against an OpenObserve stream "
                "within the configured lookback window."
            ),
            input_model=QueryOpenObserveInput,
            output_model=QueryOpenObserveOutput,
            handler=_query_openobserve,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_postgres_stats",
            description=(
                "Get PostgreSQL client-backend connection counts, "
                "max_connections, utilisation, and current database size in MiB."
            ),
            input_model=GetPostgresStatsInput,
            output_model=GetPostgresStatsOutput,
            handler=_get_postgres_stats,
            risk_tier=0,
        )
    )
