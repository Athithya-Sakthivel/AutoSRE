"""Authentication helpers for the FastMCP server."""

from __future__ import annotations

from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

from .config import Settings, settings


def get_api_key() -> str | None:
    """Return the configured API key, or None if not set."""
    value = settings.mcp_api_key.strip()
    return value or None


def build_auth_provider(config: Settings = settings) -> StaticTokenVerifier | None:
    """
    Build the FastMCP server auth provider.

    FastMCP server auth expects an auth provider object, not a raw bearer token.
    A StaticTokenVerifier is the correct fit for a fixed API key / service token.
    """
    api_key = config.mcp_api_key.strip()
    if not api_key:
        return None

    tokens = {
        api_key: {
            "sub": config.service_name,
            "client_id": config.service_name,
            "auth_type": "api_key",
        }
    }

    return StaticTokenVerifier(tokens=tokens)


__all__ = ["build_auth_provider", "get_api_key"]
