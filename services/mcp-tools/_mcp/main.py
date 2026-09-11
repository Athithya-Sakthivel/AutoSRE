"""FastMCP server entrypoint – production-grade, dev/prod switch, fail-fast."""

from __future__ import annotations

import logging
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse

from .auth import build_auth_provider
from .config import ConfigError, settings
from .runtime import Runtime, clear_runtime, set_runtime
from .telemetry import init_telemetry

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Tool imports – three-way switch
# ---------------------------------------------------------------------------
if settings.mode == "development":
    from .tools.tools_mock import (
        create_pr,
        get_code_snippet,
        git_blame,
        query_logs,
        query_traces,
        restart_aca_revision,
    )
elif settings.battle_test and settings.mode == "production":
    from .tools.get_code_snippet import get_code_snippet
    from .tools.git_blame import git_blame
    from .tools.query_logs import query_logs
    from .tools.query_traces import query_traces
    from .tools.tools_mock import create_pr, restart_aca_revision
else:
    from .tools.create_pr import create_pr
    from .tools.get_code_snippet import get_code_snippet
    from .tools.git_blame import git_blame
    from .tools.query_logs import query_logs
    from .tools.query_traces import query_traces
    from .tools.restart_aca_revision import restart_aca_revision


@asynccontextmanager
async def lifespan(_mcp: FastMCP) -> AsyncIterator[None]:
    init_telemetry(settings)

    if settings.mode == "production":
        try:
            from azure.identity import DefaultAzureCredential
        except ImportError as exc:
            raise ConfigError("azure-identity is required for production mode") from exc

        credential = DefaultAzureCredential()
        timeout = httpx.Timeout(settings.request_timeout_seconds)
        http_client = httpx.AsyncClient(timeout=timeout)

        git_root = Path("/tmp") if settings.battle_test else settings.require_git()

        runtime = Runtime(
            settings=settings,
            http=http_client,
            credential=credential,
            git_repo_root=git_root,
        )
        set_runtime(runtime)
    else:
        runtime = None

    try:
        yield
    finally:
        if runtime:
            clear_runtime()
            await runtime.http.aclose()


auth_provider = build_auth_provider()

mcp = FastMCP(
    name=settings.service_name,
    instructions=(
        "Use these tools to investigate target-system incidents, inspect source "
        "code, create pull requests for fixes, and restart Azure Container Apps revisions."
    ),
    lifespan=lifespan,
    auth=auth_provider,
)

mcp.tool(query_traces)
mcp.tool(query_logs)
mcp.tool(git_blame)
mcp.tool(get_code_snippet)
mcp.tool(create_pr)
mcp.tool(restart_aca_revision)


@mcp.custom_route("/health", methods=["GET"])
async def health(_request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "status": "ok",
            "service": settings.service_name,
            "version": settings.service_version,
            "mode": settings.mode,
            "telemetry": {
                "azure_monitor": settings.mode == "production",
                "sampling_mode": settings.sampling_mode,
            },
        }
    )


@mcp.custom_route("/ready", methods=["GET"])
async def ready(_request: Request) -> PlainTextResponse:
    return PlainTextResponse("ready")


def main() -> None:
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    mcp.run(transport="http", host=host, port=port)


if __name__ == "__main__":
    main()
