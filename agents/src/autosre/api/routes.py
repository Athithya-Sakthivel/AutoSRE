"""FastAPI routes for AutoSRE agent API.

Endpoints:
  POST /alerts                              — trigger incident (202 Accepted)
  GET  /incidents                           — list all incidents
  GET  /incidents/{id}/report               — get incident report
  POST /incidents/{id}/approve              — approve/reject
  GET  /metrics/summary                     — aggregate KPIs
  GET  /metrics/timeseries?time_range=24h   — time-bucketed data
  GET  /metrics/top-expensive?limit=5       — top N expensive
  GET  /healthz                             — liveness
  GET  /readyz                              — readiness
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import traceback
from collections import defaultdict
from datetime import UTC, datetime
from typing import Annotated, Any, cast

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, SecretStr

from autosre.config import Settings, get_settings
from autosre.runner_protocol import RunnerProtocol

logger = logging.getLogger(__name__)

router = APIRouter()
webhook_router = APIRouter()

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class AlertPayload(BaseModel):
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    fingerprint: str
    description: str = ""
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)


class ApprovalRequest(BaseModel):
    approved: bool
    comment: str = ""


class IncidentSummary(BaseModel):
    incident_id: str
    status: str
    phase: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    requires_human_approval: bool
    approval_granted: bool | None
    tokens_used: int
    cost_usd: float
    wall_clock_seconds: float
    iterations: int


class IncidentListResponse(BaseModel):
    items: list[IncidentSummary]
    total: int


class MetricsSummary(BaseModel):
    total_incidents: int
    resolved_count: int
    awaiting_approval_count: int
    failed_count: int
    avg_mttr_seconds: float
    total_cost_usd: float
    total_tokens: int
    safety_violations: int
    incidents_by_category: dict[str, int]


class MetricBucket(BaseModel):
    timestamp: str
    incidents: int
    resolved: int
    avg_mttr_seconds: float
    total_cost_usd: float
    total_tokens: int


class MetricsTimeseriesResponse(BaseModel):
    buckets: list[MetricBucket]
    range: str


class ExpensiveIncident(BaseModel):
    incident_id: str
    alert_name: str
    service: str
    cost_usd: float
    wall_clock_seconds: float
    status: str


# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------


def get_runner(request: Request) -> RunnerProtocol:
    """Get the runner from app state, typed as RunnerProtocol."""
    return cast(RunnerProtocol, request.app.state.runner)


def get_settings_dep() -> Settings:
    """Get settings dependency."""
    return get_settings()


# Type aliases for FastAPI dependencies (avoids B008 lint error)
Runner = Annotated[RunnerProtocol, Depends(get_runner)]
AppSettings = Annotated[Settings, Depends(get_settings_dep)]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _verify_signature(
    payload: bytes,
    signature: str,
    secret: str | SecretStr,
) -> bool:
    """Verify HMAC-SHA256 webhook signature."""
    if not signature.startswith("sha256="):
        return False

    if isinstance(secret, SecretStr):
        secret = secret.get_secret_value()

    expected = hmac.new(
        secret.encode("utf-8"),
        payload,
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(signature[7:], expected)


def _extract_summary(incident_id: str, values: dict[str, Any]) -> IncidentSummary:
    """Build an IncidentSummary from state values."""
    metadata = values.get("incident_metadata", {})
    return IncidentSummary(
        incident_id=incident_id,
        status=values.get("status", "unknown"),
        phase=values.get("current_phase", "unknown"),
        alert_name=metadata.get("alert_name", ""),
        service=metadata.get("service", ""),
        namespace=metadata.get("namespace", ""),
        severity=metadata.get("severity", ""),
        started_at=metadata.get("started_at", ""),
        requires_human_approval=values.get("requires_human_approval", False),
        approval_granted=values.get("approval_granted"),
        tokens_used=values.get("tokens_used", 0),
        cost_usd=values.get("cost_usd", 0.0),
        wall_clock_seconds=values.get("wall_clock_seconds", 0.0),
        iterations=values.get("iteration_count", 0),
    )


# ---------------------------------------------------------------------------
# Health & Readiness
# ---------------------------------------------------------------------------


@router.get("/healthz")
async def healthz() -> dict[str, Any]:
    """Liveness check."""
    return {"status": "ok", "version": "0.1.0"}


@router.get("/readyz")
async def readyz(request: Request) -> JSONResponse:
    """Readiness check — verifies Postgres connectivity."""
    checks: dict[str, str] = {}

    pg_pool = getattr(request.app.state, "pg_pool", None)
    if pg_pool is None:
        checks["postgres"] = "not_configured"
    else:
        try:
            async with pg_pool.connection() as conn, conn.cursor() as cur:
                await cur.execute("SELECT 1")
            checks["postgres"] = "ready"
        except Exception as exc:
            checks["postgres"] = f"error: {exc}"

    all_ready = all(v == "ready" for v in checks.values())

    return JSONResponse(
        status_code=200 if all_ready else 503,
        content={
            "status": "ready" if all_ready else "not_ready",
            "checks": checks,
        },
    )


# ---------------------------------------------------------------------------
# Webhook Endpoints
# ---------------------------------------------------------------------------


@webhook_router.post("/alerts", status_code=status.HTTP_202_ACCEPTED)
async def trigger_incident(
    request: Request,
    runner: Runner,
    settings: AppSettings,
) -> dict[str, Any]:
    """Trigger an incident via webhook. Returns 202 Accepted."""
    try:
        payload = await request.body()
        signature = request.headers.get("X-Webhook-Signature", "")

        if not _verify_signature(payload, signature, settings.alert.webhook_secret):
            raise HTTPException(status_code=401, detail="Invalid webhook signature")

        try:
            alert = AlertPayload.model_validate_json(payload)
        except Exception as exc:
            raise HTTPException(status_code=422, detail=f"Invalid alert payload: {exc}") from exc

        logger.info(
            "Alert received: %s on %s/%s",
            alert.alert_name,
            alert.namespace,
            alert.service,
        )

        incident_id = await runner.run_incident(alert.model_dump())

        logger.info("Incident %s created", incident_id)
        return {"incident_id": incident_id, "status": "accepted"}

    except HTTPException:
        raise
    except Exception as exc:
        logger.error(
            "Unexpected error in trigger_incident: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(status_code=500, detail=f"Internal error: {exc!s}") from exc


@webhook_router.post("/incidents/{incident_id}/approve")
async def approve_incident(
    incident_id: str,
    request: Request,
    approval: ApprovalRequest,
    runner: Runner,
    settings: AppSettings,
) -> dict[str, Any]:
    """Approve or reject an incident."""
    payload = await request.body()
    signature = request.headers.get("X-Webhook-Signature", "")

    if not _verify_signature(payload, signature, settings.alert.webhook_secret):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")

    approved = await runner.approve_incident(incident_id, approval.approved, approval.comment)

    return {
        "incident_id": incident_id,
        "approved": approved,
        "status": "approved" if approved else "rejected",
    }


# ---------------------------------------------------------------------------
# Incident Endpoints
# ---------------------------------------------------------------------------


@router.get("/incidents")
async def list_incidents(
    runner: Runner,
    status_filter: str | None = Query(None, alias="status", description="Filter by status"),
    limit: int = Query(100, ge=1, le=500),
) -> IncidentListResponse:
    """List all incidents."""
    try:
        all_states = await runner.list_incidents(limit=limit)

        items: list[IncidentSummary] = []
        for incident_id, state in all_states:
            values = state.values if hasattr(state, "values") else state
            if not isinstance(values, dict):
                continue

            summary = _extract_summary(incident_id, values)
            if status_filter and summary.status != status_filter:
                continue
            items.append(summary)

        return IncidentListResponse(items=items, total=len(items))

    except Exception as exc:
        logger.error("Error in list_incidents: %s\n%s", exc, traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Failed to list incidents: {exc!s}") from exc


@router.get("/incidents/{incident_id}/report")
async def get_incident_report(
    incident_id: str,
    runner: Runner,
) -> dict[str, Any]:
    """Get full incident report."""
    state = await runner.get_incident_state(incident_id)

    if state is None:
        raise HTTPException(status_code=404, detail=f"Incident {incident_id} not found")

    # Safely extract values, handling both State objects and dicts
    values = state.values if hasattr(state, "values") else state

    # Defensive: ensure values is a dict
    if not isinstance(values, dict):
        logger.error(
            "State values is not a dict for incident %s: %s",
            incident_id,
            type(values),
        )
        raise HTTPException(
            status_code=500,
            detail=f"Invalid state format for incident {incident_id}",
        )

    metadata = values.get("incident_metadata", {})

    # Defensive: ensure metadata is a dict
    if not isinstance(metadata, dict):
        logger.warning(
            "Metadata is not a dict for incident %s, using empty dict",
            incident_id,
        )
        metadata = {}

    return {
        "incident_id": incident_id,
        "status": values.get("status", "unknown"),
        "phase": values.get("current_phase", "unknown"),
        "alert_name": metadata.get("alert_name", ""),
        "service": metadata.get("service", ""),
        "namespace": metadata.get("namespace", ""),
        "severity": metadata.get("severity", ""),
        "started_at": metadata.get("started_at", ""),
        "hypotheses": values.get("hypotheses", []),
        "proposed_actions": values.get("proposed_actions", []),
        "executed_actions": values.get("executed_actions", []),
        "tokens_used": values.get("tokens_used", 0),
        "cost_usd": values.get("cost_usd", 0.0),
        "wall_clock_seconds": values.get("wall_clock_seconds", 0.0),
        "iterations": values.get("iteration_count", 0),
        "requires_human_approval": values.get("requires_human_approval", False),
        "approval_granted": values.get("approval_granted"),
    }


# ---------------------------------------------------------------------------
# Metrics Endpoints
# ---------------------------------------------------------------------------


@router.get("/metrics/summary")
async def get_metrics_summary(
    runner: Runner,
) -> MetricsSummary:
    """Get aggregate metrics across all incidents."""
    try:
        all_states = await runner.list_incidents(limit=1000)

        resolved = 0
        awaiting = 0
        failed = 0
        wall_clocks: list[float] = []
        total_cost = 0.0
        total_tokens = 0
        safety_violations = 0
        by_category: dict[str, int] = defaultdict(int)

        prohibited = {"delete_namespace", "flush_all", "drop_table"}

        for _iid, state in all_states:
            values = state.values if hasattr(state, "values") else state
            if not isinstance(values, dict):
                continue

            s = values.get("status", "unknown")
            if s in ("resolved", "complete"):
                resolved += 1
                wc = values.get("wall_clock_seconds", 0.0)
                if wc > 0:
                    wall_clocks.append(float(wc))
            elif s == "failed":
                failed += 1
            elif s == "awaiting_approval":
                awaiting += 1

            total_cost += float(values.get("cost_usd", 0.0))
            total_tokens += int(values.get("tokens_used", 0))

            metadata = values.get("incident_metadata", {})
            category = metadata.get("labels", {}).get("category", "unknown")
            if not category:
                category = metadata.get("category", "unknown")
            by_category[category] += 1

            for action in values.get("executed_actions", []):
                if isinstance(action, dict) and action.get("tool_name") in prohibited:
                    safety_violations += 1

        avg_mttr = sum(wall_clocks) / len(wall_clocks) if wall_clocks else 0.0

        return MetricsSummary(
            total_incidents=len(all_states),
            resolved_count=resolved,
            awaiting_approval_count=awaiting,
            failed_count=failed,
            avg_mttr_seconds=round(avg_mttr, 2),
            total_cost_usd=round(total_cost, 6),
            total_tokens=total_tokens,
            safety_violations=safety_violations,
            incidents_by_category=dict(by_category),
        )

    except Exception as exc:
        logger.error(
            "Error in get_metrics_summary: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(status_code=500, detail=f"Failed to get metrics: {exc!s}") from exc


@router.get("/metrics/timeseries")
async def get_metrics_timeseries(
    runner: Runner,
    time_range: str = Query("24h", pattern="^(1h|24h|7d|30d)$", alias="range"),
) -> MetricsTimeseriesResponse:
    """Get time-bucketed metrics."""
    try:
        all_states = await runner.list_incidents(limit=1000)

        bucket_minutes = {"1h": 5, "24h": 60, "7d": 360, "30d": 1440}[time_range]
        buckets: dict[str, dict[str, Any]] = {}

        for _iid, state in all_states:
            values = state.values if hasattr(state, "values") else state
            if not isinstance(values, dict):
                continue

            metadata = values.get("incident_metadata", {})
            started_at_str = metadata.get("started_at", "")
            if not started_at_str:
                continue

            try:
                started_at = datetime.fromisoformat(started_at_str.replace("Z", "+00:00"))
                if started_at.tzinfo is None:
                    started_at = started_at.replace(tzinfo=UTC)
            except ValueError, TypeError:
                continue

            bucket_minute = (started_at.minute // bucket_minutes) * bucket_minutes
            bucket_ts = started_at.replace(
                minute=bucket_minute % 60,
                hour=started_at.hour + bucket_minute // 60,
                second=0,
                microsecond=0,
            )
            bucket_key = bucket_ts.isoformat()

            if bucket_key not in buckets:
                buckets[bucket_key] = {
                    "incidents": 0,
                    "resolved": 0,
                    "wall_clocks": [],
                    "total_cost": 0.0,
                    "total_tokens": 0,
                }

            buckets[bucket_key]["incidents"] += 1
            s = values.get("status", "unknown")
            if s in ("resolved", "complete"):
                buckets[bucket_key]["resolved"] += 1
                wc = values.get("wall_clock_seconds", 0.0)
                if wc > 0:
                    buckets[bucket_key]["wall_clocks"].append(float(wc))
            buckets[bucket_key]["total_cost"] += float(values.get("cost_usd", 0.0))
            buckets[bucket_key]["total_tokens"] += int(values.get("tokens_used", 0))

        result_buckets: list[MetricBucket] = []
        for ts, data in sorted(buckets.items()):
            wc_list = data["wall_clocks"]
            avg_mttr = sum(wc_list) / len(wc_list) if wc_list else 0.0
            result_buckets.append(
                MetricBucket(
                    timestamp=ts,
                    incidents=data["incidents"],
                    resolved=data["resolved"],
                    avg_mttr_seconds=round(avg_mttr, 2),
                    total_cost_usd=round(data["total_cost"], 6),
                    total_tokens=data["total_tokens"],
                )
            )

        return MetricsTimeseriesResponse(buckets=result_buckets, range=time_range)

    except Exception as exc:
        logger.error(
            "Error in get_metrics_timeseries: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(status_code=500, detail=f"Failed to get timeseries: {exc!s}") from exc


@router.get("/metrics/top-expensive")
async def get_top_expensive(
    runner: Runner,
    limit: int = Query(5, ge=1, le=100),
) -> list[ExpensiveIncident]:
    """Get top N most expensive incidents."""
    try:
        all_states = await runner.list_incidents(limit=1000)

        incidents: list[tuple[float, ExpensiveIncident]] = []
        for incident_id, state in all_states:
            values = state.values if hasattr(state, "values") else state
            if not isinstance(values, dict):
                continue

            metadata = values.get("incident_metadata", {})
            cost = float(values.get("cost_usd", 0.0))

            incidents.append(
                (
                    cost,
                    ExpensiveIncident(
                        incident_id=incident_id,
                        alert_name=metadata.get("alert_name", ""),
                        service=metadata.get("service", ""),
                        cost_usd=cost,
                        wall_clock_seconds=float(values.get("wall_clock_seconds", 0.0)),
                        status=values.get("status", "unknown"),
                    ),
                )
            )

        incidents.sort(key=lambda x: x[0], reverse=True)
        return [item for _, item in incidents[:limit]]

    except Exception as exc:
        logger.error(
            "Error in get_top_expensive: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(
            status_code=500, detail=f"Failed to get top expensive: {exc!s}"
        ) from exc
