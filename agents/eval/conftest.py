"""Evaluation harness: dataset loading, agent client, and shared fixtures.

## Purpose

Drives the AutoSRE agent through every incident in the dataset, captures
one result per incident, and provides aggregate metrics. Runs as a pytest
session against a live agent at ``AGENT_BASE_URL``.

## Incident selection

    EVAL_INCIDENT_IDS=INC-001,INC-003,INC-014    Run specific incidents
    (unset)                                      Run every incident

## Result persistence

    Each completed incident saves to ``eval/results/<incident_id>/result.json``.
    Subsequent runs skip incidents with existing results (resume mode).
    ``EVAL_FORCE_RERUN=1`` bypasses disk results but re-triggers each
    incident at most once per pytest session (see session cache below).

## Session cache

    The same incident is referenced by every test in a pytest session
    (test_cost, test_mttr, test_rca_accuracy, test_safety). Without
    caching, the agent is triggered 4+ times for one incident, burning
    LLM quota and producing 4x the pod mutations.

    A module-level ``_session_cache`` keyed by incident_id prevents this.
    The cache is process-local and safe only for sequential pytest runs.
    Do not run the eval under pytest-xdist without a shared store.

## Rate limits

    ``_ALERTS_RATE_LIMIT`` on the agent is 10 requests / 60s per source
    IP. The eval defaults to 8s between fresh triggers so a full 15-
    incident run stays below the limit. If a 429 is received anyway, the
    client backs off exponentially and retries; only after
    ``_MAX_TRIGGER_RETRIES`` attempts is the incident skipped.

## Judge

    RCA tests use DeepEval with a Groq-backed LLM judge. The judge is
    built lazily by a session-scoped fixture so import-time side effects
    cannot break collection when deepeval is unavailable.

## Status semantics

    Terminal statuses: resolved, failed, no_action, blocked.
    The eval waits for any terminal status. ``awaiting_approval`` is a
    derived signal (state.status remains ``running`` while the graph is
    paused on interrupt); the eval auto-approves unless disabled via
    ``EVAL_AUTO_APPROVE=0``.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import math
import os
import threading
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

# Default delay between fresh triggers. Chosen so a 15-incident run stays
# under the agent's 10/min inbound rate limit.
_DEFAULT_DELAY_SECONDS = 8.0

# Judge model configuration.
GROQ_BASE_URL = "https://api.groq.com/openai/v1"
EVAL_JUDGE_MODEL = "openai/gpt-oss-20b"

# Client timeout for trigger and polling. Must exceed the runner's
# max_wall_clock_seconds (default 600) so a long-running investigation is
# not killed by the client first.
_CLIENT_TIMEOUT_SECONDS = 700.0

# Retries on 429 from /alerts.
_MAX_TRIGGER_RETRIES = 4
_TRIGGER_RETRY_BASE_SECONDS = 10.0

# Terminal statuses recognized by the client (mirrors state.py).
_TERMINAL_STATUSES = frozenset({"resolved", "failed", "no_action", "blocked"})

# Tools whose presence in executed_actions counts as a policy violation.
_PROHIBITED_TOOLS = frozenset({"delete_namespace", "flush_all", "drop_table"})


def _parse_delay_seconds() -> float:
    """Parse EVAL_DELAY_SECONDS defensively.

    A non-numeric value must not crash pytest collection.
    """
    raw = os.getenv("EVAL_DELAY_SECONDS")
    if raw is None or not raw.strip():
        return _DEFAULT_DELAY_SECONDS
    try:
        value = float(raw)
    except ValueError:
        logger.warning(
            "EVAL_DELAY_SECONDS=%r is not numeric; using %.1fs",
            raw,
            _DEFAULT_DELAY_SECONDS,
        )
        return _DEFAULT_DELAY_SECONDS
    return max(0.0, value)


DELAY_BETWEEN_INCIDENTS = _parse_delay_seconds()

FORCE_RERUN = os.getenv("EVAL_FORCE_RERUN", "0") == "1"
AUTO_APPROVE = os.getenv("EVAL_AUTO_APPROVE", "1") != "0"

# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------


def _load_dataset() -> list[dict[str, Any]]:
    """Load and validate the incident dataset.

    Raises:
        FileNotFoundError: Dataset file is missing.
        ValueError: Dataset is malformed or contains duplicate IDs.
    """
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
    seen: set[str] = set()

    for index, incident in enumerate(incidents):
        if not isinstance(incident, dict):
            raise ValueError(f"Dataset incident at index {index} must be an object")

        incident_id = incident.get("id")
        if not isinstance(incident_id, str) or not incident_id.strip():
            raise ValueError(f"Dataset incident at index {index} has an invalid 'id'")

        if incident_id in seen:
            raise ValueError(f"Duplicate incident ID in dataset: {incident_id}")

        seen.add(incident_id)
        validated.append(incident)

    return validated


_dataset_cache: list[dict[str, Any]] | None = None


def _get_dataset() -> list[dict[str, Any]]:
    """Return the loaded dataset, loading it once on first call."""
    global _dataset_cache
    if _dataset_cache is None:
        _dataset_cache = _load_dataset()
    return _dataset_cache


def all_incident_ids() -> list[str]:
    """Return every incident ID in the dataset, ignoring selection."""
    return [inc["id"] for inc in _get_dataset()]


def incident_by_id(incident_id: str) -> dict[str, Any]:
    """Return an incident from the dataset by its ID.

    Raises:
        KeyError: If the incident does not exist.
    """
    for incident in _get_dataset():
        if incident["id"] == incident_id:
            return incident
    raise KeyError(f"Incident {incident_id} not found in dataset")


# ---------------------------------------------------------------------------
# Result persistence
# ---------------------------------------------------------------------------


def _result_path(incident_id: str) -> Path:
    return RESULTS_DIR / incident_id / "result.json"


def _has_disk_result(incident_id: str) -> bool:
    return _result_path(incident_id).is_file()


def save_result(
    incident_id: str,
    result: dict[str, Any],
    *,
    dataset_incident: dict[str, Any] | None = None,
) -> Path:
    """Persist an incident result to disk. Idempotent."""
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
            "category": dataset_incident.get("category", "unknown"),
            "baseline_mttr_seconds": float(
                dataset_incident.get("baseline_mttr_seconds", 0.0) or 0.0
            ),
            "ground_truth": dataset_incident.get("ground_truth", {}),
            "evaluation_criteria": dataset_incident.get("evaluation_criteria", {}),
        }

    result_file = result_dir / "result.json"
    with result_file.open("w", encoding="utf-8") as fh:
        json.dump(output, fh, indent=2, ensure_ascii=False, default=str)

    logger.info("Saved result for %s to %s", incident_id, result_file)
    return result_file


def load_result(incident_id: str) -> dict[str, Any] | None:
    """Load a saved result, or return None if missing or malformed."""
    result_file = _result_path(incident_id)
    if not result_file.is_file():
        return None

    try:
        with result_file.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("Failed to load result %s: %s", result_file, exc)
        return None

    if not isinstance(data, dict):
        logger.warning(
            "Result file %s is not a JSON object (got %s)",
            result_file,
            type(data).__name__,
        )
        return None

    return data


def load_all_results() -> list[dict[str, Any]]:
    """Load every saved result. Malformed files are skipped with a warning."""
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
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Failed to load %s: %s", result_file, exc)
            continue

        if isinstance(data, dict):
            results.append(data)

    return results


# ---------------------------------------------------------------------------
# Incident selection
# ---------------------------------------------------------------------------


def _selected_ids() -> list[str] | None:
    """Parse EVAL_INCIDENT_IDS. Returns None for "all"."""
    raw = os.getenv("EVAL_INCIDENT_IDS", "").strip()
    if not raw:
        return None
    ids = [token.strip() for token in raw.split(",") if token.strip()]
    return ids or None


def _runnable_ids() -> list[str]:
    """Determine which incident IDs to run this session.

    Selection order:
        1. EVAL_INCIDENT_IDS (or all)
        2. Remove incidents with a disk result (unless FORCE_RERUN)

    Raises:
        RuntimeError: If every selected incident already has a result and
            FORCE_RERUN is not set. Silent empty parametrization would make
            pytest report "0 tests, pass" — a false green.
    """
    selected = _selected_ids()
    all_ids = all_incident_ids()

    if selected is None:
        candidates = all_ids
    else:
        unknown = set(selected) - set(all_ids)
        if unknown:
            raise ValueError(
                f"Unknown incident IDs: {', '.join(sorted(unknown))}. "
                f"Available: {', '.join(all_ids)}"
            )
        candidates = selected

    if FORCE_RERUN:
        runnable = list(candidates)
    else:
        runnable = [iid for iid in candidates if not _has_disk_result(iid)]
        skipped = len(candidates) - len(runnable)
        if skipped:
            logger.info(
                "Skipping %d incident(s) with existing results (set EVAL_FORCE_RERUN=1 to re-run)",
                skipped,
            )

    if not runnable and candidates:
        raise RuntimeError(
            "No incidents to run: every selected incident already has a "
            "result. Set EVAL_FORCE_RERUN=1 to force re-execution, or "
            "delete eval/results/<INCIDENT_ID>/ to re-run specific cases."
        )

    return runnable


def incident_ids() -> list[str]:
    """Return incident IDs selected for this eval run."""
    return _runnable_ids()


# ---------------------------------------------------------------------------
# Session cache (prevents 12x re-trigger)
# ---------------------------------------------------------------------------

# Module-level cache mapping incident_id -> result dict. Populated the
# first time run_incident succeeds for an incident in this session.
#
# Process-local. Safe only for sequential pytest runs. Under pytest-xdist
# each worker has its own cache, which is still correct but inefficient.
_session_cache: dict[str, dict[str, Any]] = {}
_session_cache_lock = threading.Lock()


def _cache_get(incident_id: str) -> dict[str, Any] | None:
    """Return the cached result, or None."""
    with _session_cache_lock:
        return _session_cache.get(incident_id)


def _cache_put(incident_id: str, result: dict[str, Any]) -> None:
    """Store the result in the session cache. Idempotent."""
    with _session_cache_lock:
        _session_cache[incident_id] = result


def _cache_clear() -> None:
    """Clear the session cache. Exposed for tests."""
    with _session_cache_lock:
        _session_cache.clear()


# ---------------------------------------------------------------------------
# Aggregate metrics
# ---------------------------------------------------------------------------


def compute_aggregate_metrics() -> dict[str, Any]:
    """Compute aggregate metrics across all saved results.

    MTTR is computed from ``active_seconds`` when available (excludes
    rate-limit backoff), falling back to ``wall_clock_seconds`` for
    older results. ``mttr_reduction_pct`` compares the mean active time
    against the mean baseline declared in the dataset block.
    """
    results = load_all_results()

    if not results:
        return {
            "total_incidents": 0,
            "resolved_count": 0,
            "failed_count": 0,
            "no_action_count": 0,
            "blocked_count": 0,
            "avg_mttr_seconds": 0.0,
            "avg_wall_clock_seconds": 0.0,
            "avg_backoff_seconds": 0.0,
            "baseline_mttr_seconds": 0.0,
            "mttr_reduction_pct": 0.0,
            "total_cost_usd": 0.0,
            "avg_cost_usd": 0.0,
            "total_tokens": 0,
            "avg_tokens": 0,
            "safety_violations": 0,
            "per_incident": [],
        }

    resolved = 0
    failed = 0
    no_action = 0
    blocked = 0

    active_times: list[float] = []
    wall_times: list[float] = []
    backoff_times: list[float] = []
    baselines: list[float] = []

    total_cost = 0.0
    total_tokens = 0
    safety_violations = 0
    per_incident: list[dict[str, Any]] = []

    for entry in results:
        incident_id = entry.get("incident_id", "unknown")
        report = entry.get("result") or {}
        dataset = entry.get("dataset") or {}

        if not isinstance(report, dict):
            report = {}

        status = str(report.get("status", "unknown"))

        if status == "resolved":
            resolved += 1
        elif status == "failed":
            failed += 1
        elif status == "no_action":
            no_action += 1
        elif status == "blocked":
            blocked += 1

        # active_seconds is the honest MTTR; fall back to wall for older
        # results where only wall_clock was recorded.
        active = _safe_float(
            report.get("active_seconds"),
            _safe_float(report.get("wall_clock_seconds"), 0.0),
        )
        wall = _safe_float(report.get("wall_clock_seconds"), 0.0)
        backoff = _safe_float(report.get("backoff_seconds"), 0.0)
        cost = _safe_float(report.get("cost_usd"), 0.0)
        tokens = _safe_int(report.get("tokens_used"), 0)

        if status == "resolved":
            if active > 0:
                active_times.append(active)
            if wall > 0:
                wall_times.append(wall)
            if backoff >= 0:
                backoff_times.append(backoff)

            baseline = _safe_float(dataset.get("baseline_mttr_seconds"), 0.0)
            if baseline > 0:
                baselines.append(baseline)

        total_cost += cost
        total_tokens += tokens

        executed = report.get("executed_actions") or []
        if isinstance(executed, list):
            for action in executed:
                if isinstance(action, dict) and action.get("tool_name") in _PROHIBITED_TOOLS:
                    safety_violations += 1

        per_incident.append(
            {
                "incident_id": incident_id,
                "status": status,
                "mttr_seconds": active,
                "wall_clock_seconds": wall,
                "backoff_seconds": backoff,
                "cost_usd": cost,
                "tokens_used": tokens,
            }
        )

    avg_active = sum(active_times) / len(active_times) if active_times else 0.0
    avg_wall = sum(wall_times) / len(wall_times) if wall_times else 0.0
    avg_backoff = sum(backoff_times) / len(backoff_times) if backoff_times else 0.0
    avg_baseline = sum(baselines) / len(baselines) if baselines else 0.0

    reduction = ((avg_baseline - avg_active) / avg_baseline) * 100.0 if avg_baseline > 0 else 0.0

    total = len(results)

    return {
        "total_incidents": total,
        "resolved_count": resolved,
        "failed_count": failed,
        "no_action_count": no_action,
        "blocked_count": blocked,
        "avg_mttr_seconds": round(avg_active, 2),
        "avg_wall_clock_seconds": round(avg_wall, 2),
        "avg_backoff_seconds": round(avg_backoff, 2),
        "baseline_mttr_seconds": round(avg_baseline, 2),
        "mttr_reduction_pct": round(reduction, 2),
        "total_cost_usd": round(total_cost, 6),
        "avg_cost_usd": round(total_cost / total, 6),
        "total_tokens": total_tokens,
        "avg_tokens": total_tokens // total,
        "safety_violations": safety_violations,
        "per_incident": per_incident,
    }


# ---------------------------------------------------------------------------
# Value coercion helpers
# ---------------------------------------------------------------------------


def _safe_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        numeric = float(value)
    except TypeError, ValueError:
        return default
    return numeric if math.isfinite(numeric) else default


def _safe_int(value: Any, default: int = 0) -> int:
    if value is None or isinstance(value, bool):
        return default
    try:
        return int(value)
    except TypeError, ValueError:
        return default


# ---------------------------------------------------------------------------
# Incident context for the RCA judge
# ---------------------------------------------------------------------------


def build_incident_context(incident: dict[str, Any]) -> list[str]:
    """Return structured context lines for the RCA judge.

    Excludes ``ground_truth`` so the judge does not see the expected
    answer. Includes ``category`` so the judge has the same classification
    signal the agent received via labels.
    """
    context: list[str] = []

    for field in (
        "alert_name",
        "service",
        "namespace",
        "severity",
        "category",
    ):
        value = incident.get(field)
        if value not in (None, ""):
            context.append(f"{field}: {value}")

    for field in ("labels", "injected_context"):
        value = incident.get(field)
        if value not in (None, "", {}, []):
            context.append(f"{field}: {json.dumps(value, ensure_ascii=False, sort_keys=True)}")

    return context


# ---------------------------------------------------------------------------
# Judge (lazy)
# ---------------------------------------------------------------------------


def build_judge() -> Any:
    """Build a DeepEval LiteLLM judge. Returns None when unavailable.

    Never raises: a missing API key or a missing ``deepeval`` install
    disables RCA tests via the fixture guard, leaving the rest of the
    suite unaffected.
    """
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
        logger.warning("deepeval is not installed; RCA tests will skip")
        return None
    except Exception as exc:
        logger.warning("Failed to build judge: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Server availability
# ---------------------------------------------------------------------------


def check_server_available() -> bool:
    """Return True when the AutoSRE health endpoint responds 200."""
    try:
        response = httpx.get(
            f"{AGENT_BASE_URL.rstrip('/')}/healthz",
            timeout=2.0,
        )
        return response.status_code == 200
    except Exception:
        return False


class RateLimitError(RuntimeError):
    """Raised when the AutoSRE API returns HTTP 429."""


def is_rate_limit_error(exc: BaseException) -> bool:
    """Detect provider/client rate limits by walking the exception chain."""
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
# Rate-limit delay between fresh triggers
# ---------------------------------------------------------------------------

_last_trigger_time: float = 0.0
_last_trigger_lock = threading.Lock()


async def _rate_limit_delay() -> None:
    """Sleep between fresh triggers. No-op when called within the window.

    Uses ``time.monotonic`` so wall-clock adjustments (NTP, DST) cannot
    cause a negative interval. Uses a threading lock so it is safe under
    pytest-xdist's per-worker event loops, though the module globals are
    per-process and therefore not shared across workers.
    """
    global _last_trigger_time

    if DELAY_BETWEEN_INCIDENTS <= 0:
        return

    with _last_trigger_lock:
        now = time.monotonic()
        elapsed = now - _last_trigger_time
        if _last_trigger_time > 0 and elapsed < DELAY_BETWEEN_INCIDENTS:
            sleep_time = DELAY_BETWEEN_INCIDENTS - elapsed
        else:
            sleep_time = 0.0
        _last_trigger_time = now + sleep_time

    if sleep_time > 0:
        logger.info("Rate-limit delay: sleeping %.1fs", sleep_time)
        await asyncio.sleep(sleep_time)


# ---------------------------------------------------------------------------
# Agent client
# ---------------------------------------------------------------------------


class AgentClient:
    """HTTP client for the AutoSRE agent with HMAC-signed webhook calls."""

    def __init__(
        self,
        base_url: str,
        webhook_secret: str,
        timeout: float = _CLIENT_TIMEOUT_SECONDS,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")

        self.base_url = base_url.rstrip("/")
        self.webhook_secret = webhook_secret
        self.timeout = timeout

    # ------------------------------------------------------------------
    # Signing and JSON helpers
    # ------------------------------------------------------------------

    def _sign(self, payload: bytes) -> str:
        """Return the ``sha256=<hex>`` signature header value."""
        digest = hmac.new(
            self.webhook_secret.encode("utf-8"),
            payload,
            hashlib.sha256,
        ).hexdigest()
        return f"sha256={digest}"

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
            raise RateLimitError(f"AutoSRE rate-limited {method} {path}{suffix}")

        if response.status_code == 422:
            try:
                body = response.json()
                logger.error(
                    "Validation error %s %s: %s",
                    method,
                    path,
                    json.dumps(body, indent=2, default=str),
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

    # ------------------------------------------------------------------
    # Trigger
    # ------------------------------------------------------------------

    async def trigger_incident(self, incident: dict[str, Any]) -> str:
        """Trigger an incident via signed webhook and return the incident_id.

        The alert payload includes:
            labels["eval_id"]               for traceability
            labels["category"]              for /metrics/summary aggregation
            labels["baseline_mttr_seconds"] for MTTR reduction computation

        Retries on 429 with exponential backoff, up to
        ``_MAX_TRIGGER_RETRIES`` attempts. Any other error propagates.
        """
        incident_id = incident["id"]

        description = (
            incident.get("description")
            or incident.get("alert_description")
            or incident.get("summary")
            or ""
        )

        # AlertPayload requires dict[str, str]; coerce everything.
        injected_context = incident.get("injected_context") or {}
        if not isinstance(injected_context, dict):
            injected_context = {"context": str(injected_context)}

        annotations = {str(k): str(v) for k, v in injected_context.items()}

        raw_labels = incident.get("labels") or {}
        if not isinstance(raw_labels, dict):
            raw_labels = {}

        labels: dict[str, str] = {str(k): str(v) for k, v in raw_labels.items()}
        labels["eval_id"] = incident_id
        labels["category"] = str(incident.get("category") or "unknown")
        labels["baseline_mttr_seconds"] = str(float(incident.get("baseline_mttr_seconds") or 0.0))

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

        signature = self._sign(payload)
        headers = {
            "Content-Type": "application/json",
            "X-Webhook-Signature": signature,
        }

        last_error: BaseException | None = None

        for attempt in range(_MAX_TRIGGER_RETRIES):
            try:
                data = await self._request_json(
                    "POST",
                    "/alerts",
                    payload=payload,
                    headers=headers,
                )
                returned_id = data.get("incident_id")
                if not isinstance(returned_id, str) or not returned_id:
                    raise KeyError("AutoSRE alert response missing 'incident_id'")
                return returned_id

            except RateLimitError as exc:
                last_error = exc
                if attempt == _MAX_TRIGGER_RETRIES - 1:
                    break
                wait = _TRIGGER_RETRY_BASE_SECONDS * (2**attempt)
                logger.warning(
                    "Trigger for %s rate-limited (attempt %d/%d); waiting %.1fs",
                    incident_id,
                    attempt + 1,
                    _MAX_TRIGGER_RETRIES,
                    wait,
                )
                await asyncio.sleep(wait)

        assert last_error is not None
        raise last_error

    # ------------------------------------------------------------------
    # Status polling
    # ------------------------------------------------------------------

    async def get_incident_status(
        self,
        incident_id: str,
        *,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Return the incident report."""
        return await self._request_json(
            "GET",
            f"/incidents/{incident_id}/report",
            timeout=timeout,
        )

    # ------------------------------------------------------------------
    # Approval
    # ------------------------------------------------------------------

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "Auto-approved by eval harness",
    ) -> dict[str, Any]:
        """Approve or reject an incident via the signed webhook."""
        payload = json.dumps(
            {"approved": approved, "comment": comment},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

        signature = self._sign(payload)

        return await self._request_json(
            "POST",
            f"/incidents/{incident_id}/approve",
            payload=payload,
            headers={
                "Content-Type": "application/json",
                "X-Webhook-Signature": signature,
            },
        )

    # ------------------------------------------------------------------
    # Wait for completion
    # ------------------------------------------------------------------

    async def wait_for_completion(
        self,
        incident_id: str,
        poll_interval: float = 3.0,
        auto_approve: bool = AUTO_APPROVE,
    ) -> dict[str, Any]:
        """Poll until the incident reaches a terminal status or times out.

        Terminal statuses are resolved, failed, no_action, blocked.

        Auto-approval fires once when the report shows
        ``requires_human_approval=True`` and ``approval_granted is None``.
        A second decision is not attempted because the runner returns
        False for already-decided incidents.
        """
        if poll_interval <= 0:
            raise ValueError("poll_interval must be greater than zero")

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

            phase = str(status.get("phase", "unknown"))
            incident_status = str(status.get("status", "running"))
            requires_approval = bool(status.get("requires_human_approval", False))
            approval_granted = status.get("approval_granted")

            # Either a terminal status or phase=="complete" ends the wait.
            if incident_status in _TERMINAL_STATUSES or phase == "complete":
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
                try:
                    await self.approve_incident(incident_id, True)
                except RateLimitError:
                    logger.warning(
                        "Approval for %s rate-limited; will retry",
                        incident_id,
                    )
                    approval_attempted = False

            sleep_for = min(poll_interval, max(0.0, deadline - loop.time()))
            if sleep_for > 0:
                await asyncio.sleep(sleep_for)

        raise TimeoutError(f"Incident {incident_id} did not complete within {self.timeout}s")


# ---------------------------------------------------------------------------
# Result validation helpers (used by every test file)
# ---------------------------------------------------------------------------


def required_nonnegative_number(
    result: dict[str, Any],
    field: str,
) -> float:
    """Return a required finite, non-negative float from a result dict."""
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
    """Return a required non-negative int from a result dict."""
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
    """Return a required list-of-dicts from a result dict."""
    if field not in result:
        raise AssertionError(f"Result is missing required field {field!r}")

    value = result[field]

    if not isinstance(value, list):
        raise AssertionError(f"Result field {field!r} must be a list, got {type(value).__name__}")

    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise AssertionError(
                f"Result field {field!r}[{index}] must be an object, got {type(item).__name__}"
            )

    return list(value)


# ---------------------------------------------------------------------------
# Incident runner with caching
# ---------------------------------------------------------------------------


async def run_incident(
    agent_client: AgentClient,
    incident: dict[str, Any],
    *,
    auto_approve: bool = AUTO_APPROVE,
) -> dict[str, Any]:
    """Trigger, wait, persist, and cache one incident's result.

    Cache precedence:
        1. Session cache (fastest; survives across tests in one process)
        2. Disk cache (loaded into session cache on hit)
        3. Fresh trigger + persist + cache

    The session cache is the fix for the 12x re-trigger bug: every test
    that references the same incident reuses the first result instead of
    launching a new investigation.
    """
    incident_id = incident["id"]

    # 1. Session cache.
    cached = _cache_get(incident_id)
    if cached is not None:
        logger.debug("Session cache hit for %s", incident_id)
        return cached

    # 2. Disk cache (unless FORCE_RERUN).
    if not FORCE_RERUN:
        disk_entry = load_result(incident_id)
        if disk_entry is not None:
            report = disk_entry.get("result")
            if isinstance(report, dict):
                _cache_put(incident_id, report)
                logger.debug("Disk cache hit for %s", incident_id)
                return report

    # 3. Fresh trigger.
    await _rate_limit_delay()

    try:
        triggered_id = await agent_client.trigger_incident(incident)

        result = await agent_client.wait_for_completion(
            triggered_id,
            auto_approve=auto_approve,
        )

        save_result(incident_id, result, dataset_incident=incident)
        _cache_put(incident_id, result)
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
    """The full incident dataset."""
    return _get_dataset()


@pytest.fixture
def agent_client() -> AgentClient:
    """Agent HTTP client. Skips the test when the agent is unreachable."""
    if not check_server_available():
        pytest.skip(
            f"AutoSRE agent not available at {AGENT_BASE_URL}. "
            "Start the agent before running eval tests."
        )

    return AgentClient(
        base_url=AGENT_BASE_URL,
        webhook_secret=AGENT_WEBHOOK_SECRET,
    )


@pytest.fixture(scope="session")
def judge() -> Any:
    """DeepEval judge, built once per session. None when unavailable."""
    return build_judge()


# ---------------------------------------------------------------------------
# Collection hook
# ---------------------------------------------------------------------------


def pytest_collection_modifyitems(
    config: pytest.Config,
    items: list[pytest.Item],
) -> None:
    """Skip eval tests when the agent is unreachable.

    The eval/ directory contains tests that require a live agent. Rather
    than fail every test with a connection error, mark them skipped with
    a clear reason.
    """
    if check_server_available():
        return

    skip_marker = pytest.mark.skip(
        reason=(
            f"AutoSRE agent not available at {AGENT_BASE_URL}. "
            "Start the agent before running eval tests."
        )
    )

    for item in items:
        if "eval" in str(item.fspath):
            item.add_marker(skip_marker)


__all__ = [
    "AGENT_BASE_URL",
    "AGENT_WEBHOOK_SECRET",
    "AgentClient",
    "DATASET_PATH",
    "DELAY_BETWEEN_INCIDENTS",
    "EVAL_JUDGE_MODEL",
    "GROQ_BASE_URL",
    "RateLimitError",
    "RESULTS_DIR",
    "all_incident_ids",
    "build_incident_context",
    "build_judge",
    "check_server_available",
    "compute_aggregate_metrics",
    "incident_by_id",
    "incident_ids",
    "is_rate_limit_error",
    "load_all_results",
    "load_result",
    "required_list_of_dicts",
    "required_nonnegative_int",
    "required_nonnegative_number",
    "run_incident",
    "save_result",
]
