"""OpenObserve read-only search tools for logs and metrics."""

from __future__ import annotations

import datetime as _dt
import re
import time
from typing import Any
from urllib.parse import quote

from pydantic import BaseModel, Field, field_validator

from autosre.config import Settings
from autosre.core.state import SREContext
from autosre.tools.registry import Tool, ToolExecutionError, ToolInputModel, ToolRegistry

_DEFAULT_LOOKBACK_SECONDS = 600
_MAX_SQL_LENGTH = 10_000
_MAX_WHERE_LENGTH = 2_000

_DANGEROUS_SQL_RE = re.compile(
    r"\b(?:INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|"
    r"COPY|CALL|DO|INTO|EXPLAIN|ANALYZE|SHOW|SET|RESET|VACUUM|ATTACH|DETACH)\b",
    re.IGNORECASE,
)

_DISALLOWED_WHERE_RE = re.compile(
    r"\b(?:SELECT|WITH|FROM|JOIN|UNION|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|"
    r"TRUNCATE|GRANT|REVOKE|COPY|CALL|DO|INTO|EXPLAIN|ANALYZE|SHOW|SET|RESET|"
    r"VACUUM|ATTACH|DETACH|GROUP|ORDER|HAVING|LIMIT|OFFSET)\b",
    re.IGNORECASE,
)


