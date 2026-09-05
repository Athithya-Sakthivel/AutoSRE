"""Shared fixtures for target-system tests."""

import pytest

# Import the FastAPI app instance (not the factory)
from app.main import app
from fastapi.testclient import TestClient


@pytest.fixture
def client():
    """Return a TestClient that wraps the FastAPI app."""
    return TestClient(app)


@pytest.fixture(autouse=True)
def reset_chaos():
    """Reset chaos state before every test to ensure isolation."""
    from app.chaos import chaos_state

    chaos_state.reset()
    yield
    chaos_state.reset()
