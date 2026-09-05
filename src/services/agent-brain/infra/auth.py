"""Simple API‑key authentication – identical mechanism to mcp‑tools.

The configured MCP_API_KEY acts as the shared bearer token for all
protected endpoints.  If REQUIRE_AUTH=false, all requests are allowed.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Coroutine
from typing import Any

from fastapi import HTTPException, Request

from infra.config import load_settings

logger = logging.getLogger(__name__)

PUBLIC_PATHS = {"/health", "/ready", "/ws"}


def _valid_api_key() -> str | None:
    """Return the API key that must be presented, or None if auth is off."""
    settings = load_settings()
    if not settings.require_auth:
        return None
    return settings.mcp_api_key.strip() or None


async def validate_bearer(request: Request) -> bool:
    """Return True if the request carries the correct Bearer token."""
    expected = _valid_api_key()
    if expected is None:
        return True  # auth disabled globally

    if any(request.url.path.startswith(p) for p in PUBLIC_PATHS):
        return True

    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return False

    token = auth_header[len("Bearer ") :].strip()
    return bool(token == expected)


def require_auth(
    func: Callable[..., Coroutine[Any, Any, Any]],
) -> Callable[..., Coroutine[Any, Any, Any]]:
    """Decorator that returns 401 if the request lacks the correct token."""

    async def wrapper(request: Request, *args: Any, **kwargs: Any) -> Any:
        if not await validate_bearer(request):
            raise HTTPException(status_code=401, detail="Invalid or missing authentication token")
        return await func(request, *args, **kwargs)

    return wrapper


__all__ = ["require_auth", "validate_bearer"]
