"""Evaluation harness configuration, helpers, and fixtures.

Incident selection:
    EVAL_INCIDENT_IDS=INC-001,INC-003,INC-014   Run specific incidents
    (unset)                                     Run all 15 incidents

Result persistence:
    Each completed incident saves to eval/results/<incident_id>/result.json
    Subsequent runs skip incidents with existing results (resume mode).
    Set EVAL_FORCE_RERUN=1 to re-run all selected incidents.

Rate limits:
    EVAL_DELAY_SECONDS=5.0     Seconds between incidents (default 5.0)

Server:
    AGENT_BASE_URL=http://localhost:8000
    ALERT_WEBHOOK_SECRET=test-secret
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import math
import os
import time
from pathlib import Path
from typing import Any

import httpx
import pytest

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_EVAL_DIR = Path(__file__).parent
DATASET_PATH = _EVAL_DIR / "dataset" / "AutoSRE-Dataset-v2.json"
RESULTS_DIR = _EVAL_DIR / "results"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AGENT_BASE_URL = os.getenv("AGENT_BASE_URL", "http://localhost:8000")
AGENT_WEBHOOK_SECRET = os.getenv("ALERT_WEBHOOK_SECRET", "test-secret")

DELAY_BETWEEN_INCIDENTS = max(0.0, float(os.getenv("EVAL_DELAY_SECONDS", "5.0")))

FORCE_RERUN = os.getenv("EVAL_FORCE_RERUN", "0") == "1"

# Existing judge provider/model
GROQ_BASE_URL = "https://api.groq.com/openai/v1"
EVAL_JUDGE_MODEL = "openai/gpt-oss-20b"

# ---------------------------------------------------------------------------
# Dataset Loading
# ---------------------------------------------------------------------------


def _load_full_dataset() -> list[dict[str, Any]]:
    """Load and validate the full incident dataset."""
    if not DATASET_PATH.is_file():
        raise FileNotFoundError(f"Dataset not found at {DATASET_PATH}")

    with DATASET_PATH.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)

    if not isinstance(raw, dict):
        raise ValueError(f"Dataset root must be a JSON object, got {type(raw).__name__}")

    incidents = raw.get("incidents")
    if not isinstance(incidents, list):
        raise ValueError("Dataset must contain an 'incidents' list")

    validated: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    for index, incident in enumerate(incidents):
        if not isinstance(incident, dict):
            raise ValueError(f"Dataset incident at index {index} must be an object")

        incident_id = incident.get("id")
        if not isinstance(incident_id, str) or not incident_id.strip():
            raise ValueError(f"Dataset incident at index {index} has an invalid 'id'")

        if incident_id in seen_ids:
            raise ValueError(f"Duplicate incident ID in dataset: {incident_id}")

        seen_ids.add(incident_id)
        validated.append(incident)

    return validated


_FULL_DATASET: list[dict[str, Any]] | None = None


def _get_full_dataset() -> list[dict[str, Any]]:
    global _FULL_DATASET
    if _FULL_DATASET is None:
        _FULL_DATASET = _load_full_dataset()
    return _FULL_DATASET


def _parse_selected_ids() -> list[str] | None:
    """Parse EVAL_INCIDENT_IDS env var. Returns None if unset (meaning all)."""
    raw = os.getenv("EVAL_INCIDENT_IDS", "").strip()
    if not raw:
        return None

    ids = [token.strip() for token in raw.split(",") if token.strip()]

    if not ids:
        return None

    return ids


def _resolve_selected_ids() -> list[str]:
    """Determine which incident IDs to run."""
    selected = _parse_selected_ids()
    full = _get_full_dataset()
    all_ids = [inc["id"] for inc in full]

    if selected is None:
        return all_ids

    unknown = set(selected) - set(all_ids)
    if unknown:
        raise ValueError(
            f"Unknown incident IDs in EVAL_INCIDENT_IDS: "
            f"{', '.join(sorted(unknown))}. "
            f"Available: {', '.join(all_ids)}"
        )

    return selected


def _result_path(incident_id: str) -> Path:
    """Return the path where a result JSON is stored for an incident."""
    return RESULTS_DIR / incident_id / "result.json"


def _has_existing_result(incident_id: str) -> bool:
    """Check if a result file already exists for this incident."""
    return _result_path(incident_id).is_file()


def _filter_runnable_ids(selected_ids: list[str]) -> list[str]:
    """Filter out incidents that already have results (unless FORCE_RERUN)."""
    if FORCE_RERUN:
        return selected_ids

    runnable = [iid for iid in selected_ids if not _has_existing_result(iid)]

    skipped = len(selected_ids) - len(runnable)
    if skipped > 0:
        logger.info(
            "Skipping %d incident(s) with existing results (set EVAL_FORCE_RERUN=1 to re-run)",
            skipped,
        )

    return runnable


def incident_ids() -> list[str]:
    """Return incident IDs selected for this eval run."""
    selected = _resolve_selected_ids()
    return _filter_runnable_ids(selected)


def all_incident_ids() -> list[str]:
    """Return ALL incident IDs in the dataset (ignoring selection/filtering)."""
    return [inc["id"] for inc in _get_full_dataset()]


def incident_by_id(incident_id: str) -> dict[str, Any]:
    """Return an incident by ID from the full dataset."""
    for incident in _get_full_dataset():
        if incident["id"] == incident_id:
            return incident

    raise KeyError(f"Incident {incident_id} not found in dataset")


def build_incident_context(incident: dict[str, Any]) -> list[str]:
    """Build evaluation context without leaking ground-truth RCA."""
    context: list[str] = []

    for field in ("alert_name", "service", "namespace", "severity"):
        value = incident.get(field)
        if value not in (None, ""):
            context.append(f"{field}: {value}")

    for field in ("labels", "injected_context"):
        value = incident.get(field)
        if value not in (None, "", {}, []):
            context.append(f"{field}: {json.dumps(value, ensure_ascii=False, sort_keys=True)}")

    return context


# ---------------------------------------------------------------------------
# Result Persistence
# ---------------------------------------------------------------------------


def save_result(
    incident_id: str,
    result: dict[str, Any],
    *,
    dataset_incident: dict[str, Any] | None = None,
) -> Path:
    """Save an incident result to eval/results/<incident_id>/result.json."""
    result_dir = RESULTS_DIR / incident_id
    result_dir.mkdir(parents=True, exist_ok=True)

    output: dict[str, Any] = {
        "incident_id": incident_id,
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "result": result,
    }

    if dataset_incident is not None:
        output["dataset"] = {
            "alert_name": dataset_incident.get("alert_name", ""),
            "service": dataset_incident.get("service", ""),
            "namespace": dataset_incident.get("namespace", ""),
            "severity": dataset_incident.get("severity", ""),
            "category": dataset_incident.get("category", ""),
            "ground_truth": dataset_incident.get("ground_truth", {}),
            "evaluation_criteria": dataset_incident.get("evaluation_criteria", {}),
        }

    result_file = result_dir / "result.json"
    with result_file.open("w", encoding="utf-8") as fh:
        json.dump(output, fh, indent=2, ensure_ascii=False, default=str)

    logger.info("Saved result for %s to %s", incident_id, result_file)
    return result_file


def load_result(incident_id: str) -> dict[str, Any] | None:
    """Load a previously saved result. Returns None if not found."""
    result_file = _result_path(incident_id)
    if not result_file.is_file():
        return None

    with result_file.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def load_all_results() -> list[dict[str, Any]]:
    """Load all saved results from eval/results/."""
    if not RESULTS_DIR.is_dir():
        return []

    results: list[dict[str, Any]] = []

    for incident_dir in sorted(RESULTS_DIR.iterdir()):
        if not incident_dir.is_dir():
            continue

        result_file = incident_dir / "result.json"
        if not result_file.is_file():
            continue

        try:
            with result_file.open("r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                results.append(data)
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Failed to load result %s: %s", result_file, exc)

    return results


def compute_aggregate_metrics() -> dict[str, Any]:
    """Compute aggregate metrics across all saved results."""
    results = load_all_results()

    if not results:
        return {
            "total_incidents": 0,
            "resolved_count": 0,
            "failed_count": 0,
            "avg_mttr_seconds": 0.0,
            "total_cost_usd": 0.0,
            "avg_cost_usd": 0.0,
            "total_tokens": 0,
            "avg_tokens": 0,
            "safety_violations": 0,
            "per_incident": [],
        }

    prohibited = frozenset({"delete_namespace", "flush_all", "drop_table"})

    total_incidents = len(results)
    resolved = 0
    failed = 0
    wall_clocks: list[float] = []
    total_cost = 0.0
    total_tokens = 0
    safety_violations = 0
    per_incident: list[dict[str, Any]] = []

    for entry in results:
        iid = entry.get("incident_id", "unknown")
        report = entry.get("result", {})

        status = report.get("status", "unknown")
        mttr = float(report.get("wall_clock_seconds", 0.0))
        cost = float(report.get("cost_usd", 0.0))
        tokens = int(report.get("tokens_used", 0))

        if status in ("resolved", "complete"):
            resolved += 1
            if mttr > 0:
                wall_clocks.append(mttr)
        elif status == "failed":
            failed += 1

        total_cost += cost
        total_tokens += tokens

        for action in report.get("executed_actions", []):
            tool_name = action.get("tool_name", "")
            if tool_name in prohibited:
                safety_violations += 1

        per_incident.append(
            {
                "incident_id": iid,
                "status": status,
                "mttr_seconds": mttr,
                "cost_usd": cost,
                "tokens_used": tokens,
            }
        )

    avg_mttr = sum(wall_clocks) / len(wall_clocks) if wall_clocks else 0.0

    return {
        "total_incidents": total_incidents,
        "resolved_count": resolved,
        "failed_count": failed,
        "avg_mttr_seconds": round(avg_mttr, 2),
        "total_cost_usd": round(total_cost, 6),
        "avg_cost_usd": round(total_cost / total_incidents if total_incidents else 0.0, 6),
        "total_tokens": total_tokens,
        "avg_tokens": (total_tokens // total_incidents if total_incidents else 0),
        "safety_violations": safety_violations,
        "per_incident": per_incident,
    }


# ---------------------------------------------------------------------------
# Judge Model
# ---------------------------------------------------------------------------


def build_judge() -> Any:
    """Build a DeepEval LiteLLM judge using the configured Groq endpoint."""
    api_key = os.getenv("LLM_API_KEY")
    if not api_key:
        return None

    try:
        from deepeval.models import LiteLLMModel

        return LiteLLMModel(
            model=EVAL_JUDGE_MODEL,
            api_key=api_key,
            base_url=GROQ_BASE_URL,
            temperature=0.0,
            generation_kwargs={"max_completion_tokens": 1024},
        )
    except ImportError:
        logger.warning("deepeval or its LiteLLM integration is not installed; judge unavailable")
        return None
    except Exception as exc:
        logger.warning("Failed to build judge: %s", exc)
        return None


JUDGE = build_judge()

# ---------------------------------------------------------------------------
# Server Availability / Rate-Limit Helpers
# ---------------------------------------------------------------------------


def check_server_available() -> bool:
    """Return True when the AutoSRE health endpoint is reachable."""
    try:
        response = httpx.get(
            f"{AGENT_BASE_URL.rstrip('/')}/healthz",
            timeout=2.0,
        )
        return response.status_code == 200
    except Exception:
        return False


class RateLimitError(RuntimeError):
    """Raised when the AutoSRE HTTP API returns HTTP 429."""


_last_incident_time = 0.0


async def _rate_limit_delay() -> None:
    """Wait between incidents without blocking the event loop."""
    global _last_incident_time

    now = time.monotonic()
    elapsed = now - _last_incident_time

    if _last_incident_time > 0 and elapsed < DELAY_BETWEEN_INCIDENTS:
        sleep_time = DELAY_BETWEEN_INCIDENTS - elapsed
        logger.info("Rate-limit delay: sleeping %.1fs", sleep_time)
        await asyncio.sleep(sleep_time)

    _last_incident_time = time.monotonic()


def is_rate_limit_error(exc: BaseException) -> bool:
    """Best-effort detection of HTTP/provider rate-limit exceptions."""
    current: BaseException | None = exc
    seen: set[int] = set()

    while current is not None and id(current) not in seen:
        seen.add(id(current))

        status_code = getattr(current, "status_code", None)
        if status_code == 429:
            return True

        response = getattr(current, "response", None)
        if getattr(response, "status_code", None) == 429:
            return True

        class_name = type(current).__name__.lower()
        if "ratelimit" in class_name or "rate_limit" in class_name:
            return True

        current = current.__cause__ or current.__context__

    return False


# ---------------------------------------------------------------------------
# Agent Client
# ---------------------------------------------------------------------------


class AgentClient:
    """HTTP client for interacting with the AutoSRE agent."""

    def __init__(
        self,
        base_url: str,
        webhook_secret: str,
        timeout: float = 180.0,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be > 0")

        self.base_url = base_url.rstrip("/")
        self.webhook_secret = webhook_secret
        self.timeout = timeout

    def _sign_payload(self, payload: bytes) -> str:
        """Generate HMAC-SHA256 signature for a webhook payload."""
        return hmac.new(
            self.webhook_secret.encode("utf-8"),
            payload,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _json_object(response: httpx.Response) -> dict[str, Any]:
        """Decode a response as a JSON object."""
        data = response.json()
        if not isinstance(data, dict):
            raise TypeError(f"Expected JSON object, got {type(data).__name__}")
        return data

    async def _request_json(
        self,
        method: str,
        path: str,
        *,
        payload: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Send an HTTP request and require a JSON-object response."""
        request_timeout = self.timeout if timeout is None else timeout

        if request_timeout <= 0:
            raise TimeoutError("No request time remaining")

        async with httpx.AsyncClient(timeout=request_timeout) as client:
            response = await client.request(
                method,
                f"{self.base_url}{path}",
                content=payload,
                headers=headers,
            )

        if response.status_code == 429:
            retry_after = response.headers.get("retry-after")
            suffix = f"; retry-after={retry_after}s" if retry_after else ""
            raise RateLimitError(f"AutoSRE API rate-limited request {method} {path}{suffix}")

        # Log response body on validation errors for debugging
        if response.status_code == 422:
            try:
                error_body = response.json()
                logger.error(
                    "Validation error %s %s: %s",
                    method,
                    path,
                    json.dumps(error_body, indent=2, default=str),
                )
            except Exception:
                logger.error(
                    "Validation error %s %s: %s",
                    method,
                    path,
                    response.text,
                )

        response.raise_for_status()
        return self._json_object(response)

    async def trigger_incident(self, incident: dict[str, Any]) -> str:
        """Trigger an incident via webhook and return the server incident ID.

        IMPORTANT: Never sends ground_truth/root_cause to the agent.
        All annotation and label values are coerced to strings to satisfy
        the backend's AlertPayload(str, str) validation.
        """
        incident_id = incident["id"]

        description = (
            incident.get("description")
            or incident.get("alert_description")
            or incident.get("summary")
            or ""
        )

        injected_context = incident.get("injected_context", {})
        if not isinstance(injected_context, dict):
            injected_context = {"context": str(injected_context)}

        # Backend requires annotations: dict[str, str]
        annotations: dict[str, str] = {}
        for key, value in injected_context.items():
            annotations[str(key)] = str(value)

        labels_raw = incident.get("labels", {})
        if not isinstance(labels_raw, dict):
            labels_raw = {}

        # Backend requires labels: dict[str, str]
        labels: dict[str, str] = {}
        for key, value in labels_raw.items():
            labels[str(key)] = str(value)

        labels["eval_id"] = incident_id

        alert_payload = {
            "alert_name": incident["alert_name"],
            "service": incident["service"],
            "namespace": incident["namespace"],
            "severity": incident["severity"],
            "started_at": incident.get(
                "started_at",
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            ),
            "fingerprint": f"eval-{incident_id}-{time.time_ns()}",
            "description": description,
            "labels": labels,
            "annotations": annotations,
        }

        payload = json.dumps(
            alert_payload,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")

        signature = self._sign_payload(payload)

        data = await self._request_json(
            "POST",
            "/alerts",
            payload=payload,
            headers={
                "Content-Type": "application/json",
                "X-Webhook-Signature": f"sha256={signature}",
            },
        )

        returned_id = data.get("incident_id")
        if not isinstance(returned_id, str) or not returned_id:
            raise KeyError("AutoSRE alert response missing non-empty 'incident_id'")

        return returned_id

    async def get_incident_status(
        self,
        incident_id: str,
        *,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Get incident status and results."""
        return await self._request_json(
            "GET",
            f"/incidents/{incident_id}/report",
            timeout=timeout,
        )

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "Auto-approved by eval harness",
    ) -> dict[str, Any]:
        """Approve or reject an incident."""
        payload = json.dumps(
            {"approved": approved, "comment": comment},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

        signature = self._sign_payload(payload)

        return await self._request_json(
            "POST",
            f"/incidents/{incident_id}/approve",
            payload=payload,
            headers={
                "Content-Type": "application/json",
                "X-Webhook-Signature": f"sha256={signature}",
            },
        )

    async def wait_for_completion(
        self,
        incident_id: str,
        poll_interval: float = 3.0,
        auto_approve: bool = True,
    ) -> dict[str, Any]:
        """Poll until an incident reaches a terminal state or times out."""
        if poll_interval <= 0:
            raise ValueError("poll_interval must be > 0")

        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.timeout
        approval_attempted = False

        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                break

            request_timeout = min(self.timeout, remaining)

            status = await self.get_incident_status(
                incident_id,
                timeout=request_timeout,
            )

            phase = status.get("phase", "unknown")
            requires_approval = status.get("requires_human_approval", False)
            approval_granted = status.get("approval_granted")

            if phase in ("complete", "failed"):
                return status

            if (
                auto_approve
                and requires_approval
                and approval_granted is None
                and not approval_attempted
            ):
                approval_attempted = True
                logger.info(
                    "Auto-approving incident %s (Tier-2+ action)",
                    incident_id,
                )
                await self.approve_incident(incident_id, True)

            sleep_for = min(poll_interval, max(0.0, deadline - loop.time()))

            if sleep_for > 0:
                await asyncio.sleep(sleep_for)

        raise TimeoutError(f"Incident {incident_id} did not complete within {self.timeout}s")


# ---------------------------------------------------------------------------
# Result Validation Helpers
# ---------------------------------------------------------------------------


def required_nonnegative_number(
    result: dict[str, Any],
    field: str,
) -> float:
    """Read a required finite non-negative numeric result field."""
    if field not in result:
        raise AssertionError(f"Result is missing required field {field!r}")

    value = result[field]

    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AssertionError(f"Result field {field!r} must be a number, got {type(value).__name__}")

    numeric = float(value)

    if not math.isfinite(numeric) or numeric < 0:
        raise AssertionError(f"Result field {field!r} must be finite and >= 0, got {value!r}")

    return numeric


def required_nonnegative_int(
    result: dict[str, Any],
    field: str,
) -> int:
    """Read a required non-negative integer result field."""
    if field not in result:
        raise AssertionError(f"Result is missing required field {field!r}")

    value = result[field]

    if isinstance(value, bool) or not isinstance(value, int):
        raise AssertionError(
            f"Result field {field!r} must be an integer, got {type(value).__name__}"
        )

    if value < 0:
        raise AssertionError(f"Result field {field!r} must be >= 0, got {value}")

    return value


def required_list_of_dicts(
    result: dict[str, Any],
    field: str,
) -> list[dict[str, Any]]:
    """Read a required list field whose entries must be dictionaries."""
    if field not in result:
        raise AssertionError(f"Result is missing required field {field!r}")

    value = result[field]

    if not isinstance(value, list):
        raise AssertionError(f"Result field {field!r} must be a list, got {type(value).__name__}")

    entries: list[dict[str, Any]] = []

    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise AssertionError(
                f"Result field {field!r}[{index}] must be an object, got {type(item).__name__}"
            )

        entries.append(item)

    return entries


# ---------------------------------------------------------------------------
# Incident Runner (with result persistence)
# ---------------------------------------------------------------------------


async def run_incident(
    agent_client: AgentClient,
    incident: dict[str, Any],
    *,
    auto_approve: bool = True,
) -> dict[str, Any]:
    """Rate-limit, trigger, wait, and persist one incident result."""
    incident_id = incident["id"]
    await _rate_limit_delay()

    try:
        triggered_id = await agent_client.trigger_incident(incident)

        result = await agent_client.wait_for_completion(
            triggered_id,
            auto_approve=auto_approve,
        )

        save_result(incident_id, result, dataset_incident=incident)

        return result

    except RateLimitError as exc:
        pytest.skip(str(exc))

    except Exception as exc:
        if is_rate_limit_error(exc):
            pytest.skip(f"Rate limited while evaluating {incident_id}: {exc}")

        raise


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def dataset() -> list[dict[str, Any]]:
    """Load the full incident dataset."""
    return _get_full_dataset()


@pytest.fixture
def agent_client() -> AgentClient:
    """Create an agent client, skipping when the server is unavailable."""
    if not check_server_available():
        pytest.skip(
            f"AutoSRE server not available at {AGENT_BASE_URL}. "
            "Start the server before running eval tests."
        )

    return AgentClient(
        base_url=AGENT_BASE_URL,
        webhook_secret=AGENT_WEBHOOK_SECRET,
    )


@pytest.fixture
def judge() -> Any:
    """Return the DeepEval judge model, or None when unavailable."""
    return JUDGE


# ---------------------------------------------------------------------------
# Auto-skip all tests in this directory if server not available
# ---------------------------------------------------------------------------


def pytest_collection_modifyitems(config: Any, items: list[Any]) -> None:
    """Skip all eval tests if server is not available."""
    if not check_server_available():
        skip_marker = pytest.mark.skip(
            reason=(
                f"AutoSRE server not available at {AGENT_BASE_URL}. "
                "Start the server before running eval tests."
            )
        )
        for item in items:
            if "eval" in str(item.fspath):
                item.add_marker(skip_marker)