class QueryMetricsInput(ToolInputModel):
    """Execute a read-only SQL query against OpenObserve."""

    sql: str = Field(
        min_length=1,
        max_length=_MAX_SQL_LENGTH,
    )
    lookback_seconds: int = Field(
        default=_DEFAULT_LOOKBACK_SECONDS,
        ge=60,
        le=86_400,
    )
    limit: int = Field(
        default=100,
        ge=1,
        le=1000,
    )

    @field_validator("sql")
    @classmethod
    def normalize_sql(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("SQL query must not be empty")

        return value


class QueryMetricsOutput(BaseModel):
    rows: list[dict[str, Any]]
    total_hits: int
    took_ms: float


class GetErrorClustersInput(ToolInputModel):
    """Group recent error logs for one service by exact message."""

    service: str = Field(
        min_length=1,
        max_length=200,
    )
    lookback_seconds: int = Field(
        default=_DEFAULT_LOOKBACK_SECONDS,
        ge=60,
        le=86_400,
    )
    top_n: int = Field(
        default=10,
        ge=1,
        le=50,
    )

    @field_validator("service")
    @classmethod
    def normalize_service(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("service must not be blank")

        if "\x00" in value:
            raise ValueError("service must not contain NUL bytes")

        return value


class ErrorCluster(BaseModel):
    signature: str
    count: int
    sample_message: str
    first_seen: str
    last_seen: str


class GetErrorClustersOutput(BaseModel):
    service: str
    clusters: list[ErrorCluster]


class SearchLogsInput(ToolInputModel):
    """Search the ``logs`` stream using a restricted SQL WHERE expression."""

    query: str = Field(
        min_length=1,
        max_length=_MAX_WHERE_LENGTH,
    )
    lookback_seconds: int = Field(
        default=_DEFAULT_LOOKBACK_SECONDS,
        ge=60,
        le=86_400,
    )
    limit: int = Field(
        default=50,
        ge=1,
        le=500,
    )

    @field_validator("query")
    @classmethod
    def normalize_query(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("log filter must not be empty")

        return value


class LogHit(BaseModel):
    timestamp: str
    service: str | None
    level: str | None
    message: str


class SearchLogsOutput(BaseModel):
    hits: list[LogHit]
    total: int


def _mask_sql_literals(text: str) -> str:
    """Return SQL with literals masked; reject comments and dollar-quoting."""

    chunks: list[str] = []
    in_single = False
    in_double = False
    i = 0
    paren_depth = 0

    while i < len(text):
        char = text[i]

        if not in_single and not in_double:
            if text.startswith("--", i) or text.startswith("/*", i) or text.startswith("*/", i):
                raise ValueError("SQL comments are not allowed")

            if char == "$":
                raise ValueError("dollar-quoted SQL strings are not allowed")

            if char == ";":
                raise ValueError("multiple SQL statements are not allowed")

            if char == "'":
                in_single = True
                chunks.append(" ")
                i += 1
                continue

            if char == '"':
                in_double = True
                chunks.append(" ")
                i += 1
                continue

            if char == "(":
                paren_depth += 1
            elif char == ")":
                paren_depth -= 1

                if paren_depth < 0:
                    raise ValueError("unbalanced SQL parentheses")

            chunks.append(char)
            i += 1
            continue

        if in_single:
            if char == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    chunks.extend((" ", " "))
                    i += 2
                    continue

                in_single = False

            chunks.append(" ")
            i += 1
            continue

        if char == '"':
            if i + 1 < len(text) and text[i + 1] == '"':
                chunks.extend((" ", " "))
                i += 2
                continue

            in_double = False

        chunks.append(" ")
        i += 1

    if in_single or in_double:
        raise ValueError("unterminated SQL quoted literal")

    if paren_depth != 0:
        raise ValueError("unbalanced SQL parentheses")

    return "".join(chunks)


def _contains_outside_quotes(
    text: str,
    pattern: re.Pattern[str],
) -> bool:
    """Match a regex only against SQL outside quoted literals."""

    masked = _mask_sql_literals(text)
    return bool(pattern.search(masked))


def _reject_sql_comments(text: str) -> None:
    """Reject SQL comments outside quoted literals."""

    _mask_sql_literals(text)


def _validate_read_only_sql(sql: str) -> str:
    statement = sql.strip()

    if not statement:
        raise ValueError("SQL query must not be empty")

    if len(statement) > _MAX_SQL_LENGTH:
        raise ValueError("SQL query exceeds maximum length")

    masked = _mask_sql_literals(statement)

    if not re.match(
        r"^(?:SELECT|WITH)\b",
        masked,
        re.IGNORECASE,
    ):
        raise ValueError("only SELECT/WITH SQL is permitted")

    if _DANGEROUS_SQL_RE.search(masked):
        raise ValueError("write, privilege, or administrative SQL is not permitted")

    return statement


def _validate_where_fragment(query: str) -> str:
    fragment = query.strip()

    if not fragment:
        raise ValueError("log filter must not be empty")

    if len(fragment) > _MAX_WHERE_LENGTH:
        raise ValueError("log filter exceeds maximum length")

    masked = _mask_sql_literals(fragment)

    if _DISALLOWED_WHERE_RE.search(masked):
        raise ValueError("log filter may not contain SQL subqueries or statement/clause keywords")

    return fragment


def _sql_literal(value: str) -> str:
    if "\x00" in value:
        raise ValueError("NUL bytes are not allowed")

    return "'" + value.replace("'", "''") + "'"


def _timestamp_to_iso(value: Any) -> str:
    if value is None or value == "":
        return ""

    try:
        if isinstance(value, (int, float)):
            timestamp = float(value) / 1_000_000.0

            return (
                _dt.datetime.fromtimestamp(
                    timestamp,
                    tz=_dt.UTC,
                )
                .isoformat()
                .replace("+00:00", "Z")
            )

        text = str(value)
        numeric = float(text)

        return (
            _dt.datetime.fromtimestamp(
                numeric / 1_000_000.0,
                tz=_dt.UTC,
            )
            .isoformat()
            .replace("+00:00", "Z")
        )
    except OverflowError, OSError, ValueError:
        pass

    text = str(value)

    try:
        parsed = _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return text

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.UTC)

    return (
        parsed.astimezone(_dt.UTC)
        .isoformat()
        .replace(
            "+00:00",
            "Z",
        )
    )


class OpenObserveClient:
    """Small async client for the documented OpenObserve ``_search`` API."""

    def __init__(self, settings: Settings) -> None:
        self._base_url = settings.openobserve.url.rstrip("/")
        self._email = settings.openobserve.email
        self._password = settings.openobserve.password.get_secret_value()
        self._org = (
            getattr(
                settings.openobserve,
                "organization",
                "default",
            )
            or "default"
        )
        self._client: Any | None = None

    async def _http(self) -> Any:
        if self._client is None:
            import httpx

            self._client = httpx.AsyncClient(
                base_url=self._base_url,
                auth=(self._email, self._password),
                timeout=15.0,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                },
            )

        return self._client

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def search(
        self,
        sql: str,
        lookback_seconds: int,
        limit: int,
    ) -> dict[str, Any]:
        """Run one bounded SQL search and return the raw JSON response."""

        end_us = int(time.time() * 1_000_000)
        start_us = end_us - int(lookback_seconds) * 1_000_000

        body = {
            "query": {
                "sql": sql,
                "start_time": start_us,
                "end_time": end_us,
                "from": 0,
                "size": limit,
            },
            "agent_options": {
                "mode": "partition",
                "output_format": "json",
            },
        }

        http = await self._http()

        try:
            response = await http.post(
                f"/api/{quote(self._org, safe='')}/_search",
                json=body,
            )
            response.raise_for_status()
        except Exception as exc:  # noqa: BLE001 - HTTP client boundary
            detail = str(exc)

            response = locals().get("response")

            if response is not None:
                response_text = getattr(response, "text", "")

                if response_text:
                    detail = f"{detail}; body={response_text[:500]}"

            raise ToolExecutionError(
                "openobserve.search",
                RuntimeError(f"OpenObserve search request failed: {detail}"),
            ) from exc

        try:
            data = response.json()
        except ValueError as exc:
            raise ToolExecutionError(
                "openobserve.search",
                RuntimeError("OpenObserve returned invalid JSON"),
            ) from exc

        if not isinstance(data, dict):
            raise ToolExecutionError(
                "openobserve.search",
                RuntimeError("OpenObserve returned a non-object JSON response"),
            )

        return data


def _query_metric_rows(
    data: dict[str, Any],
) -> list[dict[str, Any]]:
    hits = data.get("hits") or []

    if not isinstance(hits, list):
        raise ToolExecutionError(
            "query_metrics",
            RuntimeError("OpenObserve 'hits' field is not a list"),
        )

    rows: list[dict[str, Any]] = []

    for hit in hits:
        if not isinstance(hit, dict):
            raise ToolExecutionError(
                "query_metrics",
                RuntimeError("OpenObserve returned a non-object hit"),
            )

        rows.append(dict(hit))

    return rows


async def _query_metrics(
    args: QueryMetricsInput,
    context: SREContext,
) -> QueryMetricsOutput:
    client = _require_client(context)
    sql = _validate_read_only_sql(args.sql)

    data = await client.search(
        sql=sql,
        lookback_seconds=args.lookback_seconds,
        limit=args.limit,
    )

    rows = _query_metric_rows(data)

    try:
        total_hits = int(data.get("total", len(rows)))
        took_ms = float(data.get("took", 0.0) or 0.0)
    except (TypeError, ValueError) as exc:
        raise ToolExecutionError(
            "query_metrics",
            RuntimeError("OpenObserve returned invalid numeric metadata"),
        ) from exc

    return QueryMetricsOutput(
        rows=rows,
        total_hits=total_hits,
        took_ms=took_ms,
    )


async def _get_error_clusters(
    args: GetErrorClustersInput,
    context: SREContext,
) -> GetErrorClustersOutput:
    client = _require_client(context)

    service_literal = _sql_literal(args.service)

    sql = (
        "SELECT message AS signature, "
        "COUNT(*) AS count, "
        "MIN(_timestamp) AS first_seen, "
        "MAX(_timestamp) AS last_seen "
        "FROM logs "
        f"WHERE service = {service_literal} "
        "AND UPPER(level) IN ('ERROR', 'FATAL') "
        "GROUP BY message "
        "ORDER BY count DESC "
        f"LIMIT {args.top_n}"
    )

    data = await client.search(
        sql=sql,
        lookback_seconds=args.lookback_seconds,
        limit=args.top_n,
    )

    hits = data.get("hits") or []

    if not isinstance(hits, list):
        raise ToolExecutionError(
            "get_error_clusters",
            RuntimeError("OpenObserve 'hits' field is not a list"),
        )

    clusters: list[ErrorCluster] = []

    for row in hits:
        if not isinstance(row, dict):
            continue

        try:
            count = int(row.get("count") or 0)
        except TypeError, ValueError:
            count = 0

        signature = str(row.get("signature") or "")

        clusters.append(
            ErrorCluster(
                signature=signature,
                count=count,
                sample_message=signature,
                first_seen=_timestamp_to_iso(row.get("first_seen")),
                last_seen=_timestamp_to_iso(row.get("last_seen")),
            )
        )

    return GetErrorClustersOutput(
        service=args.service,
        clusters=clusters,
    )


async def _search_logs(
    args: SearchLogsInput,
    context: SREContext,
) -> SearchLogsOutput:
    client = _require_client(context)
    where = _validate_where_fragment(args.query)

    sql = (
        "SELECT _timestamp AS timestamp, service, level, message "
        "FROM logs "
        f"WHERE ({where}) "
        "ORDER BY _timestamp DESC "
        f"LIMIT {args.limit}"
    )

    data = await client.search(
        sql=sql,
        lookback_seconds=args.lookback_seconds,
        limit=args.limit,
    )

    hits = data.get("hits") or []

    if not isinstance(hits, list):
        raise ToolExecutionError(
            "search_logs",
            RuntimeError("OpenObserve 'hits' field is not a list"),
        )

    result: list[LogHit] = []

    for row in hits:
        if not isinstance(row, dict):
            continue

        service_value = row.get("service")
        level_value = row.get("level")

        result.append(
            LogHit(
                timestamp=_timestamp_to_iso(row.get("timestamp")),
                service=(str(service_value) if service_value is not None else None),
                level=(str(level_value) if level_value is not None else None),
                message=str(row.get("message") or ""),
            )
        )

    try:
        total = int(data.get("total", len(result)))
    except (TypeError, ValueError) as exc:
        raise ToolExecutionError(
            "search_logs",
            RuntimeError("OpenObserve returned an invalid total"),
        ) from exc

    return SearchLogsOutput(
        hits=result,
        total=total,
    )


def _require_client(context: SREContext) -> Any:
    client = getattr(
        context,
        "openobserve_client",
        None,
    )

    if client is None:
        raise ToolExecutionError(
            "observability._require_client",
            RuntimeError("SREContext.openobserve_client is not initialised"),
        )

    if not callable(getattr(client, "search", None)):
        raise ToolExecutionError(
            "observability._require_client",
            TypeError("context.openobserve_client does not implement search()"),
        )

    return client


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all OpenObserve tools."""

    registry.register(
        Tool(
            name="query_metrics",
            description=(
                "Execute one bounded, read-only SQL query against OpenObserve; "
                "only SELECT/WITH statements are accepted."
            ),
            input_model=QueryMetricsInput,
            output_model=QueryMetricsOutput,
            handler=_query_metrics,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_error_clusters",
            description=(
                "Return top error-message clusters for one service over the recent lookback window."
            ),
            input_model=GetErrorClustersInput,
            output_model=GetErrorClustersOutput,
            handler=_get_error_clusters,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="search_logs",
            description=(
                "Search the OpenObserve logs stream with a restricted WHERE "
                "expression; statement keywords and subqueries are rejected."
            ),
            input_model=SearchLogsInput,
            output_model=SearchLogsOutput,
            handler=_search_logs,
            risk_tier=0,
        )
    )
