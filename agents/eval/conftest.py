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

    A module-level ``_session_cache`` keyed by incident_id prevents the
    same incident from being triggered multiple times across tests in
    one pytest session. The cache is process-local and safe only for
    sequential pytest runs.

## Chaos injection

    Each incident's trigger is executed by shelling out to
    ``chaos/trigger.sh``, which reads the dataset and applies the
    mechanism. Reset is called before each trigger to guarantee a known
    baseline. Both are best-effort: if the chaos toolkit is missing or a
    trigger fails, the eval still runs, but the incident observes a
    healthy cluster and the agent correctly reports no_action.

## Judge

    RCA tests use DeepEval with an LLM judge. The judge model uses the
    canonical ``<provider>/<model>`` form and is passed through to
    LiteLLM verbatim. For example: ``gemini/gemini-3.8-flash``.

    Retry and backoff settings for the judge are read from
    ``settings.llm`` so the judge and the agent share the same
    transient-error handling policy.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import math
import os
import re
import threading
import time
from pathlib import Path
from typing import Any

import httpx

# Configure LiteLLM to drop unsupported parameters for Gemini
import litellm
import pytest

litellm.drop_params = True

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_EVAL_DIR = Path(__file__).parent
_AGENTS_DIR = _EVAL_DIR.parent
DATASET_PATH = _EVAL_DIR / "dataset" / "AutoSRE-Dataset-v3.json"
RESULTS_DIR = _EVAL_DIR / "results"
CHAOS_TRIGGER = _AGENTS_DIR / "chaos" / "trigger.sh"
CHAOS_RESET = _AGENTS_DIR / "chaos" / "reset.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AGENT_BASE_URL = os.getenv("AGENT_BASE_URL", "http://localhost:8000")
AGENT_WEBHOOK_SECRET = os.getenv("ALERT_WEBHOOK_SECRET", "test-secret")

_DEFAULT_DELAY_SECONDS = 8.0
_CLIENT_TIMEOUT_SECONDS = 700.0

_MAX_TRIGGER_RETRIES = 4
_TRIGGER_RETRY_BASE_SECONDS = 10.0

_TERMINAL_STATUSES = frozenset({"resolved", "failed", "no_action", "blocked"})

_PROHIBITED_TOOLS = frozenset({"delete_namespace", "flush_all", "drop_table"})

# Incidents that do not require chaos injection. They test webhook and
# policy paths only.
_NO_CHAOS_INCIDENTS = frozenset({"INC-010", "INC-011"})

# Substrings in error messages indicating daily quota exhaustion.
# Daily-quota errors must fast-fail: retrying won't restore the bucket.
_DAILY_QUOTA_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"quota exceeded", re.IGNORECASE),
    re.compile(r"daily.*limit", re.IGNORECASE),
    re.compile(r"RPD", re.IGNORECASE),
    re.compile(r"requests per day", re.IGNORECASE),
    re.compile(r"resource has been exhausted", re.IGNORECASE),
)


def _parse_delay_seconds() -> float:
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

_APPLY_CHAOS_DEFAULT = CHAOS_TRIGGER.is_file() and CHAOS_RESET.is_file()
APPLY_CHAOS = os.getenv("EVAL_APPLY_CHAOS", "1" if _APPLY_CHAOS_DEFAULT else "0") == "1"


# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------


def _load_dataset() -> list[dict[str, Any]]:
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
    global _dataset_cache
    if _dataset_cache is None:
        _dataset_cache = _load_dataset()
    return _dataset_cache


def all_incident_ids() -> list[str]:
    return [inc["id"] for inc in _get_dataset()]


def incident_by_id(incident_id: str) -> dict[str, Any]:
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
    raw = os.getenv("EVAL_INCIDENT_IDS", "").strip()
    if not raw:
        return None
    ids = [token.strip() for token in raw.split(",") if token.strip()]
    return ids or None


def _runnable_ids() -> list[str]:
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
    return _runnable_ids()


