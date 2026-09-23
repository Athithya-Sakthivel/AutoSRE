"""FastAPI routes for AutoSRE agent.

Endpoints:
  POST /alerts
  POST /incidents/{id}/approve
  GET  /incidents
  GET  /incidents/{id}/report
  GET  /metrics/summary
  GET  /metrics/timeseries
  GET  /metrics/top-expensive
  GET  /healthz
  GET  /readyz
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import uuid
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from math import isfinite
from typing import Annotated, Any, Literal, cast

from fastapi import (
    APIRouter,
    Depends,
    Header,
    HTTPException,
    Query,
    Request,
    status,
)
from fastapi.responses import JSONResponse
from langchain_core.runnables import RunnableConfig
from pydantic import BaseModel, Field

from autosre.api.runner import LangGraphRunner
from autosre.config import Settings

logger = logging.getLogger(__name__)

router = APIRouter()
webhook_router = APIRouter()


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class AlertPayload(BaseModel):
    alert_name: str = Field(..., min_length=1, max_length=200)
    service: str = Field(..., min_length=1, max_length=200)
    namespace: str = Field(..., min_length=1, max_length=200)
    severity: str = Field(
        ...,
        pattern=r"^(sev[1-4]|critical|high|medium|low)$",
    )
    started_at: str = Field(..., max_length=100)
    fingerprint: str = Field(..., max_length=512)
    description: str = Field(default="", max_length=10_000)
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)


class AlertAcceptedResponse(BaseModel):
    incident_id: str
    status: str = "accepted"
    message: str = "Investigation started"


class ApprovalPayload(BaseModel):
    approved: bool
    comment: str = Field(default="", max_length=2_000)


class ApprovalResponse(BaseModel):
    incident_id: str
    approved: bool
    status: str


MetricRange = Literal["1h", "24h", "7d", "30d"]


# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------


def get_settings(request: Request) -> Settings:
    """Return application settings from FastAPI application state."""
    return cast(Settings, request.app.state.settings)


def get_runner(request: Request) -> LangGraphRunner:
    """Return LangGraph runner from FastAPI application state."""
    return cast(LangGraphRunner, request.app.state.runner)


def get_pg_pool(request: Request) -> Any:
    """Return PostgreSQL pool from FastAPI application state."""
    return request.app.state.pg_pool


def _thread_config(thread_id: str) -> RunnableConfig:
    """Build a LangChain RunnableConfig for a specific LangGraph thread."""
    return {
        "configurable": {
            "thread_id": thread_id,
        },
    }


# ---------------------------------------------------------------------------
# Webhook signature verification
# ---------------------------------------------------------------------------


def verify_webhook_signature(
    payload: bytes,
    signature_header: str | None,
    secret: str,
) -> bool:
    if not signature_header:
        return False

    if not signature_header.startswith("sha256="):
        return False

    expected = signature_header[7:]

    if len(expected) != hashlib.sha256().digest_size * 2:
        return False

    computed = hmac.new(
        secret.encode("utf-8"),
        payload,
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(computed, expected)


# ---------------------------------------------------------------------------
# Helpers for status derivation
# ---------------------------------------------------------------------------


def _derive_status(state: Mapping[str, Any]) -> str:
    """Derive incident status string from graph state."""
    phase = state.get("current_phase", "unknown")

    if phase == "complete":
        executed = state.get("executed_actions", [])
        any_success = any(
            isinstance(action, Mapping) and bool(action.get("success")) for action in executed
        )
        return "resolved" if any_success else "complete"

    if phase == "failed":
        return "failed"

    if state.get("requires_human_approval") and state.get("approval_granted") is None:
        return "awaiting_approval"

    return "running"


def _state_to_incident_dict(
    state: Mapping[str, Any],
    fallback_id: str,
) -> dict[str, Any]:
    """Convert raw graph state into the incident shape expected by the UI."""
    metadata = state.get("incident_metadata", {})

    if not isinstance(metadata, Mapping):
        metadata = {}

    return {
        "incident_id": str(metadata.get("incident_id") or fallback_id),
        "status": _derive_status(state),
        "phase": str(state.get("current_phase", "unknown")),
        "alert_name": str(metadata.get("alert_name") or "Unknown"),
        "service": str(metadata.get("service") or ""),
        "namespace": str(metadata.get("namespace") or ""),
        "severity": str(metadata.get("severity") or "medium"),
        "started_at": str(metadata.get("started_at") or ""),
        "hypotheses": list(state.get("hypotheses", [])),
        "proposed_actions": list(state.get("proposed_actions", [])),
        "executed_actions": list(state.get("executed_actions", [])),
        "tokens_used": int(state.get("tokens_used", 0)),
        "cost_usd": float(state.get("cost_usd", 0.0)),
        "wall_clock_seconds": float(state.get("wall_clock_seconds", 0.0)),
        "iterations": int(state.get("iteration_count", 0)),
        "requires_human_approval": bool(state.get("requires_human_approval", False)),
        "approval_granted": state.get("approval_granted"),
    }


def _parse_utc_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None

    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)

    return parsed.astimezone(UTC)


def _finite_float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default

    try:
        result = float(value)
    except TypeError, ValueError:
        return default

    return result if isfinite(result) else default


def _nonnegative_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default

    try:
        result = int(value)
    except TypeError, ValueError:
        return default

    return max(0, result)


def _has_successful_action(state: Mapping[str, Any]) -> bool:
    actions = state.get("executed_actions", [])

    if not isinstance(actions, (list, tuple)):
        return False

    return any(isinstance(action, Mapping) and bool(action.get("success")) for action in actions)


async def _iter_incident_states(
    runner: LangGraphRunner,
) -> list[tuple[str, Mapping[str, Any]]]:
    """Load incident states from the checkpointer.

    Returns a list of ``(thread_id, state_dict)`` tuples.
    Incidents that cannot be loaded are skipped.
    """
    graph = runner.graph
    checkpointer_obj = getattr(graph, "checkpointer", None)

    if checkpointer_obj is None:
        return []

    conn = getattr(checkpointer_obj, "conn", None)

    if conn is None:
        return []

    try:
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT DISTINCT thread_id FROM checkpoints "
                "WHERE checkpoint_ns = '' "
                "ORDER BY thread_id DESC LIMIT 100"
            )
            rows = await cur.fetchall()
    except Exception:
        logger.exception("Failed to list checkpoint thread_ids")
        return []

    results: list[tuple[str, Mapping[str, Any]]] = []

    for row in rows:
        if not isinstance(row, (tuple, list)) or not row:
            continue

        thread_id = row[0]

        if not isinstance(thread_id, str) or not thread_id:
            continue

        try:
            snapshot = await graph.aget_state(_thread_config(thread_id))
        except Exception:
            continue

        if snapshot is None:
            continue

        state = getattr(snapshot, "values", None)

        if not isinstance(state, Mapping):
            continue

        results.append((thread_id, state))

    return results


# ---------------------------------------------------------------------------
# Webhook routes
# ---------------------------------------------------------------------------


@webhook_router.post(
    "/alerts",
    response_model=AlertAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def receive_alert(
    request: Request,
    alert: AlertPayload,
    settings: Annotated[Settings, Depends(get_settings)],
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
    x_webhook_signature: Annotated[
        str | None,
        Header(alias="X-Webhook-Signature"),
    ] = None,
) -> AlertAcceptedResponse:
    webhook_secret = settings.alert.webhook_secret.get_secret_value()
    payload_bytes = await request.body()

    if not verify_webhook_signature(
        payload_bytes,
        x_webhook_signature,
        webhook_secret,
    ):
        logger.warning(
            "Invalid webhook signature",
            extra={"alert_name": alert.alert_name},
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid webhook signature",
        )

    incident_id = str(uuid.uuid4())

    logger.info(
        "Received alert: %s for %s",
        alert.alert_name,
        alert.service,
        extra={
            "incident_id": incident_id,
            "alert_name": alert.alert_name,
            "service": alert.service,
            "namespace": alert.namespace,
            "severity": alert.severity,
        },
    )

    await runner.run_incident(incident_id, alert.model_dump())

    return AlertAcceptedResponse(incident_id=incident_id)


@webhook_router.post(
    "/incidents/{incident_id}/approve",
    response_model=ApprovalResponse,
    status_code=status.HTTP_200_OK,
)
async def approve_incident(
    request: Request,
    incident_id: str,
    approval: ApprovalPayload,
    settings: Annotated[Settings, Depends(get_settings)],
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
    x_webhook_signature: Annotated[
        str | None,
        Header(alias="X-Webhook-Signature"),
    ] = None,
) -> ApprovalResponse:
    webhook_secret = settings.alert.webhook_secret.get_secret_value()
    payload_bytes = await request.body()

    if not verify_webhook_signature(
        payload_bytes,
        x_webhook_signature,
        webhook_secret,
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid webhook signature",
        )

    logger.info(
        "Received approval for incident %s: %s",
        incident_id,
        "approved" if approval.approved else "rejected",
    )

    found = await runner.approve_incident(
        incident_id,
        approval.approved,
        approval.comment,
    )

    if not found:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=(f"Incident {incident_id} not found or already approved"),
        )

    return ApprovalResponse(
        incident_id=incident_id,
        approved=approval.approved,
        status="approved" if approval.approved else "rejected",
    )


# ---------------------------------------------------------------------------
# Incident query routes
# ---------------------------------------------------------------------------


@router.get("/incidents")
async def list_incidents(
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
) -> dict[str, Any]:
    """List all incidents."""
    incident_states = await _iter_incident_states(runner)

    items = [_state_to_incident_dict(state, thread_id) for thread_id, state in incident_states]

    items.sort(
        key=lambda item: str(item.get("started_at", "")),
        reverse=True,
    )

    return {
        "items": items,
        "total": len(items),
    }


@router.get("/incidents/{incident_id}/report")
async def get_incident_report(
    incident_id: str,
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
) -> dict[str, Any]:
    """Return the full state of a single incident."""
    try:
        state_snapshot = await runner.graph.aget_state(_thread_config(incident_id))
    except Exception as exc:
        logger.error(
            "Failed to retrieve state for incident %s: %s",
            incident_id,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to retrieve state: {exc}",
        ) from exc

    if state_snapshot is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Incident not found",
        )

    state = getattr(state_snapshot, "values", None)

    if not isinstance(state, Mapping):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Incident not found",
        )

    return _state_to_incident_dict(state, incident_id)


# ---------------------------------------------------------------------------
# Metrics routes
# ---------------------------------------------------------------------------


@router.get("/metrics/summary")
async def metrics_summary(
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
) -> dict[str, Any]:
    """Aggregate metrics across all incidents."""
    incident_states = await _iter_incident_states(runner)

    total = len(incident_states)
    resolved_count = 0
    awaiting_approval_count = 0
    failed_count = 0
    total_cost = 0.0
    total_tokens = 0
    resolved_wall_clocks: list[float] = []
    safety_violations = 0
    categories: dict[str, int] = {}

    for _thread_id, state in incident_states:
        status_str = _derive_status(state)

        if status_str == "resolved":
            resolved_count += 1

            wall_clock = _finite_float(state.get("wall_clock_seconds"))

            if wall_clock > 0:
                resolved_wall_clocks.append(wall_clock)

        elif status_str == "failed":
            failed_count += 1

        elif status_str == "awaiting_approval":
            awaiting_approval_count += 1

        total_cost += max(
            0.0,
            _finite_float(state.get("cost_usd")),
        )
        total_tokens += _nonnegative_int(state.get("tokens_used"))

        metadata = state.get("incident_metadata", {})

        if isinstance(metadata, Mapping):
            alert_name = str(metadata.get("alert_name") or "Unknown")
            categories[alert_name] = categories.get(alert_name, 0) + 1

        executed_actions = state.get("executed_actions", [])

        if isinstance(executed_actions, (list, tuple)):
            for action in executed_actions:
                if isinstance(action, Mapping):
                    tier = _nonnegative_int(
                        action.get("risk_tier"),
                        0,
                    )
                    if tier >= 4:
                        safety_violations += 1

    avg_mttr = (
        sum(resolved_wall_clocks) / len(resolved_wall_clocks) if resolved_wall_clocks else 0.0
    )

    return {
        "total_incidents": total,
        "resolved_count": resolved_count,
        "awaiting_approval_count": awaiting_approval_count,
        "failed_count": failed_count,
        "avg_mttr_seconds": round(avg_mttr, 2),
        "total_cost_usd": round(total_cost, 6),
        "total_tokens": total_tokens,
        "safety_violations": safety_violations,
        "incidents_by_category": categories,
    }


@router.get("/metrics/timeseries")
async def metrics_timeseries(
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
    metric_range: Annotated[
        MetricRange,
        Query(alias="range"),
    ] = "24h",
) -> dict[str, Any]:
    """Return time-bucketed incident metrics."""
    range_map: dict[
        MetricRange,
        tuple[timedelta, timedelta],
    ] = {
        "1h": (
            timedelta(hours=1),
            timedelta(minutes=5),
        ),
        "24h": (
            timedelta(hours=24),
            timedelta(hours=1),
        ),
        "7d": (
            timedelta(days=7),
            timedelta(hours=6),
        ),
        "30d": (
            timedelta(days=30),
            timedelta(days=1),
        ),
    }

    lookback, bucket_size = range_map[metric_range]
    cutoff = datetime.now(UTC) - lookback
    bucket_seconds = int(bucket_size.total_seconds())
    bucket_count = max(
        1,
        int(lookback.total_seconds() / bucket_seconds),
    )

    incident_states = await _iter_incident_states(runner)

    accumulators: list[dict[str, int | float]] = [
        {
            "incidents": 0,
            "resolved": 0,
            "resolved_wall_clock_seconds": 0.0,
            "total_cost_usd": 0.0,
            "total_tokens": 0,
        }
        for _ in range(bucket_count)
    ]

    for _thread_id, state in incident_states:
        metadata = state.get("incident_metadata", {})

        if not isinstance(metadata, Mapping):
            continue

        started_at = _parse_utc_datetime(metadata.get("started_at"))

        if started_at is None or started_at < cutoff:
            continue

        bucket_index = int((started_at - cutoff).total_seconds() // bucket_seconds)

        if bucket_index < 0 or bucket_index >= bucket_count:
            continue

        acc = accumulators[bucket_index]

        acc["incidents"] = int(acc["incidents"]) + 1
        acc["total_cost_usd"] = float(acc["total_cost_usd"]) + max(
            0.0,
            _finite_float(state.get("cost_usd")),
        )
        acc["total_tokens"] = int(acc["total_tokens"]) + _nonnegative_int(state.get("tokens_used"))

        if state.get("current_phase") == "complete" and _has_successful_action(state):
            acc["resolved"] = int(acc["resolved"]) + 1
            acc["resolved_wall_clock_seconds"] = float(acc["resolved_wall_clock_seconds"]) + max(
                0.0,
                _finite_float(state.get("wall_clock_seconds")),
            )

    buckets: list[dict[str, Any]] = []

    for index, acc in enumerate(accumulators):
        resolved = int(acc["resolved"])

        avg_mttr = float(acc["resolved_wall_clock_seconds"]) / resolved if resolved else 0.0

        bucket_start = cutoff + bucket_size * index

        buckets.append(
            {
                "timestamp": bucket_start.isoformat(),
                "incidents": int(acc["incidents"]),
                "resolved": resolved,
                "avg_mttr_seconds": round(avg_mttr, 2),
                "total_cost_usd": round(
                    float(acc["total_cost_usd"]),
                    6,
                ),
                "total_tokens": int(acc["total_tokens"]),
            }
        )

    return {
        "buckets": buckets,
        "range": metric_range,
    }


@router.get("/metrics/top-expensive")
async def top_expensive_incidents(
    runner: Annotated[LangGraphRunner, Depends(get_runner)],
    limit: Annotated[
        int,
        Query(ge=1, le=100),
    ] = 5,
) -> list[dict[str, Any]]:
    """Return the most expensive completed incidents."""
    incident_states = await _iter_incident_states(runner)
    incidents_with_cost: list[dict[str, Any]] = []

    for thread_id, state in incident_states:
        cost = max(
            0.0,
            _finite_float(state.get("cost_usd")),
        )

        if cost <= 0.0:
            continue

        phase = state.get("current_phase")

        if phase == "complete":
            status_str = "resolved" if _has_successful_action(state) else "complete"
        elif phase == "failed":
            status_str = "failed"
        else:
            continue

        metadata = state.get("incident_metadata", {})

        if not isinstance(metadata, Mapping):
            metadata = {}

        incidents_with_cost.append(
            {
                "incident_id": str(metadata.get("incident_id") or thread_id),
                "alert_name": str(metadata.get("alert_name") or "Unknown"),
                "service": str(metadata.get("service") or ""),
                "cost_usd": round(cost, 6),
                "wall_clock_seconds": max(
                    0.0,
                    _finite_float(state.get("wall_clock_seconds")),
                ),
                "status": status_str,
            }
        )

    incidents_with_cost.sort(
        key=lambda item: item["cost_usd"],
        reverse=True,
    )

    return incidents_with_cost[:limit]


# ---------------------------------------------------------------------------
# Health probes
# ---------------------------------------------------------------------------


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {
        "status": "ok",
        "version": "0.1.0",
    }


@router.get("/readyz")
async def readyz(
    pg_pool: Annotated[Any, Depends(get_pg_pool)],
) -> JSONResponse:
    checks: dict[str, str] = {}

    try:
        async with (
            pg_pool.connection() as conn,
            conn.cursor() as cur,
        ):
            await cur.execute("SELECT 1")

        checks["postgres"] = "ok"

        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={
                "status": "ready",
                "checks": checks,
            },
        )

    except Exception as exc:
        logger.error(
            "Postgres readiness check failed: %s",
            exc,
        )

        checks["postgres"] = "failed"

        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={
                "status": "not_ready",
                "checks": checks,
            },
        )
