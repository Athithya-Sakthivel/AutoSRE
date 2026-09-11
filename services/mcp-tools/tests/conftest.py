"""Shared test fixtures – force development mode and provide test client."""

import os

import pytest

os.environ["MCP_TOOLS_MODE"] = "development"
os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = ""


@pytest.fixture(scope="session")
def test_client():
    """Return a Starlette TestClient for the FastMCP server."""
    from _mcp.main import mcp
    from starlette.testclient import TestClient

    # FastMCP v3 exposes the ASGI app via http_app()
    return TestClient(mcp.http_app())