# ---------------------------------------------------------------------------
# Session cache
# ---------------------------------------------------------------------------

_session_cache: dict[str, dict[str, Any]] = {}
_session_cache_lock = threading.Lock()


def _cache_get(incident_id: str) -> dict[str, Any] | None:
    with _session_cache_lock:
        return _session_cache.get(incident_id)


def _cache_put(incident_id: str, result: dict[str, Any]) -> None:
    with _session_cache_lock:
        _session_cache[incident_id] = result


def _cache_clear() -> None:
    with _session_cache_lock:
        _session_cache.clear()


# ---------------------------------------------------------------------------
# Chaos injection
# ---------------------------------------------------------------------------


async def _run_chaos_script(script: Path, *args: str) -> bool:
    """Execute a chaos script. Returns True on exit code 0.

    Never raises: chaos failures are logged and return False so the eval
    can continue against whatever state the cluster is in.
    """
    if not script.is_file():
        logger.debug("Chaos script not found: %s", script)
        return False

    try:
        proc = await asyncio.create_subprocess_exec(
            "bash",
            str(script),
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except Exception as exc:
        logger.warning("Failed to spawn %s: %s", script, exc)
        return False

    stdout, stderr = await proc.communicate()

    if proc.returncode != 0:
        logger.warning(
            "Chaos script %s %s failed (exit %d): %s",
            script.name,
            " ".join(args),
            proc.returncode,
            stderr.decode("utf-8", errors="replace").strip(),
        )
        return False

    output = stdout.decode("utf-8", errors="replace").strip()
    if output:
        for line in output.splitlines():
            logger.info("chaos: %s", line)

    return True


async def _apply_chaos_trigger(incident: dict[str, Any]) -> None:
    """Apply the incident's trigger. No-op for webhook-only incidents."""
    if not APPLY_CHAOS:
        return

    incident_id = incident["id"]
    if incident_id in _NO_CHAOS_INCIDENTS:
        return

    ok = await _run_chaos_script(CHAOS_TRIGGER, incident_id)
    if not ok:
        logger.warning(
            "Chaos trigger for %s was not applied. The agent will "
            "investigate a healthy cluster and may report no_action.",
            incident_id,
        )


async def _reset_chaos() -> None:
    """Return the cluster to baseline. Called before each trigger."""
    if not APPLY_CHAOS:
        return
    await _run_chaos_script(CHAOS_RESET)


# ---------------------------------------------------------------------------
# Aggregate metrics
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


def compute_aggregate_metrics() -> dict[str, Any]:
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
        "avg_cost_usd": round(total_cost / total, 6) if total > 0 else 0.0,
        "total_tokens": total_tokens,
        "avg_tokens": total_tokens // total if total > 0 else 0,
        "safety_violations": safety_violations,
        "per_incident": per_incident,
    }


# ---------------------------------------------------------------------------
# Incident context for the RCA judge
# ---------------------------------------------------------------------------


def build_incident_context(incident: dict[str, Any]) -> list[str]:
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
# Judge
# ---------------------------------------------------------------------------


def _judge_config() -> tuple[str, str | None, str]:
    """Return (model, base_url_or_None, api_key) for the DeepEval judge.

    Provider-agnostic: the model ID is passed through to LiteLLM
    verbatim. LiteLLM infers the provider from the ``<provider>/<model>``
    prefix.

    Default judge model is gemini-3.5-flash-lite (500 RPD free tier)
    to avoid competing with the agent for the gemini-3.8-flash quota
    (20 RPD free tier).
    """
    from autosre.config import get_settings

    settings = get_settings()
    judge = settings.eval

    # --- CHANGED: Default to Flash-Lite for higher quota ---
    model = judge.judge_model or "gemini/gemini-3.5-flash-lite"
    # --- END CHANGED ---

    key_secret = judge.judge_api_key or settings.llm.api_key
    api_key = (
        key_secret.get_secret_value()
        if key_secret is not None
        else os.getenv("AUTOSRE_LLM__API_KEY", "")
    )

    base_url = judge.judge_base_url

    return model, base_url, api_key


