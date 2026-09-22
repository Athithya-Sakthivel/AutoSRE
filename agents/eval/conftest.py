"""Evaluation harness configuration and fixtures.

These tests require a running AutoSRE server and full infrastructure.
They are automatically skipped when the server is not available.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
from pathlib import Path
from typing import Any

import httpx
import pytest

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

EVAL_INCIDENT_COUNT = int(os.getenv("EVAL_INCIDENT_COUNT", "3"))
AGENT_BASE_URL = os.getenv("AGENT_BASE_URL", "http://localhost:8000")
AGENT_WEBHOOK_SECRET = os.getenv("ALERT_WEBHOOK_SECRET", "test-secret")

# Limit to prevent API throttling on free tier
MAX_INCIDENTS = min(EVAL_INCIDENT_COUNT, 30)

# ---------------------------------------------------------------------------
# Judge Model (DeepEval)
# ---------------------------------------------------------------------------

_llm_api_key = os.getenv("LLM_API_KEY")
if _llm_api_key:
    os.environ.setdefault("OPENAI_API_KEY", _llm_api_key)
    os.environ.setdefault("GROQ_API_KEY", _llm_api_key)

GROQ_BASE_URL = "https://api.groq.com/openai/v1"
EVAL_JUDGE_MODEL = "openai/gpt-oss-20b"


def build_judge() -> Any:
    """Build DeepEval judge model. Returns None if no API key."""
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        return None

    try:
        from deepeval.models import OpenAIModel

        return OpenAIModel(
            model=EVAL_JUDGE_MODEL,
            api_key=api_key,
            base_url=GROQ_BASE_URL,
            temperature=0.0,
            cost_per_input_token=0.075 / 1_000_000,
            cost_per_output_token=0.30 / 1_000_000,
        )
    except Exception:
        return None


JUDGE = build_judge()

# ---------------------------------------------------------------------------
# Dataset Loading
# ---------------------------------------------------------------------------

DATASET_PATH = Path(__file__).parent / "dataset" / "AutoSRE-Dataset-v1.json"


def load_dataset() -> list[dict[str, Any]]:
    """Load incident dataset from JSON file."""
    if not DATASET_PATH.exists():
        return []

    with DATASET_PATH.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)

    incidents = raw.get("incidents", [])
    return incidents[:MAX_INCIDENTS]


def incident_ids() -> list[str]:
    """Return list of incident IDs to test."""
    dataset = load_dataset()
    return [inc["id"] for inc in dataset]


def incident_by_id(incident_id: str) -> dict[str, Any]:
    """Get incident by ID."""
    dataset = load_dataset()
    for inc in dataset:
        if inc["id"] == incident_id:
            return inc
    raise KeyError(f"Incident {incident_id} not found")


# ---------------------------------------------------------------------------
# Server Availability Check
# ---------------------------------------------------------------------------


def check_server_available() -> bool:
    """Check if the AutoSRE server is running and accessible."""
    try:
        response = httpx.get(f"{AGENT_BASE_URL}/healthz", timeout=2.0)
        return response.status_code == 200
    except Exception:
        return False


SERVER_AVAILABLE = check_server_available()


# ---------------------------------------------------------------------------
# Agent Client
# ---------------------------------------------------------------------------


class AgentClient:
    """HTTP client for interacting with AutoSRE agent."""

    def __init__(
        self,
        base_url: str,
        webhook_secret: str,
        timeout: float = 120.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.webhook_secret = webhook_secret
        self.timeout = timeout

    def _sign_payload(self, payload: bytes) -> str:
        """Generate HMAC-SHA256 signature for webhook payload."""
        return hmac.new(
            self.webhook_secret.encode(),
            payload,
            hashlib.sha256,
        ).hexdigest()

    async def trigger_incident(self, incident: dict[str, Any]) -> str:
        """Trigger an incident via webhook. Returns incident_id."""
        payload = json.dumps(incident).encode()
        signature = self._sign_payload(payload)

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(
                f"{self.base_url}/alerts",
                content=payload,
                headers={
                    "Content-Type": "application/json",
                    "X-Webhook-Signature": f"sha256={signature}",
                },
            )
            response.raise_for_status()
            data = response.json()
            return data["incident_id"]

    async def get_incident_status(self, incident_id: str) -> dict[str, Any]:
        """Get incident status and results."""
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.get(
                f"{self.base_url}/incidents/{incident_id}/report",
            )
            response.raise_for_status()
            return response.json()

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "",
    ) -> dict[str, Any]:
        """Approve or reject an incident."""
        payload = json.dumps({"approved": approved, "comment": comment}).encode()
        signature = self._sign_payload(payload)

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(
                f"{self.base_url}/incidents/{incident_id}/approve",
                content=payload,
                headers={
                    "Content-Type": "application/json",
                    "X-Webhook-Signature": f"sha256={signature}",
                },
            )
            response.raise_for_status()
            return response.json()

    async def wait_for_completion(
        self,
        incident_id: str,
        poll_interval: float = 2.0,
    ) -> dict[str, Any]:
        """Poll until incident completes or times out."""
        deadline = asyncio.get_event_loop().time() + self.timeout

        while asyncio.get_event_loop().time() < deadline:
            status = await self.get_incident_status(incident_id)
            phase = status.get("phase", "unknown")

            if phase in ("complete", "failed", "awaiting_approval"):
                return status

            await asyncio.sleep(poll_interval)

        raise TimeoutError(f"Incident {incident_id} did not complete within {self.timeout}s")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def dataset() -> list[dict[str, Any]]:
    """Load incident dataset."""
    return load_dataset()


@pytest.fixture
def agent_client() -> AgentClient:
    """Create agent client."""
    if not SERVER_AVAILABLE:
        pytest.skip(f"AutoSRE server not available at {AGENT_BASE_URL}")
    return AgentClient(
        base_url=AGENT_BASE_URL,
        webhook_secret=AGENT_WEBHOOK_SECRET,
    )


@pytest.fixture
def judge():
    """Return DeepEval judge model."""
    return JUDGE


# ---------------------------------------------------------------------------
# Auto-skip all tests in this directory if server not available
# ---------------------------------------------------------------------------


def pytest_collection_modifyitems(config: Any, items: list[Any]) -> None:
    """Skip all eval tests if server is not available."""
    if not SERVER_AVAILABLE:
        skip_marker = pytest.mark.skip(
            reason=f"AutoSRE server not available at {AGENT_BASE_URL}. "
            f"Run 'bash test_e2e_locally.sh' to start the server."
        )
        for item in items:
            # Only skip tests in the eval/ directory
            if "eval" in str(item.fspath):
                item.add_marker(skip_marker)
