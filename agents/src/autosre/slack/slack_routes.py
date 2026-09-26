"""FastAPI endpoints for the optional HTTP Slack transport."""

from __future__ import annotations

import json
import logging
from typing import Any, cast
from urllib.parse import parse_qs

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from autosre.slack.handler import SlackHandler

logger = logging.getLogger(__name__)

slack_router = APIRouter(
    prefix="/slack",
    tags=["slack"],
)


def _get_handler(request: Request) -> SlackHandler:
    handler = getattr(
        request.app.state,
        "slack_handler",
        None,
    )

    if handler is None:
        raise HTTPException(
            status_code=503,
            detail="Slack handler not configured",
        )

    return cast(SlackHandler, handler)


@slack_router.post("/events")
async def handle_events(
    request: Request,
) -> JSONResponse:
    """Handle HTTP Slack Events API requests."""
    body = await request.body()
    handler = _get_handler(request)

    if not handler.verify_request(
        body,
        request.headers,
    ):
        logger.warning("Rejected Slack Events API request with invalid signature")
        raise HTTPException(
            status_code=401,
            detail="Invalid Slack signature",
        )

    try:
        payload: Any = json.loads(body)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid JSON",
        ) from exc

    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=400,
            detail="Slack payload must be a JSON object",
        )

    if payload.get("type") == "url_verification":
        challenge = payload.get("challenge")

        if not isinstance(challenge, str) or not challenge:
            raise HTTPException(
                status_code=400,
                detail="Missing Slack challenge",
            )

        return JSONResponse(content={"challenge": challenge})

    return JSONResponse(content={"ok": True})


@slack_router.post("/interactivity")
async def handle_interactivity(
    request: Request,
) -> JSONResponse:
    """Handle HTTP Block Kit interactions with immediate acknowledgement."""
    body = await request.body()
    handler = _get_handler(request)

    if not handler.verify_request(
        body,
        request.headers,
    ):
        logger.warning("Rejected Slack interactivity request with invalid signature")
        raise HTTPException(
            status_code=401,
            detail="Invalid Slack signature",
        )

    try:
        form = parse_qs(
            body.decode("utf-8"),
            keep_blank_values=True,
            strict_parsing=False,
        )
    except UnicodeDecodeError as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid request encoding",
        ) from exc

    payload_values = form.get("payload")

    if not payload_values or not payload_values[0]:
        raise HTTPException(
            status_code=400,
            detail="Missing Slack payload",
        )

    try:
        payload: Any = json.loads(payload_values[0])
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid Slack payload JSON",
        ) from exc

    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=400,
            detail="Slack payload must be a JSON object",
        )

    if payload.get("type") == "block_actions":
        handler.schedule_interactivity(payload)

    return JSONResponse(content={})
