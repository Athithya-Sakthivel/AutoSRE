"""FastAPI routes for the AutoSRE agent API.

## Endpoints

### Health
    GET  /healthz                          Liveness. Always 200.
    GET  /readyz                           Readiness. 200 when Postgres responds.

### Webhook ingress (HMAC signed)
    POST /alerts                           Trigger an incident. 202 Accepted.
    POST /incidents/{id}/approve           Resume a paused HITL interrupt.
    POST /api/sign-approval                Sign an approval body for the UI.

### Incident queries
    GET  /incidents                        List incidents (with status filter).
    GET  /incidents/{id}/report            Full incident report.

### Metrics
    GET  /metrics/summary                  Aggregate KPIs.
    GET  /metrics/timeseries?range=24h     Epoch-aligned time buckets.
    GET  /metrics/top-expensive?limit=5    Top N by cost.

### Admin (X-Admin-Secret header)
    POST /admin/pause                      Reject new incidents.
    POST /admin/resume                     Accept new incidents.
    GET  /admin/status                     Current pause state.

## Contracts

### Webhook signature
Every webhook endpoint verifies HMAC-SHA256 over the raw request body
against ``settings.alert.webhook_secret``. The signature header is
``X-Webhook-Signature: sha256=<hex>``. Invalid signatures return 401.

### Timing
Two MTTR fields are surfaced:
    wall_clock_seconds   Total elapsed, including rate-limit backoff.
    active_seconds       wall_clock minus backoff. The honest MTTR.

The metrics summary computes ``mttr_reduction_pct`` from
``active_seconds`` against a per-incident baseline declared in
``labels['baseline_mttr_seconds']`` by the eval harness.

### Status derivation
``awaiting_approval`` is a derived status surfaced on IncidentSummary
when ``requires_human_approval=True`` and ``approval_granted is None``.
The underlying state.status remains ``running``.

### Timeseries bucketing
Buckets are epoch-aligned:
    bucket_seconds = bucket_minutes * 60
    bucket_epoch   = (floor(started_at) // bucket_seconds) * bucket_seconds
This guarantees chronological ordering across all ranges.

### Rate limiting
``/alerts`` is limited per client IP by an in-process token bucket. The
limit is not shared across replicas; a multi-replica deployment must
move this to a shared store. Documented in ``_RateLimiter``.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import time
import traceback
from collections import defaultdict, deque
from datetime import UTC, datetime
from typing import Annotated, Any, cast

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, SecretStr

from autosre.config import Settings, get_settings
from autosre.core.router import LLMBudgetExhaustedError
from autosre.runner_protocol import RunnerProtocol

logger = logging.getLogger(__name__)

router = APIRouter()
webhook_router = APIRouter()

# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

_ALERTS_RATE_LIMIT = 10
_ALERTS_RATE_WINDOW_SECONDS = 60


class _RateLimiter:
    """In-process token bucket keyed by client identifier.

    Single-replica only. A multi-replica deployment must back this with
    Redis or an ingress rate limiter. Left in-process deliberately so
    the module has no extra dependency for the local harness.
    """

    def __init__(self, max_requests: int, window_seconds: float) -> None:
        if max_requests <= 0:
            raise ValueError("max_requests must be > 0")
        if window_seconds <= 0:
            raise ValueError("window_seconds must be > 0")

        self._max = max_requests
        self._window = window_seconds
        self._requests: dict[str, deque[float]] = defaultdict(deque)
        self._lock = asyncio.Lock()

    async def allow(self, key: str) -> bool:
        """Return True if a request from ``key`` is allowed now."""
        now = time.monotonic()
        async with self._lock:
            q = self._requests[key]
            cutoff = now - self._window
            while q and q[0] < cutoff:
                q.popleft()
            if len(q) >= self._max:
                return False
            q.append(now)
            return True

    def reset(self) -> None:
        """Clear all buckets. Used by tests."""
        self._requests.clear()


_alerts_limiter = _RateLimiter(_ALERTS_RATE_LIMIT, _ALERTS_RATE_WINDOW_SECONDS)


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class AlertPayload(BaseModel):
    """Alert webhook payload."""

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
    """Approval decision payload."""

    approved: bool
    comment: str = ""


class IncidentSummary(BaseModel):
    """Incident list-view record.

    ``awaiting_approval`` is a derived status: when the graph is paused on
    a HITL interrupt, the underlying state.status remains ``running`` but
    this field surfaces ``awaiting_approval`` so list views can filter.
    """

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
    active_seconds: float
    backoff_seconds: float
    iterations: int
    proposed_actions: list[dict[str, Any]] = Field(default_factory=list)
    executed_actions: list[dict[str, Any]] = Field(default_factory=list)


class IncidentListResponse(BaseModel):
    """Response for listing incidents."""

    items: list[IncidentSummary]
    total: int


class IncidentReportResponse(BaseModel):
    """Full incident report."""

    incident_id: str
    status: str
    phase: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    hypotheses: list[dict[str, Any]] = Field(default_factory=list)
    proposed_actions: list[dict[str, Any]] = Field(default_factory=list)
    executed_actions: list[dict[str, Any]] = Field(default_factory=list)
    tokens_used: int
    cost_usd: float
    wall_clock_seconds: float
    active_seconds: float
    backoff_seconds: float
    iterations: int
    requires_human_approval: bool
    approval_granted: bool | None


class MetricsSummary(BaseModel):
    """Aggregate KPIs across all incidents.

    ``mttr_reduction_pct`` compares the agent's mean ``active_seconds``
    against the mean ``baseline_mttr_seconds`` declared by the dataset.
    When the baseline is unavailable or zero, the field is 0.0.
    """

    total_incidents: int
    resolved_count: int
    awaiting_approval_count: int
    failed_count: int
    no_action_count: int
    avg_mttr_seconds: float
    avg_wall_clock_seconds: float
    avg_backoff_seconds: float
    baseline_mttr_seconds: float
    mttr_reduction_pct: float
    total_cost_usd: float
    total_tokens: int
    safety_violations: int
    incidents_by_category: dict[str, int]


class MetricBucket(BaseModel):
    """One epoch-aligned time bucket."""

    timestamp: str
    incidents: int
    resolved: int
    no_action: int
    failed: int
    avg_mttr_seconds: float
    total_cost_usd: float
    total_tokens: int


class MetricsTimeseriesResponse(BaseModel):
    """Time-bucketed metrics."""

    buckets: list[MetricBucket]
    range: str


class ExpensiveIncident(BaseModel):
    """Top-N expensive incident record."""

    incident_id: str
    alert_name: str
    service: str
    cost_usd: float
    wall_clock_seconds: float
    status: str


class AdminStatusResponse(BaseModel):
    """Response for /admin/status."""

    paused: bool
    reason: str | None = None


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_PROHIBITED_TOOLS = frozenset({"delete_namespace", "flush_all", "drop_table"})
_TERMINAL_SUCCESS_STATUSES = frozenset({"resolved"})
_TERMINAL_FAILURE_STATUSES = frozenset({"failed", "blocked"})
_NO_ACTION_STATUSES = frozenset({"no_action"})

_BUCKET_MINUTES_BY_RANGE: dict[str, int] = {
    "1h": 5,
    "24h": 60,
    "7d": 360,
    "30d": 1440,
}


# ---------------------------------------------------------------------------
# Dependency injection
# ---------------------------------------------------------------------------


def get_runner(request: Request) -> RunnerProtocol:
    """Return the LangGraphRunner bound to the running FastAPI app."""
    runner = getattr(request.app.state, "runner", None)
    if runner is None:
        raise HTTPException(
            status_code=503,
            detail="Runner not initialized",
        )
    return cast(RunnerProtocol, runner)


def get_settings_dep(request: Request) -> Settings:
    """Return the Settings bound to the running app.

    Prefers ``app.state.settings`` so ``create_app(settings)`` is the
    single source of truth. Falls back to the process-wide cache only
    when the app was constructed without explicit settings.
    """
    settings = getattr(request.app.state, "settings", None)
    if isinstance(settings, Settings):
        return settings
    return get_settings()


Runner = Annotated[RunnerProtocol, Depends(get_runner)]
AppSettings = Annotated[Settings, Depends(get_settings_dep)]


# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------


def _verify_signature(
    payload: bytes,
    signature: str,
    secret: str | SecretStr,
) -> bool:
    """Verify an HMAC-SHA256 webhook signature in constant time."""
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


def _require_admin_secret(request: Request, settings: Settings) -> None:
    """Raise 401/503 unless the caller supplied the correct admin secret.

    Uses ``settings.admin.secret``. When the secret is unset, the endpoint
    is disabled entirely (503) to prevent accidental unauthenticated
    access to control-plane operations.
    """
    admin = getattr(settings, "admin", None)
    secret: SecretStr | None = getattr(admin, "secret", None)

    if secret is None:
        raise HTTPException(
            status_code=503,
            detail="Admin endpoints are disabled (no secret configured)",
        )

    provided = request.headers.get("X-Admin-Secret", "")
    if not provided:
        raise HTTPException(status_code=401, detail="Missing admin secret")

    if not hmac.compare_digest(provided, secret.get_secret_value()):
        raise HTTPException(status_code=401, detail="Invalid admin secret")


# ---------------------------------------------------------------------------
# Value extraction helpers
# ---------------------------------------------------------------------------


def _as_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value) if value is not None else default
    except TypeError, ValueError:
        return default


def _as_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    try:
        return int(value) if value is not None else default
    except TypeError, ValueError:
        return default


def _as_str(value: Any, default: str = "") -> str:
    return str(value) if value is not None else default


def _state_values(state: Any) -> dict[str, Any]:
    """Return the values dict from a checkpointed state snapshot.

    LangGraph StateSnapshots expose ``.values`` as a mapping. Older test
    doubles may pass a plain dict; both shapes are accepted.
    """
    if state is None:
        return {}
    values = getattr(state, "values", state)
    if isinstance(values, dict):
        return values
    return {}


def _derive_status(
    raw_status: str,
    requires_approval: bool,
    approval_granted: bool | None,
) -> str:
    """Return the UI-facing status.

    ``awaiting_approval`` is derived; the underlying state keeps its
    ``running`` status while the graph is paused on the interrupt.
    """
    if requires_approval and approval_granted is None and raw_status == "running":
        return "awaiting_approval"
    return raw_status


def _extract_summary(incident_id: str, values: dict[str, Any]) -> IncidentSummary:
    """Build an IncidentSummary from state values."""
    metadata = values.get("incident_metadata") or {}
    if not isinstance(metadata, dict):
        metadata = {}

    requires_approval = bool(values.get("requires_human_approval", False))
    approval_granted = values.get("approval_granted")
    raw_status = _as_str(values.get("status", "unknown"))

    status = _derive_status(raw_status, requires_approval, approval_granted)

    return IncidentSummary(
        incident_id=incident_id,
        status=status,
        phase=_as_str(values.get("current_phase", "unknown")),
        alert_name=_as_str(metadata.get("alert_name", "")),
        service=_as_str(metadata.get("service", "")),
        namespace=_as_str(metadata.get("namespace", "")),
        severity=_as_str(metadata.get("severity", "")),
        started_at=_as_str(metadata.get("started_at", "")),
        requires_human_approval=requires_approval,
        approval_granted=(bool(approval_granted) if approval_granted is not None else None),
        tokens_used=_as_int(values.get("tokens_used", 0)),
        cost_usd=_as_float(values.get("cost_usd", 0.0)),
        wall_clock_seconds=_as_float(values.get("wall_clock_seconds", 0.0)),
        active_seconds=_as_float(values.get("active_seconds", 0.0)),
        backoff_seconds=_as_float(values.get("backoff_seconds", 0.0)),
        iterations=_as_int(values.get("iteration_count", 0)),
        proposed_actions=list(values.get("proposed_actions") or []),
        executed_actions=list(values.get("executed_actions") or []),
    )


def _baseline_mttr_seconds(values: dict[str, Any]) -> float:
    """Return the dataset-declared baseline MTTR, or 0.0.

    The eval harness sets ``labels['baseline_mttr_seconds']`` per incident
    before triggering. This helper parses it defensively.
    """
    metadata = values.get("incident_metadata") or {}
    if not isinstance(metadata, dict):
        return 0.0
    labels = metadata.get("labels") or {}
    if not isinstance(labels, dict):
        return 0.0

    raw = labels.get("baseline_mttr_seconds")
    value = _as_float(raw, 0.0)
    return value if value > 0 else 0.0


def _count_safety_violations(executed_actions: list[Any]) -> int:
    """Count prohibited tools that executed despite policy.

    Broader than the previous check: any executed action whose tool name
    is in the prohibited set counts, regardless of whether the policy
    layer was bypassed. In a correct system this count is always zero.
    """
    violations = 0
    for action in executed_actions:
        if not isinstance(action, dict):
            continue
        if action.get("tool_name") in _PROHIBITED_TOOLS:
            violations += 1
    return violations


# ---------------------------------------------------------------------------
# Health & readiness
# ---------------------------------------------------------------------------


@router.get("/healthz")
async def healthz(request: Request) -> dict[str, Any]:
    return {
        "status": "ok",
        "version": "0.1.4",
        "paused": bool(getattr(request.app.state, "paused", False)),
    }


@router.get("/readyz")
async def readyz(request: Request) -> JSONResponse:
    """Readiness probe. Verifies Postgres connectivity."""
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
# Admin
# ---------------------------------------------------------------------------


def _is_paused(request: Request) -> bool:
    return bool(getattr(request.app.state, "paused", False))


@router.post("/admin/pause")
async def admin_pause(
    request: Request,
    settings: AppSettings,
) -> AdminStatusResponse:
    """Reject new incidents. Existing work continues."""
    _require_admin_secret(request, settings)
    request.app.state.paused = True
    request.app.state.pause_reason = "manual"
    logger.warning("Agent paused by admin")
    return AdminStatusResponse(paused=True, reason="manual")


@router.post("/admin/resume")
async def admin_resume(
    request: Request,
    settings: AppSettings,
) -> AdminStatusResponse:
    """Accept new incidents again."""
    _require_admin_secret(request, settings)
    request.app.state.paused = False
    request.app.state.pause_reason = None
    logger.warning("Agent resumed by admin")
    return AdminStatusResponse(paused=False, reason=None)


@router.get("/admin/status")
async def admin_status(
    request: Request,
    settings: AppSettings,
) -> AdminStatusResponse:
    """Return the current pause state. Requires the admin secret."""
    _require_admin_secret(request, settings)
    return AdminStatusResponse(
        paused=_is_paused(request),
        reason=getattr(request.app.state, "pause_reason", None),
    )


# ---------------------------------------------------------------------------
# Approval signing (same-origin helper for the UI)
# ---------------------------------------------------------------------------


@router.post("/api/sign-approval")
async def sign_approval(
    approval: ApprovalRequest,
    settings: AppSettings,
) -> dict[str, str]:
    """Return an HMAC-signed body for POST /incidents/{id}/approve.

    The browser cannot compute HMAC-SHA256 without exposing the webhook
    secret, so the UI requests a signature from the same-origin API and
    forwards it as the X-Webhook-Signature header.
    """
    body = json.dumps(
        {"approved": approval.approved, "comment": approval.comment},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")

    secret = settings.alert.webhook_secret
    secret_value: str = secret.get_secret_value() if isinstance(secret, SecretStr) else str(secret)

    signature = hmac.new(
        secret_value.encode("utf-8"),
        body,
        hashlib.sha256,
    ).hexdigest()

    return {
        "signature": f"sha256={signature}",
        "body": body.decode("utf-8"),
    }


# ---------------------------------------------------------------------------
# Webhook endpoints
# ---------------------------------------------------------------------------


def _client_ip(request: Request) -> str:
    """Return the client IP, honoring X-Forwarded-For when present."""
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()
    return request.client.host if request.client else "unknown"


@webhook_router.post(
    "/alerts",
    status_code=status.HTTP_202_ACCEPTED,
)
async def trigger_incident(
    request: Request,
    runner: Runner,
    settings: AppSettings,
) -> dict[str, Any]:
    """Trigger an incident via signed webhook.

    Order of checks:
        1. Rate limit
        2. Pause flag
        3. HMAC signature
        4. Payload validation
        5. Dispatch
    """
    # 1. Rate limit first so abusive clients can't burn signature checks.
    client = _client_ip(request)
    if not await _alerts_limiter.allow(client):
        logger.warning("Rate limit exceeded for %s", client)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded",
        )

    # 2. Pause flag. Refuse new work while paused; existing graph runs
    # continue to completion.
    if _is_paused(request):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Agent is paused",
        )

    # 3. Read body once. It is needed for both signature verification and
    # parsing.
    try:
        payload = await request.body()
    except Exception as exc:
        logger.error("Failed to read /alerts body: %s", exc)
        raise HTTPException(status_code=400, detail="Failed to read request body") from exc

    signature = request.headers.get("X-Webhook-Signature", "")

    if not _verify_signature(payload, signature, settings.alert.webhook_secret):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")

    # 4. Validate payload.
    try:
        alert = AlertPayload.model_validate_json(payload)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Invalid alert payload: {exc}") from exc

    logger.info(
        "Alert received: %s on %s/%s (severity=%s)",
        alert.alert_name,
        alert.namespace,
        alert.service,
        alert.severity,
    )

    # 5. Dispatch. Translate runner-level failures into specific statuses
    # so the caller can distinguish transient from fatal.
    try:
        incident_id = await runner.run_incident(alert.model_dump())
    except TimeoutError as exc:
        logger.error("Incident dispatch timed out for alert %s", alert.alert_name)
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Incident exceeded wall-clock budget",
        ) from exc
    except LLMBudgetExhaustedError as exc:
        logger.error("Incident dispatch aborted: provider budget exhausted")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="LLM provider budget exhausted",
        ) from exc
    except Exception as exc:
        logger.error(
            "Unexpected error in trigger_incident: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(status_code=500, detail=f"Internal error: {exc!s}") from exc

    logger.info("Incident %s created", incident_id)
    return {"incident_id": incident_id, "status": "accepted"}


@webhook_router.post("/incidents/{incident_id}/approve")
async def approve_incident(
    incident_id: str,
    request: Request,
    approval: ApprovalRequest,
    runner: Runner,
    settings: AppSettings,
) -> dict[str, Any]:
    """Resume a paused HITL interrupt with the operator's decision.

    The signature is verified over the raw body, then the payload is
    parsed. This ordering matches the Slack-style verification contract.
    """
    payload = await request.body()
    signature = request.headers.get("X-Webhook-Signature", "")

    if not _verify_signature(payload, signature, settings.alert.webhook_secret):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")

    approved = await runner.approve_incident(incident_id, approval.approved, approval.comment)

    if not approved:
        # Distinguish "already decided" from "not found" for operators.
        state = await runner.get_incident_state(incident_id)
        if state is None:
            raise HTTPException(
                status_code=404,
                detail=f"Incident {incident_id} not found",
            )
        raise HTTPException(
            status_code=409,
            detail="Incident does not require approval or was already decided",
        )

    return {
        "incident_id": incident_id,
        "approved": approval.approved,
        "status": "approved" if approval.approved else "rejected",
    }


# ---------------------------------------------------------------------------
# Incident queries
# ---------------------------------------------------------------------------


@router.get("/incidents")
async def list_incidents(
    runner: Runner,
    status_filter: str | None = Query(None, alias="status", description="Filter by derived status"),
    limit: int = Query(100, ge=1, le=500),
) -> IncidentListResponse:
    """List incidents, optionally filtered by status."""
    try:
        all_states = await runner.list_incidents(limit=limit)

        items: list[IncidentSummary] = []
        for incident_id, state in all_states:
            values = _state_values(state)
            if not values:
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
) -> IncidentReportResponse:
    """Return the full incident report."""
    state = await runner.get_incident_state(incident_id)

    if state is None:
        raise HTTPException(status_code=404, detail=f"Incident {incident_id} not found")

    values = _state_values(state)

    if not values:
        raise HTTPException(
            status_code=500,
            detail=f"Invalid state format for incident {incident_id}",
        )

    metadata = values.get("incident_metadata") or {}
    if not isinstance(metadata, dict):
        metadata = {}

    return IncidentReportResponse(
        incident_id=incident_id,
        status=_as_str(values.get("status", "unknown")),
        phase=_as_str(values.get("current_phase", "unknown")),
        alert_name=_as_str(metadata.get("alert_name", "")),
        service=_as_str(metadata.get("service", "")),
        namespace=_as_str(metadata.get("namespace", "")),
        severity=_as_str(metadata.get("severity", "")),
        started_at=_as_str(metadata.get("started_at", "")),
        hypotheses=list(values.get("hypotheses") or []),
        proposed_actions=list(values.get("proposed_actions") or []),
        executed_actions=list(values.get("executed_actions") or []),
        tokens_used=_as_int(values.get("tokens_used", 0)),
        cost_usd=_as_float(values.get("cost_usd", 0.0)),
        wall_clock_seconds=_as_float(values.get("wall_clock_seconds", 0.0)),
        active_seconds=_as_float(values.get("active_seconds", 0.0)),
        backoff_seconds=_as_float(values.get("backoff_seconds", 0.0)),
        iterations=_as_int(values.get("iteration_count", 0)),
        requires_human_approval=bool(values.get("requires_human_approval", False)),
        approval_granted=values.get("approval_granted"),
    )


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


@router.get("/metrics/summary")
async def get_metrics_summary(runner: Runner) -> MetricsSummary:
    """Aggregate KPIs across all incidents.

    MTTR is computed from ``active_seconds`` (excludes rate-limit
    backoff). ``mttr_reduction_pct`` compares the mean active time
    against the mean dataset-declared baseline.
    """
    try:
        all_states = await runner.list_incidents(limit=1000)

        resolved = 0
        awaiting = 0
        failed = 0
        no_action = 0

        active_times: list[float] = []
        wall_times: list[float] = []
        backoff_times: list[float] = []
        baselines: list[float] = []

        total_cost = 0.0
        total_tokens = 0
        safety_violations = 0
        by_category: dict[str, int] = defaultdict(int)

        for _iid, state in all_states:
            values = _state_values(state)
            if not values:
                continue

            raw_status = _as_str(values.get("status", "unknown"))
            requires_approval = bool(values.get("requires_human_approval", False))
            approval_granted = values.get("approval_granted")
            status = _derive_status(raw_status, requires_approval, approval_granted)

            if status == "awaiting_approval":
                awaiting += 1
            elif status in _TERMINAL_SUCCESS_STATUSES:
                resolved += 1
            elif status in _TERMINAL_FAILURE_STATUSES:
                failed += 1
            elif status in _NO_ACTION_STATUSES:
                no_action += 1

            # Timing (all incidents contribute to cost/tokens, only
            # resolved ones contribute to MTTR).
            if status in _TERMINAL_SUCCESS_STATUSES:
                active = _as_float(values.get("active_seconds", 0.0))
                wall = _as_float(values.get("wall_clock_seconds", 0.0))
                backoff = _as_float(values.get("backoff_seconds", 0.0))
                if active > 0:
                    active_times.append(active)
                if wall > 0:
                    wall_times.append(wall)
                if backoff >= 0:
                    backoff_times.append(backoff)

                baseline = _baseline_mttr_seconds(values)
                if baseline > 0:
                    baselines.append(baseline)

            total_cost += _as_float(values.get("cost_usd", 0.0))
            total_tokens += _as_int(values.get("tokens_used", 0))

            # Category from labels, with a top-level fallback for older
            # incidents recorded before category propagation was added.
            metadata = values.get("incident_metadata") or {}
            category = "unknown"
            if isinstance(metadata, dict):
                labels = metadata.get("labels") or {}
                if isinstance(labels, dict):
                    category = _as_str(labels.get("category")) or "unknown"
                if category == "unknown":
                    category = _as_str(metadata.get("category")) or "unknown"
            by_category[category] += 1

            executed = values.get("executed_actions") or []
            if isinstance(executed, list):
                safety_violations += _count_safety_violations(executed)

        avg_active = sum(active_times) / len(active_times) if active_times else 0.0
        avg_wall = sum(wall_times) / len(wall_times) if wall_times else 0.0
        avg_backoff = sum(backoff_times) / len(backoff_times) if backoff_times else 0.0
        avg_baseline = sum(baselines) / len(baselines) if baselines else 0.0
        reduction = (
            ((avg_baseline - avg_active) / avg_baseline) * 100.0 if avg_baseline > 0 else 0.0
        )

        return MetricsSummary(
            total_incidents=len(all_states),
            resolved_count=resolved,
            awaiting_approval_count=awaiting,
            failed_count=failed,
            no_action_count=no_action,
            avg_mttr_seconds=round(avg_active, 2),
            avg_wall_clock_seconds=round(avg_wall, 2),
            avg_backoff_seconds=round(avg_backoff, 2),
            baseline_mttr_seconds=round(avg_baseline, 2),
            mttr_reduction_pct=round(reduction, 2),
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


def _bucket_epoch(ts: float, bucket_seconds: int) -> int:
    """Return the epoch start of the bucket containing ``ts``."""
    if bucket_seconds <= 0:
        raise ValueError("bucket_seconds must be positive")
    return (int(ts) // bucket_seconds) * bucket_seconds


@router.get("/metrics/timeseries")
async def get_metrics_timeseries(
    runner: Runner,
    time_range: str = Query(
        "24h",
        pattern="^(1h|24h|7d|30d)$",
        alias="range",
        description="Time range for bucketing",
    ),
) -> MetricsTimeseriesResponse:
    """Return epoch-aligned time-bucketed metrics.

    Buckets are aligned to the epoch so they are always chronologically
    ordered. The previous implementation produced non-monotonic labels
    (04:30, 19:30, 15:30) because it manipulated wall-clock fields
    instead of epoch offsets.
    """
    try:
        all_states = await runner.list_incidents(limit=1000)

        bucket_minutes = _BUCKET_MINUTES_BY_RANGE[time_range]
        bucket_seconds = bucket_minutes * 60

        buckets: dict[int, dict[str, Any]] = {}

        for _iid, state in all_states:
            values = _state_values(state)
            if not values:
                continue

            metadata = values.get("incident_metadata") or {}
            if not isinstance(metadata, dict):
                continue

            started_at_raw = metadata.get("started_at", "")
            if not started_at_raw:
                continue

            try:
                parsed = datetime.fromisoformat(str(started_at_raw).replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=UTC)
            except ValueError, TypeError:
                continue

            epoch = parsed.timestamp()
            bucket_start = _bucket_epoch(epoch, bucket_seconds)

            slot = buckets.setdefault(
                bucket_start,
                {
                    "incidents": 0,
                    "resolved": 0,
                    "no_action": 0,
                    "failed": 0,
                    "active_times": [],
                    "total_cost": 0.0,
                    "total_tokens": 0,
                },
            )

            slot["incidents"] += 1

            raw_status = _as_str(values.get("status", "unknown"))
            requires_approval = bool(values.get("requires_human_approval", False))
            approval_granted = values.get("approval_granted")
            status = _derive_status(raw_status, requires_approval, approval_granted)

            if status == "resolved":
                slot["resolved"] += 1
                active = _as_float(values.get("active_seconds", 0.0))
                if active > 0:
                    slot["active_times"].append(active)
            elif status == "no_action":
                slot["no_action"] += 1
            elif status == "failed":
                slot["failed"] += 1

            slot["total_cost"] += _as_float(values.get("cost_usd", 0.0))
            slot["total_tokens"] += _as_int(values.get("tokens_used", 0))

        result_buckets: list[MetricBucket] = []

        for bucket_start in sorted(buckets.keys()):
            data = buckets[bucket_start]
            active_list = data["active_times"]
            avg_active = sum(active_list) / len(active_list) if active_list else 0.0

            result_buckets.append(
                MetricBucket(
                    timestamp=datetime.fromtimestamp(bucket_start, tz=UTC).isoformat(),
                    incidents=data["incidents"],
                    resolved=data["resolved"],
                    no_action=data["no_action"],
                    failed=data["failed"],
                    avg_mttr_seconds=round(avg_active, 2),
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
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get timeseries: {exc!s}",
        ) from exc


@router.get("/metrics/top-expensive")
async def get_top_expensive(
    runner: Runner,
    limit: int = Query(5, ge=1, le=100),
) -> list[ExpensiveIncident]:
    """Return the N most expensive incidents."""
    try:
        all_states = await runner.list_incidents(limit=1000)

        incidents: list[ExpensiveIncident] = []

        for incident_id, state in all_states:
            values = _state_values(state)
            if not values:
                continue

            metadata = values.get("incident_metadata") or {}
            if not isinstance(metadata, dict):
                metadata = {}

            incidents.append(
                ExpensiveIncident(
                    incident_id=incident_id,
                    alert_name=_as_str(metadata.get("alert_name", "")),
                    service=_as_str(metadata.get("service", "")),
                    cost_usd=_as_float(values.get("cost_usd", 0.0)),
                    wall_clock_seconds=_as_float(values.get("wall_clock_seconds", 0.0)),
                    status=_as_str(values.get("status", "unknown")),
                )
            )

        incidents.sort(key=lambda x: x.cost_usd, reverse=True)
        return incidents[:limit]

    except Exception as exc:
        logger.error(
            "Error in get_top_expensive: %s\n%s",
            exc,
            traceback.format_exc(),
        )
        raise HTTPException(
            status_code=500,
            detail=f"Failed to get top expensive: {exc!s}",
        ) from exc


__all__ = [
    "router",
    "webhook_router",
    "AlertPayload",
    "ApprovalRequest",
    "IncidentSummary",
    "IncidentListResponse",
    "IncidentReportResponse",
    "MetricsSummary",
    "MetricBucket",
    "MetricsTimeseriesResponse",
    "ExpensiveIncident",
    "AdminStatusResponse",
]
