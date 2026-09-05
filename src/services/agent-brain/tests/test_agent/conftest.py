"""Shared fixtures for agent tests."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _mock_infra_ws_manager(mocker):
    """Prevent any WebSocket broadcasts during tests."""
    mocker.patch("infra.ws.manager.publish_state")
    mocker.patch("infra.ws.manager.publish_event")


@pytest.fixture
def base_state():
    """Minimal valid state dict for workflow nodes."""
    return {
        "alert": {
            "id": "alert-1",
            "name": "Test Alert",
            "resource_id": "/subs/rg/svc",
            "severity": "error",
            "description": "Service is down",
        },
        "alert_id": "alert-1",
        "thread_id": "test-thread",
        "service_name": "test-svc",
        "resource_id": "/subs/rg/svc",
        "severity": "error",
        "status": "new",
        "retry_count": 0,
        "max_retries": 3,
    }
