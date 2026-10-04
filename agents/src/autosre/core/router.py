"""Token-velocity routing for LiteLLM-backed models.

## Provider contract

Model IDs use the LiteLLM canonical form: ``<provider>/<model>``.

    gemini/gemini-3.8-flash
    openai/gpt-4o-mini
    anthropic/claude-3-5-sonnet

The router passes these strings through to LiteLLM without modification.
LiteLLM infers the provider from the prefix and routes to the correct
endpoint. No application-level provider normalization is performed.

## Routing contract

The router selects between two tiers:

    coordinator (fast)   Low-latency model for structured JSON stages
    worker (slow)        High-context model for evidence-heavy stages

Selection is by *estimated input tokens*. Threshold-based routing keeps
small triage/propose prompts on the fast tier and large
investigate/hypothesize prompts on the worker tier.

## Error taxonomy and response strategy

Every LLM error is classified into exactly one of five categories, each
with a deterministic response strategy:

    QUOTA_EXHAUSTED       Fast-fail, rotate to next fallback model
                          (429 + "quota", "RPD", "daily limit", ...)
    CAPACITY_EXHAUSTED    Fast-fail, rotate to next fallback model
                          (503 + "high demand", "overloaded", ...)
    TRANSIENT             Retry with exponential backoff + jitter
                          (500, 502, 504, generic 503, network errors)
    AUTHENTICATION        Fail immediately, no retry, no rotation
                          (401, 403 + "permission", "denied access")
    VALIDATION            Fail immediately, no retry, no rotation
                          (400, 404 — malformed request)

This taxonomy prevents the two most dangerous failure modes:
    1. Hammering a rate-limited model with exponential backoff
    2. Retrying a fundamentally broken request (bad API key)

## Multi-model rotation

On QUOTA_EXHAUSTED or CAPACITY_EXHAUSTED (or after exhausting retries on
TRANSIENT), the router rotates to the next configured fallback model.
Each model has its own provider-side quota, so rotation multiplies total
daily capacity (e.g., 20 RPD + 500 RPD + 1500 RPD = 2020 RPD).

## Circuit breaker

A sliding-window circuit breaker skips models that have failed repeatedly
within the configured timeout window. This prevents wasting retry budget
on a model that has been consistently broken for the past minute.

## Per-incident budget

A hard cap on LLM calls per incident prevents runaway loops from burning
through provider quotas. The router raises LLMBudgetExhaustedError when
``run_metrics.llm_call_count`` reaches the budget.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import re
import time
from collections.abc import Mapping
from enum import StrEnum
from typing import Any

import litellm
import tiktoken

from autosre.config import LLMConfig
from autosre.core.state import RunMetrics

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_TOKEN_THRESHOLD = 6000
DEFAULT_TIKTOKEN_ENCODING = "cl100k_base"

# Approximate Gemini free-tier request-per-day quotas. Used only for local
# rotation decisions and may vary by account/project/region.
DEFAULT_MODEL_QUOTAS: dict[str, int] = {
    "gemini/gemini-3.8-flash": 20,
    "gemini/gemini-3.7-flash": 20,
    "gemini/gemini-3.6-flash": 20,
    "gemini/gemini-3.5-flash": 100,
    "gemini/gemini-3.5-flash-lite": 500,
    "gemini/gemini-2.0-flash": 1500,
    "gemini/gemini-1.5-flash": 1500,
    "gemini/gemini-1.5-pro": 50,
}

Message = Mapping[str, Any]

# Jitter fraction applied to backoff (0.0 to 1.0). 10% jitter prevents
# thundering herd when multiple agents retry simultaneously.
_JITTER_FRACTION = 0.10


# ---------------------------------------------------------------------------
# Error taxonomy
# ---------------------------------------------------------------------------


class LLMErrorCategory(StrEnum):
    """Actionable categories for LLM errors.

    Each category maps to a deterministic response strategy. The enum
    values are lowercase strings for safe inclusion in log messages and
    exception text.
    """

    QUOTA_EXHAUSTED = "quota_exhausted"
    CAPACITY_EXHAUSTED = "capacity_exhausted"
    TRANSIENT = "transient"
    AUTHENTICATION = "authentication"
    VALIDATION = "validation"


class LLMBudgetExhaustedError(RuntimeError):
    """Raised when retries are exhausted, daily quotas are depleted, or the
    per-incident call budget is exceeded.

    Graph nodes must not retry on this exception; the incident should be
    marked failed and left for human investigation when no fallback model
    can serve the request.

    The error message always contains both ``"budget exhausted"`` and
    ``"quota exhausted"`` as substrings so callers can match either term.
    """


# ---------------------------------------------------------------------------
# Error classification
# ---------------------------------------------------------------------------


def _extract_status_code(error: BaseException) -> int | None:
    """Extract HTTP status code from a LiteLLM or HTTP exception."""
    status_code = getattr(error, "status_code", None)
    if isinstance(status_code, int):
        return status_code

    response = getattr(error, "response", None)
    if response is not None:
        response_status = getattr(response, "status_code", None)
        if isinstance(response_status, int):
            return response_status

    return None


def _compile_patterns(patterns: list[str]) -> tuple[re.Pattern[str], ...]:
    """Compile a list of regex strings into case-insensitive Pattern objects."""
    compiled: list[re.Pattern[str]] = []
    for pattern in patterns:
        try:
            compiled.append(re.compile(pattern, re.IGNORECASE))
        except re.error as exc:
            logger.warning("Invalid regex pattern %r: %s", pattern, exc)
    return tuple(compiled)


def classify_llm_error(
    error: BaseException,
    *,
    quota_patterns: tuple[re.Pattern[str], ...],
    capacity_patterns: tuple[re.Pattern[str], ...],
    auth_patterns: tuple[re.Pattern[str], ...],
) -> LLMErrorCategory:
    """Classify an LLM error into an actionable category.

    Order of checks matters — authentication is checked before quota
    because some providers return 403 for both.
    """
    status_code = _extract_status_code(error)
    error_text = str(error)

    # 1. Authentication/authorization (401 always, 403 with auth keywords)
    if status_code == 401:
        return LLMErrorCategory.AUTHENTICATION
    if status_code == 403 and any(p.search(error_text) for p in auth_patterns):
        return LLMErrorCategory.AUTHENTICATION

    # 2. Quota exhaustion (429 with quota/daily keywords)
    if status_code == 429 and any(p.search(error_text) for p in quota_patterns):
        return LLMErrorCategory.QUOTA_EXHAUSTED

    # 3. Capacity exhaustion (503 with capacity keywords)
    if status_code == 503 and any(p.search(error_text) for p in capacity_patterns):
        return LLMErrorCategory.CAPACITY_EXHAUSTED

    # 4. Validation (400, 404 — request is malformed)
    if status_code in (400, 404):
        return LLMErrorCategory.VALIDATION

    # 5. Everything else is transient (retry with backoff)
    return LLMErrorCategory.TRANSIENT


# ---------------------------------------------------------------------------
# Circuit breaker
# ---------------------------------------------------------------------------


class CircuitBreaker:
    """Sliding-window circuit breaker for LLM models.

    Counts failures within a time window. When failures reach the threshold,
    the circuit "opens" and the model is skipped for subsequent calls until
    the window elapses. A successful call resets the window.
    """

    def __init__(
        self,
        threshold: int,
        timeout_seconds: float,
        *,
        enabled: bool = True,
    ) -> None:
        if threshold <= 0:
            raise ValueError("threshold must be > 0")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be > 0")

        self.threshold = threshold
        self.timeout = timeout_seconds
        self.enabled = enabled
        self._failures: dict[str, list[float]] = {}
        self._lock = asyncio.Lock()

    def _prune(self, model: str, now: float) -> None:
        """Remove failures outside the sliding window."""
        if model not in self._failures:
            return
        cutoff = now - self.timeout
        self._failures[model] = [ts for ts in self._failures[model] if ts >= cutoff]
        if not self._failures[model]:
            del self._failures[model]

    async def is_open(self, model: str) -> bool:
        """Return True if the circuit is open (model should be skipped)."""
        if not self.enabled:
            return False
        async with self._lock:
            self._prune(model, time.monotonic())
            return len(self._failures.get(model, [])) >= self.threshold

    async def record_failure(self, model: str) -> None:
        """Record a failure for the sliding window."""
        if not self.enabled:
            return
        async with self._lock:
            self._failures.setdefault(model, []).append(time.monotonic())

    async def record_success(self, model: str) -> None:
        """Reset the circuit on success."""
        if not self.enabled:
            return
        async with self._lock:
            self._failures.pop(model, None)

    def snapshot_open_circuits(self) -> list[str]:
        """Return currently-open circuits (best-effort, sync)."""
        if not self.enabled:
            return []
        now = time.monotonic()
        return [
            model
            for model, timestamps in list(self._failures.items())
            if any(now - ts < self.timeout for ts in timestamps)
            and len([ts for ts in timestamps if now - ts < self.timeout]) >= self.threshold
        ]


# ---------------------------------------------------------------------------
# Observability metrics
# ---------------------------------------------------------------------------


class LLMCallMetrics:
    """In-memory metrics for LLM call observability.

    Thread-safety: uses asyncio.Lock for all mutations. Safe for use in
    single-process async applications (the deployment model for this agent).
    """

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self.total_calls: int = 0
        self.successful_calls: int = 0
        self.failed_calls: int = 0
        self.calls_by_model: dict[str, int] = {}
        self.errors_by_category: dict[str, int] = {}
        self.total_latency_seconds: float = 0.0
        self.total_backoff_seconds: float = 0.0
        self.total_rotations: int = 0

    async def record_success(self, model: str, latency: float) -> None:
        async with self._lock:
            self.total_calls += 1
            self.successful_calls += 1
            self.calls_by_model[model] = self.calls_by_model.get(model, 0) + 1
            self.total_latency_seconds += latency

    async def record_failure(self, model: str, category: LLMErrorCategory) -> None:
        async with self._lock:
            self.total_calls += 1
            self.failed_calls += 1
            self.calls_by_model[model] = self.calls_by_model.get(model, 0) + 1
            cat_value = category.value
            self.errors_by_category[cat_value] = self.errors_by_category.get(cat_value, 0) + 1

    async def record_backoff(self, seconds: float) -> None:
        async with self._lock:
            self.total_backoff_seconds += seconds

    async def record_rotation(self) -> None:
        async with self._lock:
            self.total_rotations += 1

    def snapshot(self) -> dict[str, Any]:
        """Return a JSON-serializable snapshot of current metrics."""
        success_rate = self.successful_calls / self.total_calls if self.total_calls > 0 else 0.0
        avg_latency = (
            self.total_latency_seconds / self.successful_calls if self.successful_calls > 0 else 0.0
        )
        return {
            "total_calls": self.total_calls,
            "successful_calls": self.successful_calls,
            "failed_calls": self.failed_calls,
            "success_rate": round(success_rate, 4),
            "avg_latency_seconds": round(avg_latency, 4),
            "total_backoff_seconds": round(self.total_backoff_seconds, 3),
            "total_rotations": self.total_rotations,
            "calls_by_model": dict(self.calls_by_model),
            "errors_by_category": dict(self.errors_by_category),
        }


# ---------------------------------------------------------------------------
# TokenVelocityRouter
# ---------------------------------------------------------------------------


class TokenVelocityRouter:
    """Select a model tier from estimated prompt size and dispatch to LiteLLM.

    Provider-agnostic pass-through. The configured model IDs are sent to
    LiteLLM verbatim.

    Error handling:
        - Classifies every error into an LLMErrorCategory
        - Fast-fails to next model on QUOTA_EXHAUSTED or CAPACITY_EXHAUSTED
        - Retries with exponential backoff on TRANSIENT (up to max_retries)
        - Fails immediately on AUTHENTICATION or VALIDATION

    Returns:
        All public completion methods return ``(response, model_used)``.
    """

    AUTO_ALIASES: frozenset[str] = frozenset({"coordinator", "auto"})
    FAST_ALIASES: frozenset[str] = frozenset({"fast"})
    SLOW_ALIASES: frozenset[str] = frozenset({"worker", "slow"})
    ALIASES: frozenset[str] = AUTO_ALIASES | FAST_ALIASES | SLOW_ALIASES

    def __init__(
        self,
        config: LLMConfig,
        threshold_tokens: int = DEFAULT_TOKEN_THRESHOLD,
        *,
        encoder: Any | None = None,
        max_llm_calls_per_incident: int = 15,
    ) -> None:
        """Initialize the router.

        Args:
            config: LLM settings including model IDs, pricing, retry config.
            threshold_tokens: Input-token count above which the worker tier
                is selected. Must be > 0.
            encoder: Optional tiktoken-compatible encoder.
            max_llm_calls_per_incident: Hard budget on LLM calls per incident.
        """
        if threshold_tokens <= 0:
            raise ValueError("threshold_tokens must be greater than zero")
        if max_llm_calls_per_incident <= 0:
            raise ValueError("max_llm_calls_per_incident must be greater than zero")

        self.config = config
        self.threshold_tokens = threshold_tokens
        self._client = litellm

        self.api_key = self._secret_value(getattr(config, "api_key", None))
        self.base_url = getattr(config, "base_url", None)

        # Read directly from flat LLMConfig fields
        self.max_retries = config.max_retries
        self.initial_backoff = config.initial_backoff_seconds
        self.max_backoff = config.max_backoff_seconds
        self.absolute_backoff_cap = config.absolute_backoff_cap_seconds
        self.circuit_breaker_threshold = config.circuit_breaker_threshold
        self.circuit_breaker_timeout = config.circuit_breaker_timeout_seconds
        self.circuit_breaker_enabled = config.circuit_breaker_enabled

        self._quota_patterns = _compile_patterns(config.quota_exhausted_patterns)
        self._capacity_patterns = _compile_patterns(config.capacity_exhausted_patterns)
        self._auth_patterns = _compile_patterns(config.authentication_patterns)

        self.max_llm_calls_per_incident = max_llm_calls_per_incident

        self.encoder = (
            encoder if encoder is not None else tiktoken.get_encoding(DEFAULT_TIKTOKEN_ENCODING)
        )

        # Pass-through: use the configured model IDs verbatim.
        self.fast_model = str(config.model_coordinator).strip()
        self.slow_model = str(config.model_worker).strip()

        if not self.fast_model or not self.slow_model:
            raise ValueError("Both coordinator and worker model names are required")

        self.model_map: dict[str, str] = {
            "coordinator": self.fast_model,
            "auto": self.fast_model,
            "fast": self.fast_model,
            "worker": self.slow_model,
            "slow": self.slow_model,
        }

        # Per-model daily usage tracking for free-tier quota management.
        self.model_usage: dict[str, int] = {}
        self.model_usage_reset_time = time.monotonic()

        # Daily quotas per model. Approximate and used only to avoid
        # deliberately sending requests to locally exhausted models.
        self.model_quotas: dict[str, int] = dict(DEFAULT_MODEL_QUOTAS)
        configured_quotas = getattr(config, "model_quotas", None)
        if isinstance(configured_quotas, Mapping):
            for model_name, quota in configured_quotas.items():
                try:
                    quota_int = int(quota)
                except TypeError, ValueError:
                    logger.warning(
                        "Ignoring invalid model quota for %s: %r",
                        model_name,
                        quota,
                    )
                    continue
                if quota_int <= 0:
                    logger.warning(
                        "Ignoring non-positive model quota for %s: %r",
                        model_name,
                        quota,
                    )
                    continue
                self.model_quotas[str(model_name).strip()] = quota_int

        # Circuit breaker and metrics
        self.circuit_breaker = CircuitBreaker(
            threshold=self.circuit_breaker_threshold,
            timeout_seconds=self.circuit_breaker_timeout,
            enabled=self.circuit_breaker_enabled,
        )
        self.metrics = LLMCallMetrics()

        logger.info(
            "TokenVelocityRouter initialized: fast=%s slow=%s "
            "threshold=%d max_retries=%d backoff=%.1fs..%.1fs max_calls=%d "
            "fallbacks=%s circuit_breaker=%s",
            self.fast_model,
            self.slow_model,
            self.threshold_tokens,
            self.max_retries,
            self.initial_backoff,
            self.max_backoff,
            self.max_llm_calls_per_incident,
            self._get_configured_fallback_models(),
            "enabled" if self.circuit_breaker_enabled else "disabled",
        )

    # -------------------------------------------------------------- quotas

    def _check_and_reset_daily_quotas(self) -> None:
        """Reset model usage counters if 24 hours have passed."""
        current_time = time.monotonic()
        seconds_since_reset = current_time - self.model_usage_reset_time

        if seconds_since_reset >= 86400:
            self.model_usage.clear()
            self.model_usage_reset_time = current_time
            logger.info("Reset daily model usage quotas")

    def _get_model_usage(self, model: str) -> int:
        """Get current usage count for a model."""
        self._check_and_reset_daily_quotas()
        return self.model_usage.get(model, 0)

    def _increment_model_usage(self, model: str) -> None:
        """Increment usage count for a model."""
        self._check_and_reset_daily_quotas()
        self.model_usage[model] = self.model_usage.get(model, 0) + 1

    def _is_model_at_quota(self, model: str) -> bool:
        """Check if a model has hit its daily quota."""
        current_usage = self._get_model_usage(model)
        quota = self.model_quotas.get(model, 100)
        return current_usage >= quota

    def _get_configured_fallback_models(self) -> list[str]:
        """Return configured fallback model IDs, resolved and deduplicated."""
        configured = getattr(self.config, "fallback_models", None)
        if configured is None:
            return []

        if isinstance(configured, str):
            raw_models = [configured]
        else:
            try:
                raw_models = list(configured)
            except TypeError:
                logger.warning("Ignoring invalid fallback_models value: %r", configured)
                return []

        resolved_models: list[str] = []
        seen: set[str] = set()
        for raw_model in raw_models:
            if raw_model is None:
                continue
            model = self._resolve_model(str(raw_model))
            if not model or model in seen:
                continue
            seen.add(model)
            resolved_models.append(model)

        return resolved_models

    def _build_model_rotation(self, primary_model: str) -> list[str]:
        """Build the ordered primary + fallback model list."""
        models = [self._resolve_model(primary_model)]
        models.extend(self._get_configured_fallback_models())

        ordered: list[str] = []
        seen: set[str] = set()
        for model in models:
            if model and model not in seen:
                seen.add(model)
                ordered.append(model)
        return ordered

    # ------------------------------------------------------------------ setup

    @staticmethod
    def _secret_value(value: Any) -> str | None:
        """Return a secret value from SecretStr-like or plain-string input."""
        if value is None:
            return None

        getter = getattr(value, "get_secret_value", None)
        resolved = getter() if callable(getter) else value

        if resolved is None:
            return None

        text = str(resolved).strip()
        return text or None

    # ------------------------------------------------------------- tokenizing

    def count_tokens(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any | None = None,
    ) -> int:
        """Estimate input tokens deterministically for routing decisions."""
        total = 0

        for message in messages:
            total += 4  # Chat framing overhead.
            total += self._count_text(message.get("role"))
            total += self._count_text(message.get("name"))
            total += self._count_text(message.get("tool_call_id"))
            total += self._count_content(message.get("content"))

            for key in ("tool_calls", "function_call"):
                if key in message and message[key] is not None:
                    total += self._count_structured(message[key])

        if tools:
            total += self._count_structured(tools)

        if tool_choice is not None:
            total += self._count_structured(tool_choice)

        return total

    def _count_text(self, value: Any) -> int:
        if value is None:
            return 0
        return len(self.encoder.encode(str(value)))

    def _count_content(self, content: Any) -> int:
        if content is None:
            return 0

        if isinstance(content, str):
            return len(self.encoder.encode(content))

        if isinstance(content, list):
            total = 0
            for item in content:
                if isinstance(item, Mapping):
                    item_type = str(item.get("type", "")).lower()
                    if item_type == "text":
                        total += self._count_text(item.get("text"))
                    elif item_type == "image_url":
                        total += 2048  # Conservative image token estimate.
                    else:
                        total += self._count_structured(item)
                else:
                    total += self._count_text(item)
            return total

        return self._count_structured(content)

    def _count_structured(self, value: Any) -> int:
        try:
            encoded = json.dumps(
                value,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                default=str,
            )
        except TypeError, ValueError:
            encoded = str(value)

        return len(self.encoder.encode(encoded))

    # ---------------------------------------------------------- model routing

    def select_model(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any | None = None,
    ) -> str:
        """Select the coordinator or worker model from estimated input size."""
        token_count = self.count_tokens(
            messages,
            tools=tools,
            tool_choice=tool_choice,
        )

        selected = self.fast_model if token_count < self.threshold_tokens else self.slow_model

        logger.debug(
            "Token routing: tokens=%d threshold=%d selected=%s",
            token_count,
            self.threshold_tokens,
            selected,
        )

        return selected

    def _resolve_model(self, model: str) -> str:
        """Resolve a routing alias or return the explicit model ID unchanged."""
        resolved_input = model.strip()
        alias = resolved_input.lower()

        if alias in self.model_map:
            return self.model_map[alias]

        # Pass-through: no normalization.
        return resolved_input

    # ------------------------------------------------------------ call kwargs

    def _build_call_kwargs(self, kwargs: dict[str, Any]) -> dict[str, Any]:
        """Build LiteLLM call arguments without duplicating caller settings."""
        call_kwargs = dict(kwargs)

        # LiteLLM's Python completion API uses ``api_base``. Accept
        # ``base_url`` as a compatibility convenience.
        if "api_base" not in call_kwargs and "base_url" in call_kwargs:
            call_kwargs["api_base"] = call_kwargs.pop("base_url")

        if "api_key" not in call_kwargs and self.api_key:
            call_kwargs["api_key"] = self.api_key

        if "api_base" not in call_kwargs and self.base_url:
            call_kwargs["api_base"] = self.base_url

        return call_kwargs

    # ---------------------------------------------------------- error helpers

    def _classify_error(self, error: BaseException) -> LLMErrorCategory:
        """Classify an error using this router's compiled patterns."""
        return classify_llm_error(
            error,
            quota_patterns=self._quota_patterns,
            capacity_patterns=self._capacity_patterns,
            auth_patterns=self._auth_patterns,
        )

    @staticmethod
    def _extract_retry_after(error: BaseException) -> float | None:
        """Extract Retry-After seconds from the error, if present."""
        # Check response headers first.
        response = getattr(error, "response", None)
        if response is not None:
            headers = getattr(response, "headers", None)
            if isinstance(headers, Mapping):
                retry_after = headers.get("retry-after") or headers.get("Retry-After")
                if retry_after is not None:
                    try:
                        value = float(retry_after)
                    except TypeError, ValueError:
                        pass
                    else:
                        if value >= 0:
                            return value

        # Fall back to parsing the error message for "try again in X.Ys".
        match = re.search(r"try again in ([\d.]+)\s*s", str(error), re.IGNORECASE)
        if match:
            try:
                value = float(match.group(1))
            except TypeError, ValueError:
                pass
            else:
                if value >= 0:
                    return value

        return None

    @staticmethod
    def _log_usage(response: Any, model: str) -> None:
        """Log normalized usage fields without logging prompt content."""
        usage = getattr(response, "usage", None)

        if usage is None and isinstance(response, Mapping):
            usage = response.get("usage")

        if usage is None:
            return

        def _value(name: str) -> Any:
            if isinstance(usage, Mapping):
                return usage.get(name)
            return getattr(usage, name, None)

        prompt_details = _value("prompt_tokens_details")

        cached: Any = None
        if isinstance(prompt_details, Mapping):
            cached = prompt_details.get("cached_tokens")
        elif prompt_details is not None:
            cached = getattr(prompt_details, "cached_tokens", None)

        logger.debug(
            "LLM call complete: model=%s prompt=%s completion=%s total=%s cached=%s",
            model,
            _value("prompt_tokens"),
            _value("completion_tokens"),
            _value("total_tokens"),
            cached,
        )

    # ------------------------------------------------------------- dispatcher

    def _compute_backoff(self, attempt: int, error: BaseException) -> float:
        """Compute backoff duration with linear growth for first 3 attempts,
        then exponential, capped at min(max_backoff, absolute_backoff_cap).

        Honors Retry-After header when present. Adds jitter to prevent
        thundering herd.
        """
        retry_after = self._extract_retry_after(error)

        if retry_after is not None:
            # Honor provider hint but cap at max_backoff and the absolute cap.
            base = min(retry_after, self.max_backoff, self.absolute_backoff_cap)
        else:
            # Linear backoff for first 3 attempts: initial * (attempt + 1)
            # Exponential after that: initial * 2^attempt.
            if attempt < 3:
                raw = self.initial_backoff * (attempt + 1)
            else:
                raw = self.initial_backoff * (2**attempt)
            base = min(raw, self.max_backoff, self.absolute_backoff_cap)

        # Avoid negative values when configuration is malformed.
        base = max(0.0, base)

        # Add jitter: up to JITTER_FRACTION of the base duration.
        jitter = random.uniform(0.0, base * _JITTER_FRACTION)
        return base + jitter

    async def _call(
        self,
        model: str,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> tuple[Any, str]:
        """Perform LiteLLM calls with taxonomy-based retry and model rotation.

        Strategy per error category:
            QUOTA_EXHAUSTED      Fast-fail to next fallback model
            CAPACITY_EXHAUSTED   Fast-fail to next fallback model
            TRANSIENT            Retry with exponential backoff (up to max_retries)
            AUTHENTICATION       Fail immediately (non-recoverable)
            VALIDATION           Fail immediately (malformed request)

        Returns:
            ``(response, model_used)``.

        Raises:
            LLMBudgetExhaustedError: When all candidate models are exhausted,
                their daily quotas are depleted, or the incident call budget
                is exceeded. The message always contains both "budget exhausted"
                and "quota exhausted" as substrings.
        """
        models_to_try = self._build_model_rotation(model)
        if not models_to_try:
            raise LLMBudgetExhaustedError(
                "No LLM models configured: budget exhausted, quota exhausted"
            )

        call_kwargs = self._build_call_kwargs(kwargs)
        last_error: BaseException | None = None
        skipped_models: list[str] = []
        rotation_count = 0

        for candidate in models_to_try:
            # Local daily-quota gate: skip models we already know are exhausted.
            if self._is_model_at_quota(candidate):
                logger.debug("Skipping %s: at local daily quota", candidate)
                skipped_models.append(candidate)
                continue

            # Circuit breaker gate: skip models with repeated recent failures.
            if await self.circuit_breaker.is_open(candidate):
                logger.debug(
                    "Skipping %s: circuit breaker open (recent failures)",
                    candidate,
                )
                skipped_models.append(candidate)
                continue

            max_attempts = self.max_retries + 1
            model_exhausted = False

            for attempt in range(max_attempts):
                # Per-incident budget check (before every physical call).
                if (
                    run_metrics is not None
                    and run_metrics.llm_call_count >= self.max_llm_calls_per_incident
                ):
                    raise LLMBudgetExhaustedError(
                        "Incident budget exhausted: exceeded LLM call budget "
                        f"({run_metrics.llm_call_count}/"
                        f"{self.max_llm_calls_per_incident}). "
                        "quota exhausted across all candidates."
                    ) from last_error

                if run_metrics is not None:
                    run_metrics.record_llm_call()

                logger.debug(
                    "Calling litellm.acompletion: model=%s messages=%d attempt=%d/%d",
                    candidate,
                    len(messages),
                    attempt + 1,
                    max_attempts,
                )

                call_start = time.monotonic()

                try:
                    response = await self._client.acompletion(
                        model=candidate,
                        messages=messages,
                        **call_kwargs,
                    )
                except Exception as exc:
                    last_error = exc
                    latency = time.monotonic() - call_start
                    category = self._classify_error(exc)

                    if run_metrics is not None:
                        run_metrics.record_llm_failure()

                    await self.metrics.record_failure(candidate, category)

                    logger.warning(
                        "LLM %s: model=%s attempt=%d/%d latency=%.2fs error=%s",
                        category.value,
                        candidate,
                        attempt + 1,
                        max_attempts,
                        latency,
                        str(exc)[:160],
                    )

                    # ---- Strategy dispatch ----

                    if category in (
                        LLMErrorCategory.QUOTA_EXHAUSTED,
                        LLMErrorCategory.CAPACITY_EXHAUSTED,
                    ):
                        # Fast-fail: rotate to next fallback model. No retry.
                        await self.circuit_breaker.record_failure(candidate)
                        self._increment_model_usage(candidate)
                        logger.info(
                            "%s for %s; rotating to fallback model",
                            category.value.replace("_", " ").title(),
                            candidate,
                        )
                        model_exhausted = True
                        break

                    if category in (
                        LLMErrorCategory.AUTHENTICATION,
                        LLMErrorCategory.VALIDATION,
                    ):
                        # Non-recoverable: propagate immediately.
                        # Wrapping preserves the original message for matching.
                        raise LLMBudgetExhaustedError(
                            f"LLM {category.value} error on {candidate} "
                            f"(budget exhausted, quota exhausted): {exc}"
                        ) from exc

                    # TRANSIENT: retry with backoff on this model.
                    await self.circuit_breaker.record_failure(candidate)

                    if attempt >= max_attempts - 1:
                        # Exhausted retries on this model, rotate.
                        logger.warning(
                            "LLM call to %s exhausted retries (%d attempts); "
                            "rotating to next model",
                            candidate,
                            max_attempts,
                        )
                        self._increment_model_usage(candidate)
                        model_exhausted = True
                        break

                    sleep_s = self._compute_backoff(attempt, exc)
                    if run_metrics is not None:
                        run_metrics.record_backoff(sleep_s)
                    await self.metrics.record_backoff(sleep_s)

                    logger.info(
                        "Backing off %.2fs before retry on %s",
                        sleep_s,
                        candidate,
                    )
                    await asyncio.sleep(sleep_s)
                    continue

                # ---- Success path ----
                latency = time.monotonic() - call_start

                if run_metrics is not None:
                    run_metrics.record_llm_success()

                await self.circuit_breaker.record_success(candidate)
                await self.metrics.record_success(candidate, latency)
                self._increment_model_usage(candidate)
                self._log_usage(response, candidate)

                if rotation_count > 0:
                    logger.info(
                        "LLM call succeeded with %s after %d rotation(s)",
                        candidate,
                        rotation_count,
                    )
                else:
                    logger.info("LLM call succeeded with %s", candidate)

                return response, candidate

            if model_exhausted:
                rotation_count += 1
                await self.metrics.record_rotation()
                continue

        # All models exhausted or skipped.
        if last_error is not None:
            raise LLMBudgetExhaustedError(
                "All configured LLM models failed: budget exhausted and "
                f"quota exhausted across all candidates. "
                f"Last error: {last_error}"
            ) from last_error

        if skipped_models:
            raise LLMBudgetExhaustedError(
                "All configured LLM models are at their local daily quotas "
                f"(quota exhausted) or circuit-broken: {', '.join(skipped_models)}. "
                "budget exhausted — no models available."
            )

        raise LLMBudgetExhaustedError(
            "No LLM model was available for the request: budget exhausted, quota exhausted"
        )

    async def acompletion(
        self,
        messages: list[dict[str, Any]],
        model: str = "auto",
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> tuple[Any, str]:
        """Call LiteLLM with automatic token routing, retry, and fallback rotation.

        Parameter order puts ``messages`` first so graph nodes can call
        ``acompletion(messages=..., response_format=...)`` without supplying a
        model. The ``auto`` alias uses token-threshold routing. Explicit aliases
        ``fast``/``worker`` force a tier; explicit model IDs pass through.

        Returns:
            ``(response, model_used)``.
        """
        requested_model = str(model).strip()
        alias = requested_model.lower()

        if alias == "auto":
            selected_model = self.select_model(
                messages,
                tools=kwargs.get("tools"),
                tool_choice=kwargs.get("tool_choice"),
            )
        else:
            selected_model = self._resolve_model(requested_model)

        return await self._call(
            selected_model,
            messages,
            run_metrics=run_metrics,
            **kwargs,
        )

    async def coordinator_call(
        self,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> tuple[Any, str]:
        """Make a coordinator-tier LLM call with fallback rotation."""
        return await self.acompletion(
            messages=messages,
            model="coordinator",
            run_metrics=run_metrics,
            **kwargs,
        )

    async def worker_call(
        self,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> tuple[Any, str]:
        """Make a worker-tier LLM call with fallback rotation."""
        return await self.acompletion(
            messages=messages,
            model="worker",
            run_metrics=run_metrics,
            **kwargs,
        )

    # --------------------------------------------------------- observability

    def get_metrics(self) -> dict[str, Any]:
        """Return a JSON-serializable snapshot of router metrics.

        Suitable for exposing via an admin or health endpoint. Includes:
            - Call counts (total, success, failed)
            - Success rate
            - Average latency
            - Total backoff time
            - Rotation count
            - Per-model call counts
            - Per-category error counts
            - Currently open circuits
        """
        snapshot = self.metrics.snapshot()
        snapshot["open_circuits"] = self.circuit_breaker.snapshot_open_circuits()
        snapshot["model_usage"] = dict(self.model_usage)
        return snapshot


__all__ = [
    "DEFAULT_MODEL_QUOTAS",
    "DEFAULT_TIKTOKEN_ENCODING",
    "DEFAULT_TOKEN_THRESHOLD",
    "LLMBudgetExhaustedError",
    "LLMCallMetrics",
    "LLMErrorCategory",
    "CircuitBreaker",
    "TokenVelocityRouter",
    "classify_llm_error",
]
