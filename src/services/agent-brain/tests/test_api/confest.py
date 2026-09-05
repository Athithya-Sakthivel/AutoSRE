"""Shared fixtures for API tests – mocks the entire agent runtime."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from infra.config import Settings


@pytest.fixture
def mock_settings():
    """Return a Settings object with auth disabled and test values."""
    return Settings(
        service_name="agent-brain-test",
        environment="development",
        require_auth=False,
        mcp_api_key="test-key",
        cosmos_endpoint="https://fake.cosmos.azure.com",
        cosmos_key="fake-key",
        cosmos_database="testdb",
        cosmos_container="testcontainer",
        mcp_tools_url="http://localhost:8000/mcp",
    )


@pytest.fixture
def mock_graph():
    """Return a mock LangGraph graph that can be invoked."""
    graph = MagicMock()
    graph.ainvoke = AsyncMock(return_value={"status": "resolved"})
    graph.aget_state = AsyncMock(return_value={"status": "triaged"})
    return graph


@pytest.fixture
def client(mock_settings, mock_graph):
    """Create a TestClient with mocked graph and lifespan components."""
    with (
        patch("main.load_settings", return_value=mock_settings),
        patch("main._build_checkpointer", return_value=MagicMock()),
        patch("main.build_graph", return_value=mock_graph),
        patch("main.init_llm_client", AsyncMock()),
        patch("main.get_tools_client", return_value=MagicMock(connect=AsyncMock())),
        patch("main.close_llm_client", AsyncMock()),
        patch("main.close_tools_client", AsyncMock()),
        patch("main.setup_telemetry"),
    ):
        from main import app

        with TestClient(app) as client:
            yield client