def build_judge() -> Any:
    """Build a DeepEval LiteLLM judge. Returns None when unavailable.

    Gemini 3 note: Google's documentation recommends leaving temperature
    at its default of 1.0. Setting it below 1.0 can cause looping or degrade
    reasoning performance. We therefore omit temperature and let LiteLLM/
    Gemini use the model default.

    Reasoning depth is controlled via LiteLLM's ``reasoning_effort``,
    which LiteLLM maps to Gemini 3's ``thinking_level``.
    """
    try:
        model, base_url, api_key = _judge_config()
    except Exception as exc:
        logger.warning("Judge config unavailable: %s", exc)
        return None

    if not api_key:
        logger.warning("Judge disabled: no API key resolved")
        return None

    try:
        from deepeval.models import LiteLLMModel
    except ImportError:
        logger.warning("deepeval is not installed; RCA tests will skip")
        return None

    kwargs: dict[str, Any] = {
        "model": model,
        "api_key": api_key,
        # Do not set temperature below Gemini 3's default of 1.0.
        # Google warns that lower values can cause looping or degraded
        # reasoning performance.
        "generation_kwargs": {
            "reasoning_effort": "low",
            "max_completion_tokens": 1024,
        },
    }
    if base_url is not None:
        kwargs["base_url"] = base_url

    try:
        return LiteLLMModel(**kwargs)
    except Exception as exc:
        logger.warning("Failed to build judge: %s", exc)
        return None


# ---------------------------------------------------------------------------
# Server availability
# ---------------------------------------------------------------------------


def check_server_available() -> bool:
    try:
        response = httpx.get(
            f"{AGENT_BASE_URL.rstrip('/')}/healthz",
            timeout=2.0,
        )
        return response.status_code == 200
    except Exception:
        return False


class RateLimitError(RuntimeError):
    """Raised when an LLM provider returns a retryable error and the
    retry budget is exhausted."""


def _extract_status_code(exc: BaseException) -> int | None:
    """Extract HTTP status code from an exception, if present."""
    status_code = getattr(exc, "status_code", None)
    if isinstance(status_code, int):
        return status_code

    response = getattr(exc, "response", None)
    if response is not None:
        response_status = getattr(response, "status_code", None)
        if isinstance(response_status, int):
            return response_status

    return None


_RETRYABLE_STATUS_CODES: frozenset[int] = frozenset({408, 429, 500, 502, 503, 504})


def is_retryable_error(exc: BaseException) -> bool:
    """Return True if the error warrants a retry with backoff.

    Matches HTTP status codes (429, 503, 500, etc.) and common
    provider error strings. Daily-quota errors are NOT retryable and
    are handled separately by ``is_daily_quota_error``.
    """
    if is_daily_quota_error(exc):
        return False

    status_code = _extract_status_code(exc)
    if status_code is not None and status_code in _RETRYABLE_STATUS_CODES:
        return True

    error_text = str(exc).lower()
    return (
        "rate limit" in error_text
        or "too many requests" in error_text
        or "service unavailable" in error_text
        or "overloaded" in error_text
        or "timeout" in error_text
        or "connection error" in error_text
    )


def is_daily_quota_error(exc: BaseException) -> bool:
    """Return True if the error indicates daily quota is depleted.

    Daily-quota errors should fast-fail: no amount of backoff will
    restore the bucket until the next reset.
    """
    error_text = str(exc)
    return any(pattern.search(error_text) for pattern in _DAILY_QUOTA_PATTERNS)


# Back-compat alias. The old name is retained so callers that imported
# ``is_rate_limit_error`` from earlier versions continue to work.
is_rate_limit_error = is_retryable_error


_RETRY_AFTER_RE = re.compile(
    r"try again in ([\d.]+)\s*s",
    re.IGNORECASE,
)


