"""Shared API-key authentication for the AutoSRE dashboard.

## Design

Single shared bearer secret (not username/password). Suitable for a
single-tenant, network-isolated SRE console. This is defense-in-depth
behind Kubernetes NetworkPolicy, not a multi-user identity system.

## Enablement

    AUTOSRE_API_KEY unset or empty  -> authentication DISABLED (local dev)
    AUTOSRE_API_KEY set             -> protected routes require X-API-Key

## Route scope

Protected (UI-facing read + signature minting):
    GET  /incidents
    GET  /incidents/{id}/report
    GET  /metrics/*
    POST /api/sign-approval

Intentionally exempt (already authenticated by a stronger scheme):
    /alerts/*                  -> HMAC webhook signature
    /admin/*                   -> X-Admin-Secret
    /incidents/{id}/approve    -> HMAC webhook signature (minted by the
                                 protected /api/sign-approval endpoint)

Always public:
    /healthz, /readyz          -> bootstrap probes
    /docs, /redoc, /openapi.json
    Static SPA assets
    OPTIONS preflight          -> must reach CORS middleware unsigned

## Implementation notes

Pure ASGI middleware (not BaseHTTPMiddleware) so streaming responses are
untouched and exceptions are returned as real HTTP responses. Raising
HTTPException from middleware would surface as a 500, not a 401.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import re

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

logger = logging.getLogger(__name__)

_PUBLIC_PATHS: frozenset[str] = frozenset(
    {
        "/healthz",
        "/readyz",
        "/docs",
        "/redoc",
        "/openapi.json",
    }
)

_exempt_prefixes: tuple[str, ...] = ("/alerts", "/admin")


def _is_protected(path: str, method: str) -> bool:
    """Return True when a request requires the shared API key."""
    # Preflight carries no credentials by design; let CORS answer it.
    if method == "OPTIONS":
        return False

    if path in _PUBLIC_PATHS:
        return False

    # Machine-to-machine routes have their own authentication.
    if path.startswith(_exempt_prefixes):
        return False

    # HEAD must not bypass GET protection.
    effective_method = "GET" if method == "HEAD" else method

    if path == "/api/sign-approval":
        return effective_method == "POST"

    if path == "/incidents":
        return effective_method == "GET"

    if path.startswith("/incidents/") and path.endswith("/report"):
        return effective_method == "GET"

    if path.startswith("/metrics/"):
        return effective_method == "GET"

    # Includes POST /incidents/{id}/approve: HMAC-verified by the route.
    return False


class ApiKeyMiddleware:
    """Enforce X-API-Key on protected routes when a key is configured."""

    def __init__(self, app: ASGIApp, *, api_key: str | None = None) -> None:
        self.app = app
        self._api_key = (
            api_key if api_key is not None else os.getenv("AUTOSRE_API_KEY", "")
        ).strip()

        logger.info(
            "API key authentication %s",
            "enabled" if self._api_key else "disabled",
        )

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not self._api_key:
            await self.app(scope, receive, send)
            return

        path: str = scope.get("path", "")
        method: str = str(scope.get("method", "GET")).upper()

        if not _is_protected(path, method):
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        provided = headers.get("x-api-key", "")

        # Constant-time comparison; encode to bytes so non-ASCII input
        # cannot raise TypeError inside compare_digest.
        if provided and hmac.compare_digest(
            provided.encode("utf-8"), self._api_key.encode("utf-8")
        ):
            await self.app(scope, receive, send)
            return

        response = JSONResponse(
            {"detail": "Invalid or missing API key"},
            status_code=401,
            headers={"WWW-Authenticate": "ApiKey"},
        )
        await response(scope, receive, send)


def render_index_with_key(index_html: str, *, api_key: str | None = None) -> str:
    """Inject the client-side API key into the built SPA HTML.

    Called by the FastAPI SPA fallback handler when serving ui/dist.
    No-op when no key is configured (local development).

    The key is JSON-encoded and HTML-sensitive characters are escaped so a
    secret containing quotes or "</script>" cannot break out of the script
    element. The variable is read by src/lib/api.ts at request time.

    NOTE: This is a shared bearer secret, visible to anyone who can load the
    console. NetworkPolicy remains the primary access boundary.
    """
    key = (api_key if api_key is not None else os.getenv("AUTOSRE_API_KEY", "")).strip()

    if not key:
        return index_html

    safe_literal = (
        json.dumps(key).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    )
    script = f"<script>window.__AUTOSRE_API_KEY__={safe_literal};</script>"

    if "</head>" in index_html:
        return index_html.replace("</head>", f"{script}</head>", 1)

    # Fallback for templates without a literal closing head tag.
    # Insert immediately after <head ...> so the doctype stays first.
    return re.sub(
        r"(<head\b[^>]*>)",
        lambda match: f"{match.group(1)}{script}",
        index_html,
        count=1,
        flags=re.IGNORECASE,
    )


__all__ = ["ApiKeyMiddleware", "render_index_with_key"]
