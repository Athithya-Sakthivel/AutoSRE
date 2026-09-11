"""Return traces and exceptions from Azure Log Analytics."""

from __future__ import annotations

from typing import Any

from opentelemetry import trace

from ..helpers import format_log_rows, run_log_analytics_query, traces_kql, utc_now_iso
from ..runtime import get_runtime


async def query_traces(
    service_name: str, time_range_minutes: int = 30, limit: int = 25
) -> dict[str, Any]:
    """Find recent traces and exceptions for a service."""
    if time_range_minutes <= 0:
        raise ValueError("time_range_minutes must be > 0")
    if limit <= 0:
        raise ValueError("limit must be > 0")

    runtime = get_runtime()
    tracer = trace.get_tracer(runtime.settings.service_name)

    with tracer.start_as_current_span("query_traces") as span:
        kql = traces_kql(service_name, time_range_minutes, limit)
        payload = await run_log_analytics_query(kql, time_range_minutes)
        rows = format_log_rows(payload)
        span.set_attribute("mcp.tool", "query_traces")
        span.set_attribute("mcp.row_count", len(rows))
        return {
            "service_name": service_name,
            "time_range_minutes": time_range_minutes,
            "limit": limit,
            "count": len(rows),
            "rows": rows,
            "queried_at": utc_now_iso(),
        }