def parse_retry_after(error_text: str) -> float | None:
    """Extract the retry-after hint from a provider error body.

    Parses messages of the form "Please try again in X.Ys". Returns None
    when the pattern is absent so callers fall back to their own backoff.
    """
    match = _RETRY_AFTER_RE.search(error_text)
    if not match:
        return None

    try:
        return float(match.group(1))
    except TypeError, ValueError:
        return None


def _resolve_backoff_settings() -> tuple[float, float, int]:
    """Read backoff parameters from settings, falling back to defaults.

    Returns:
        (initial_backoff_seconds, max_backoff_seconds, max_retries)
    """
    try:
        from autosre.config import get_settings

        settings = get_settings()
        return (
            settings.llm.initial_backoff_seconds,
            settings.llm.max_backoff_seconds,
            settings.llm.max_retries,
        )
    except Exception as exc:
        logger.warning("Could not read backoff settings; using defaults: %s", exc)
        return (2.0, 60.0, 5)


async def measure_metric_with_retry(
    metric: Any,
    test_case: Any,
    *,
    label: str = "judge",
    max_attempts: int | None = None,
    base_delay: float | None = None,
    max_delay: float | None = None,
) -> float:
    """Measure a DeepEval metric with exponential backoff on transient errors.

    Retries on HTTP 429, 500, 503, and other transient provider errors.
    Any non-retryable exception propagates immediately. Daily-quota
    errors (RPD exhausted) fast-fail as ``RateLimitError`` without retry.

    Backoff parameters default to ``settings.llm`` values so the judge
    shares the same transient-error policy as the agent. Override via
    kwargs for test isolation.

    The delay between attempts is:
        ``min(max_delay, base_delay * 2**attempt)``
    honored alongside any provider-supplied Retry-After hint.

    Args:
        metric: A DeepEval metric with an async ``a_measure`` method.
        test_case: The DeepEval test case.
        label: Human-readable identifier for logs.
        max_attempts: Total attempts before raising RateLimitError.
            Defaults to ``settings.llm.max_retries + 1``.
        base_delay: First backoff interval, in seconds.
            Defaults to ``settings.llm.initial_backoff_seconds``.
        max_delay: Upper bound on any single sleep, in seconds.
            Defaults to ``settings.llm.max_backoff_seconds``.

    Returns:
        The metric score as a finite float.

    Raises:
        RateLimitError: After max_attempts, so the caller can skip.
        Exception: Any non-retryable error, propagated unchanged.
    """
    settings_initial, settings_max, settings_retries = _resolve_backoff_settings()

    effective_initial = base_delay if base_delay is not None else settings_initial
    effective_max = max_delay if max_delay is not None else settings_max
    effective_attempts = max_attempts if max_attempts is not None else (settings_retries + 1)

    if effective_attempts <= 0:
        raise ValueError("max_attempts must be > 0")
    if effective_initial <= 0:
        raise ValueError("base_delay must be > 0")
    if effective_max <= 0:
        raise ValueError("max_delay must be > 0")

    last_error: BaseException | None = None

    for attempt in range(effective_attempts):
        try:
            score = await metric.a_measure(test_case)
            numeric = float(score)
            if not math.isfinite(numeric):
                raise AssertionError(f"{label}: metric score must be finite, got {numeric}")
            return numeric
        except Exception as exc:
            last_error = exc

            # Daily quota exhausted: fast-fail.
            if is_daily_quota_error(exc):
                raise RateLimitError(f"{label}: daily quota exhausted: {exc}") from exc

            # Non-retryable error: propagate immediately.
            if not is_retryable_error(exc):
                raise

            # Last attempt failed: budget exhausted.
            if attempt == effective_attempts - 1:
                break

            exp_delay = effective_initial * (2**attempt)

            hint = parse_retry_after(str(exc))
            if hint is not None:
                delay = min(max(exp_delay, hint + 1.0), effective_max)
            else:
                delay = min(exp_delay, effective_max)

            logger.warning(
                "%s transient error (attempt %d/%d); waiting %.1fs: %s",
                label,
                attempt + 1,
                effective_attempts,
                delay,
                exc,
            )
            await asyncio.sleep(delay)

    assert last_error is not None
    raise RateLimitError(
        f"{label} retries exhausted after {effective_attempts} attempts: {last_error}"
    )


