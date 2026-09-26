"""OpenObserve client and read-only observability tools.

## Exports

- `OpenObserveClient` — HTTP adapter for OpenObserve Search API
- `query_openobserve` — Tier-0 tool wrapping OpenObserveClient

## Tools Registered

### Tier 0 — Read-Only Diagnostics (1 tool)
- `query_openobserve`: Run SQL-compatible queries against OpenObserve streams

## Contracts

### Output Contract
The observability tool is Tier-0 (read-only), so it does not include `success` or
`verification_passed` fields in its output model. These fields are only
required for Tier-1+ remediation tools.

### SREContext Contract
- `query_openobserve` reads from `context.openobserve_client`, which must be
  an `OpenObserveClient` instance (or compatible). If None, the tool raises
  `ToolExecutionError`.

### Error Handling Contract
The OpenObserve client degrades query failures into an explicit `error` field so
that the agent can distinguish an empty result from an unavailable backend. A
missing client or malformed tool invocation still raises `ToolExecutionError`.

### OpenObserve Query Contract
Queries are bounded by:
- `time_range_minutes` (1-1440 minutes lookback)
- `limit` (1-500 rows)
- SQL syntax validated by OpenObserve server (no client-side validation)

The client converts Python datetime to OpenObserve's microsecond timestamp format.
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
# OpenObserve HTTP Client
# ---------------------------------------------------------------------------


class OpenObserveClient:
    """HTTP adapter for OpenObserve Search API queries.

    Wraps HTTP calls to OpenObserve with basic-auth and time-bounded queries.
    The client reads connection details from `settings.openobserve`.

    Attributes:
        _settings: Application settings object with openobserve config
        _session: Lazily-created httpx.AsyncClient
        _org_id: OpenObserve organization ID, defaulting to "default"

    Usage:
        client = OpenObserveClient(settings)
        result = await client.query(
            query="SELECT * FROM logs WHERE status >= 500",
            stream="logs",
            time_range_minutes=30,
            limit=100,
        )
        await client.close()
    """

    def __init__(self, settings: Any) -> None:
        """Initialize the OpenObserve client.

        Args:
            settings: Application settings object with openobserve config
        """
        self._settings = settings
        self._session: Any | None = None
        self._org_id = "default"

    async def _ensure_session(self) -> Any:
        """Lazily create the httpx session.

        Returns:
            httpx.AsyncClient configured with OpenObserve credentials

        Raises:
            RuntimeError: If settings.openobserve is not configured
        """
        if self._session is not None:
            return self._session

        import httpx

        o2 = getattr(self._settings, "openobserve", None)

        if o2 is None:
            raise RuntimeError("settings.openobserve not configured")

        base_url = str(
            getattr(
                o2,
                "url",
                "http://localhost:5080",
            )
        )
        email = str(
            getattr(
                o2,
                "email",
                "",
            )
        )
        password_secret = getattr(
            o2,
            "password",
            None,
        )

        if password_secret is not None and hasattr(
            password_secret,
            "get_secret_value",
        ):
            password = password_secret.get_secret_value()
        else:
            password = str(password_secret or "")

        self._org_id = str(
            getattr(
                o2,
                "org_id",
                "default",
            )
            or "default"
        )

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
        """Execute a bounded SQL query against an OpenObserve stream.

        Args:
            query: SQL-compatible query string
            stream: OpenObserve stream name (e.g., "logs", "metrics")
            time_range_minutes: Lookback window in minutes (1-1440)
            limit: Maximum rows to return (1-500)

        Returns:
            Dict with "hits" (list of rows) and "total" (total matching rows).
            Query failures return empty hits plus an explicit "error" field so
            callers can distinguish backend failure from a genuine empty result.

        Note:
            Time bounds are converted to OpenObserve's microsecond timestamp format.
        """
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
            response = await session.post(
                f"/api/{self._org_id}/_search",
                json=payload,
            )
            response.raise_for_status()
            parsed: dict[str, Any] = response.json()
            return parsed
        except Exception as exc:
            logger.warning(
                "OpenObserve query failed: %s",
                exc,
            )
            return {
                "hits": [],
                "total": 0,
                "error": str(exc),
            }

    async def close(self) -> None:
        """Close the HTTP session and release resources."""
        if self._session is not None:
            await self._session.aclose()
            self._session = None


# ---------------------------------------------------------------------------
# Input / Output Models
# ---------------------------------------------------------------------------


class QueryOpenObserveInput(ToolInputModel):
    """Input for querying OpenObserve streams."""

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
    limit: int = Field(
        default=50,
        ge=1,
        le=500,
    )


class QueryOpenObserveOutput(BaseModel):
    """Output for query_openobserve tool.

    Attributes:
        rows: List of result rows (dicts)
        total: Total matching rows (may be > len(rows) if truncated)
        truncated: True if results were truncated due to limit
        error: Query/backend error when the request could not be completed
    """

    rows: list[dict[str, Any]]
    total: int
    truncated: bool
    error: str | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _o11y_client(context: SREContext) -> Any:
    """Return the OpenObserve client from SREContext.

    Returns:
        OpenObserveClient instance

    Raises:
        ToolExecutionError: If openobserve_client is not initialized
    """
    client = getattr(
        context,
        "openobserve_client",
        None,
    )

    if client is None:
        raise ToolExecutionError(
            "observability._o11y_client",
            RuntimeError("SREContext.openobserve_client is not initialised"),
        )

    return client


def _normalise_openobserve_result(
    result: Any,
) -> tuple[
    list[dict[str, Any]],
    int | None,
    str | None,
]:
    """Normalise common OpenObserve adapter result shapes.

    Handles JSON strings/bytes, raw row lists, standard ``hits`` responses,
    nested ``hits.hits`` responses, and explicit adapter/query errors.
    """
    if isinstance(
        result,
        (bytes, bytearray, str),
    ):
        try:
            result = json.loads(result)
        except TypeError, ValueError:
            return (
                [],
                None,
                "OpenObserve returned non-JSON data",
            )

    if isinstance(result, list):
        rows = [dict(row) for row in result if isinstance(row, Mapping)]
        return rows, None, None

    if not isinstance(result, Mapping):
        return (
            [],
            None,
            "OpenObserve returned an unsupported response shape",
        )

    error_raw = result.get("error")
    error = str(error_raw) if error_raw else None

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

    return rows, total, error


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _query_openobserve(
    args: QueryOpenObserveInput,
    context: SREContext,
) -> QueryOpenObserveOutput:
    """Run a bounded SQL-compatible query against an OpenObserve stream."""
    client = _o11y_client(context)

    query_method = getattr(
        client,
        "query",
        None,
    )

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
        raise ToolExecutionError(
            "query_openobserve",
            exc,
        ) from exc

    rows, reported_total, error = _normalise_openobserve_result(result)

    total = (
        max(
            reported_total,
            len(rows),
        )
        if reported_total is not None
        else len(rows)
    )

    truncated = not error and (len(rows) >= args.limit or total > len(rows))

    return QueryOpenObserveOutput(
        rows=rows,
        total=total,
        truncated=truncated,
        error=error,
    )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register the observability tools with the given registry."""
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
