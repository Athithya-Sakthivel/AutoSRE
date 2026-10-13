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

The client converts wall-clock time to OpenObserve's microsecond timestamp format
and wraps the SQL string in the required ``{"query": {"sql": ..., "start_time":
..., "end_time": ..., "from": 0, "size": N}}`` payload shape.
"""

from __future__ import annotations

import contextlib
import json
import logging
import time
from collections.abc import Mapping
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
    The client reads connection details from ``settings.openobserve``.

    Attributes:
        _settings: Application settings object with openobserve config
        _session: Lazily-created httpx.AsyncClient
        _org_id: OpenObserve organization ID, defaulting to "default"
        _base_url: Cached base URL for the OpenObserve server
        _timeout: Per-request timeout in seconds

    Usage::

        client = OpenObserveClient(settings)
        result = await client.query(
            query="SELECT * FROM app_logs WHERE status >= 500",
            stream="app_logs",
            time_range_minutes=30,
            limit=100,
        )
        await client.close()
    """

    # Default stream name. The rivulet OTel pipeline writes to ``app_logs``;
    # override per-call if a different stream is needed.
    DEFAULT_STREAM = "app_logs"

    def __init__(self, settings: Any) -> None:
        """Initialize the OpenObserve client.

        Args:
            settings: Application settings object with openobserve config
        """
        self._settings = settings
        self._session: Any | None = None
        self._org_id = "default"
        self._base_url: str = "http://localhost:5080"
        self._timeout: float = 30.0
        self._email: str = ""
        self._password: str = ""

    async def _ensure_session(self) -> Any:
        """Lazily create the httpx session.

        Returns:
            httpx.AsyncClient configured with OpenObserve credentials

        Raises:
            RuntimeError: If settings.openobserve is not configured
        """
        if self._session is not None:
            return self._session

        import httpx  # noqa: PLC0415 — lazy import to avoid import-time dep

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

        self._org_id = str(getattr(o2, "org_id", "default") or "default")
        self._base_url = base_url.rstrip("/")
        self._email = email
        self._password = password

        self._session = httpx.AsyncClient(
            base_url=self._base_url,
            auth=(self._email, self._password),
            timeout=self._timeout,
        )

        logger.debug(
            "OpenObserve client initialised: base_url=%s org=%s",
            self._base_url,
            self._org_id,
        )

        return self._session

    async def query(
        self,
        *,
        query: str,
        stream: str = "app_logs",
        time_range_minutes: int = 30,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Execute a bounded SQL query against an OpenObserve stream.

        Constructs the payload shape required by OpenObserve's ``_search``
        endpoint::

            {
              "query": {
                "sql": "<SQL>",
                "start_time": <epoch_microseconds>,
                "end_time": <epoch_microseconds>,
                "from": 0,
                "size": <limit>
              }
            }

        Args:
            query: SQL-compatible query string
            stream: OpenObserve stream name (default ``app_logs``)
            time_range_minutes: Lookback window in minutes (1-1440)
            limit: Maximum rows to return (1-500)

        Returns:
            Dict with ``hits`` (list of rows) and ``total`` (total matching
            rows). Query failures return empty hits plus an explicit ``error``
            field so callers can distinguish backend failure from a genuine
            empty result.

        Raises:
            ToolExecutionError: On authentication failure, network error, or
                malformed query.
        """
        import httpx  # noqa: PLC0415 — lazy import

        session = await self._ensure_session()

        # Clamp inputs to safe ranges
        time_range_minutes = max(1, min(1440, int(time_range_minutes)))
        limit = max(1, min(500, int(limit)))

        # OpenObserve uses EPOCH MICROSECONDS for time bounds
        now_us = int(time.time() * 1_000_000)
        start_us = now_us - (time_range_minutes * 60 * 1_000_000)

        # Ensure SQL has a LIMIT clause
        sql = query.strip().rstrip(";")
        if "LIMIT" not in sql.upper():
            sql = f"{sql} LIMIT {limit}"

        # Normalise stream name — the LLM sometimes emits "logs" out of
        # habit. Map it to the real stream name so queries succeed.
        effective_stream = stream or self.DEFAULT_STREAM
        if effective_stream == "logs":
            effective_stream = self.DEFAULT_STREAM

        # Build the REQUIRED OpenObserve payload shape.
        # The "query" field MUST be a struct, not a bare SQL string.
        payload = {
            "query": {
                "sql": sql,
                "start_time": start_us,
                "end_time": now_us,
                "from": 0,
                "size": limit,
            }
        }

        # URL includes the stream name: /api/{org}/{stream}/_search?type=logs
        url = f"/api/{self._org_id}/{effective_stream}/_search?type=logs"

        try:
            resp = await session.post(url, json=payload)
        except httpx.TimeoutException as exc:
            raise ToolExecutionError(
                "query_openobserve",
                ConnectionError(f"OpenObserve request timed out: {exc}"),
            ) from exc
        except httpx.HTTPError as exc:
            raise ToolExecutionError(
                "query_openobserve",
                ConnectionError(f"Failed to reach OpenObserve: {exc}"),
            ) from exc

        try:
            if resp.status_code == 401:
                raise ToolExecutionError(
                    "query_openobserve",
                    PermissionError(
                        f"OpenObserve authentication failed (HTTP 401): {(resp.text or '')[:200]}"
                    ),
                )

            if resp.status_code == 400:
                body = resp.text or ""
                raise ToolExecutionError(
                    "query_openobserve",
                    ValueError(f"OpenObserve rejected query (HTTP 400): {body[:300]}"),
                )

            if resp.status_code >= 400:
                body = resp.text or ""
                raise ToolExecutionError(
                    "query_openobserve",
                    RuntimeError(f"OpenObserve returned HTTP {resp.status_code}: {body[:300]}"),
                )

            data = resp.json()

        finally:
            # httpx response objects don't need explicit closing for non-streaming
            # responses, but be defensive.
            with contextlib.suppress(Exception):
                await resp.aclose()

        # OpenObserve returns {"hits": [...], "total": N} on success.
        # Some query shapes return {"hits": [...], "agg": {...}}.
        hits = data.get("hits", []) if isinstance(data, Mapping) else []
        total = data.get("total", len(hits)) if isinstance(data, Mapping) else 0

        if not isinstance(hits, list):
            hits = []

        return {"hits": hits, "total": int(total) if total is not None else len(hits)}

    async def close(self) -> None:
        """Close the HTTP session and release resources."""
        if self._session is not None:
            with contextlib.suppress(Exception):
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
        description="SQL-compatible OpenObserve query (e.g. 'SELECT * FROM app_logs WHERE level = \\'error\\' LIMIT 50')",
    )
    stream: str = Field(
        default="app_logs",
        min_length=1,
        max_length=200,
        description="OpenObserve stream name (default: app_logs)",
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
        description="Maximum rows to return",
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
    client = getattr(context, "openobserve_client", None)

    if client is None:
        raise ToolExecutionError(
            "observability._o11y_client",
            RuntimeError("SREContext.openobserve_client is not initialised"),
        )

    return client


def _normalise_openobserve_result(
    result: Any,
) -> tuple[list[dict[str, Any]], int | None, str | None]:
    """Normalise common OpenObserve adapter result shapes.

    Handles JSON strings/bytes, raw row lists, standard ``hits`` responses,
    nested ``hits.hits`` responses, and explicit adapter/query errors.
    """
    if isinstance(result, (bytes, bytearray, str)):
        try:
            result = json.loads(result)
        except TypeError, ValueError:
            return [], None, "OpenObserve returned non-JSON data"

    if isinstance(result, list):
        rows = [dict(row) for row in result if isinstance(row, Mapping)]
        return rows, None, None

    if not isinstance(result, Mapping):
        return [], None, "OpenObserve returned an unsupported response shape"

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
    except ToolExecutionError:
        # Re-raise tool errors verbatim so the error field propagates.
        raise
    except Exception as exc:
        raise ToolExecutionError("query_openobserve", exc) from exc

    rows, reported_total, error = _normalise_openobserve_result(result)

    total = max(reported_total, len(rows)) if reported_total is not None else len(rows)

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
                "within the configured lookback window. The default stream is "
                "'app_logs' which receives rivulet application logs via OTel."
            ),
            input_model=QueryOpenObserveInput,
            output_model=QueryOpenObserveOutput,
            handler=_query_openobserve,
            risk_tier=0,
        )
    )
