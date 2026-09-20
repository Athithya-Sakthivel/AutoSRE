"""FastAPI routes for AutoSRE agent."""

from __future__ import annotations

import hashlib
import hmac
import logging
import uuid
from typing import Annotated, Any, cast

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field

from autosre.api.runner import StubIncidentRunner
from autosre.config import Settings

logger = logging.getLogger(__name__)

router = APIRouter()
webhook_router = APIRouter()


# --- Request/Response Models ---


class AlertPayload(BaseModel):
    """Alert payload from OpenObserve webhook."""

    alert_name: str = Field(..., min_length=1, max_length=200)
    service: str = Field(..., min_length=1, max_length=200)
    namespace: str = Field(..., min_length=1, max_length=200)
    severity: str = Field(..., pattern=r"^(sev[1-4]|critical|high|medium|low)$")
    started_at: str = Field(..., max_length=100)
    fingerprint: str = Field(..., max_length=512)
    description: str = Field("", max_length=10_000)
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)


class AlertAcceptedResponse(BaseModel):
    """Response when alert is accepted."""

    incident_id: str
    status: str = "accepted"
    message: str = "Investigation started"


class ApprovalPayload(BaseModel):
    """HITL approval/rejection payload."""

    approved: bool
    comment: str = Field(..., max_length=2_000)


class ApprovalResponse(BaseModel):
    """Response when approval is recorded."""

    incident_id: str
    approved: bool
    status: str


# --- Dependencies ---


def get_settings(request: Request) -> Settings:
    """Get settings from app state."""
    return cast(Settings, request.app.state.settings)


def get_runner(request: Request) -> StubIncidentRunner:
    """Get incident runner from app state."""
    return cast(StubIncidentRunner, request.app.state.runner)


def get_pg_pool(request: Request) -> Any:
    """Get Postgres connection pool from app state."""
    return request.app.state.pg_pool


# --- Webhook Signature Verification ---


def verify_webhook_signature(
    payload: bytes,
    signature_header: str | None,
    secret: str,
) -> bool:
    """Verify HMAC-SHA256 webhook signature."""
    if not signature_header:
        return False

    if not signature_header.startswith("sha256="):
        return False

    expected_signature = signature_header[7:]  # Strip "sha256=" prefix

    if len(expected_signature) != hashlib.sha256().digest_size * 2:
        return False

    computed_signature = hmac.new(
        secret.encode("utf-8"),
        payload,
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(computed_signature, expected_signature)


# --- Routes ---


@webhook_router.post(
    "/alerts",
    response_model=AlertAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def receive_alert(
    request: Request,
    alert: AlertPayload,
    settings: Annotated[Settings, Depends(get_settings)],
    runner: Annotated[StubIncidentRunner, Depends(get_runner)],
    x_webhook_signature: Annotated[str | None, Header(alias="X-Webhook-Signature")] = None,
) -> AlertAcceptedResponse:
    """Receive alert webhook and start investigation."""
    # Verify signature AFTER body validation
    webhook_secret = settings.alert.webhook_secret.get_secret_value()
    payload_bytes = await request.body()

    if not verify_webhook_signature(payload_bytes, x_webhook_signature, webhook_secret):
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
    runner: Annotated[StubIncidentRunner, Depends(get_runner)],
    x_webhook_signature: Annotated[str | None, Header(alias="X-Webhook-Signature")] = None,
) -> ApprovalResponse:
    """Receive HITL approval/rejection webhook."""
    # Verify signature
    webhook_secret = settings.alert.webhook_secret.get_secret_value()
    payload_bytes = await request.body()

    if not verify_webhook_signature(payload_bytes, x_webhook_signature, webhook_secret):
        logger.warning(
            "Invalid webhook signature for approval",
            extra={"incident_id": incident_id},
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid webhook signature",
        )

    logger.info(
        "Received approval for incident %s: %s",
        incident_id,
        "approved" if approval.approved else "rejected",
        extra={
            "incident_id": incident_id,
            "approved": approval.approved,
            "comment": approval.comment,
        },
    )

    found = await runner.approve_incident(
        incident_id,
        approval.approved,
        approval.comment,
    )

    if not found:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Incident {incident_id} not found or already approved",
        )

    return ApprovalResponse(
        incident_id=incident_id,
        approved=approval.approved,
        status="approved" if approval.approved else "rejected",
    )


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness probe."""
    return {"status": "ok", "version": "0.1.0"}


@router.get("/readyz")
async def readyz(
    pg_pool: Annotated[Any, Depends(get_pg_pool)],
) -> dict[str, Any]:
    """Readiness probe."""
    checks: dict[str, str] = {}

    try:
        async with pg_pool.connection() as conn, conn.cursor() as cur:
            await cur.execute("SELECT 1")
        checks["postgres"] = "ok"
    except Exception as e:
        logger.error("Postgres readiness check failed: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Postgres not ready",
        ) from e

    return {"status": "ready", "checks": checks}