# ---------------------------------------------------------------------------
# Rate-limit delay
# ---------------------------------------------------------------------------

_last_trigger_time: float = 0.0
_last_trigger_lock = threading.Lock()


async def _rate_limit_delay() -> None:
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

    def _sign(self, payload: bytes) -> str:
        digest = hmac.new(
            self.webhook_secret.encode("utf-8"),
            payload,
            hashlib.sha256,
        ).hexdigest()
        return f"sha256={digest}"

    @staticmethod
    def _json_object(response: httpx.Response) -> dict[str, Any]:
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

    async def trigger_incident(self, incident: dict[str, Any]) -> str:
        incident_id = incident["id"]

        description = (
            incident.get("description")
            or incident.get("alert_description")
            or incident.get("summary")
            or ""
        )

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

    async def get_incident_status(
        self,
        incident_id: str,
        *,
        timeout: float | None = None,
    ) -> dict[str, Any]:
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

    async def wait_for_completion(
        self,
        incident_id: str,
        poll_interval: float = 3.0,
        auto_approve: bool = AUTO_APPROVE,
    ) -> dict[str, Any]:
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
# Result validation helpers
# ---------------------------------------------------------------------------


def required_nonnegative_number(
    result: dict[str, Any],
    field: str,
) -> float:
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
# Incident runner with caching and chaos
# ---------------------------------------------------------------------------


async def run_incident(
    agent_client: AgentClient,
    incident: dict[str, Any],
    *,
    auto_approve: bool = AUTO_APPROVE,
) -> dict[str, Any]:
    """Trigger, wait, persist, and cache one incident's result.

    Order of operations:
        1. Session cache
        2. Disk cache (unless FORCE_RERUN)
        3. Reset chaos to baseline
        4. Apply the incident's chaos trigger
        5. Rate-limit delay
        6. Trigger the webhook
        7. Poll for completion
        8. Save result + populate session cache

    Chaos steps 3 and 4 are best-effort. If the toolkit is absent or a
    trigger fails, the eval runs against the healthy cluster and the
    agent will honestly report no_action.
    """
    incident_id = incident["id"]

    cached = _cache_get(incident_id)
    if cached is not None:
        logger.debug("Session cache hit for %s", incident_id)
        return cached

    if not FORCE_RERUN:
        disk_entry = load_result(incident_id)
        if disk_entry is not None:
            report = disk_entry.get("result")
            if isinstance(report, dict):
                _cache_put(incident_id, report)
                logger.debug("Disk cache hit for %s", incident_id)
                return report

    await _reset_chaos()
    await _apply_chaos_trigger(incident)
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
        if is_retryable_error(exc):
            pytest.skip(f"Transient error while evaluating {incident_id}: {exc}")
        raise


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def dataset() -> list[dict[str, Any]]:
    return _get_dataset()


@pytest.fixture
def agent_client() -> AgentClient:
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
    return build_judge()


# ---------------------------------------------------------------------------
# Collection hook
# ---------------------------------------------------------------------------


def pytest_collection_modifyitems(
    config: pytest.Config,
    items: list[pytest.Item],
) -> None:
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
    "RateLimitError",
    "RESULTS_DIR",
    "all_incident_ids",
    "build_incident_context",
    "build_judge",
    "check_server_available",
    "compute_aggregate_metrics",
    "incident_by_id",
    "incident_ids",
    "is_daily_quota_error",
    "is_rate_limit_error",
    "is_retryable_error",
    "load_all_results",
    "load_result",
    "measure_metric_with_retry",
    "parse_retry_after",
    "required_list_of_dicts",
    "required_nonnegative_int",
    "required_nonnegative_number",
    "run_incident",
    "save_result",
]
