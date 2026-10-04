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
investigate/hypothesize prompts on the worker tier. When both tiers
point to the same model (common on free tiers with uniform pricing),
the router still functions correctly as a pass-through.

Explicit overrides:
    "coordinator" / "auto"   Threshold-based routing
    "fast"                   Force the coordinator model
    "worker" / "slow"        Force the worker model
    <explicit model id>      Passed through unchanged

## Retry and backoff contract

Every physical HTTP call is counted in ``RunMetrics.llm_call_count``.
Transient errors (HTTP 429, 500, 503) trigger exponential backoff with
jitter. The sleep duration is recorded in ``RunMetrics.backoff_seconds``
so that ``complete_node`` can report honest active work time excluding
rate-limit waits.

Backoff strategy:
    - Attempts 0-2: linear (initial_backoff * (attempt + 1))
    - Attempts 3+: exponential (initial_backoff * 2^attempt)
    - All: capped at min(max_backoff, 30.0)
    - All: jitter up to 10% of base to prevent thundering herd
    - Retry-After header honored when present

Daily quota exhaustion (RPD) is detected and fast-fails without retry,
since no amount of backoff will restore a depleted daily bucket.

When consecutive failures exceed ``max_retries``, the router raises
``LLMBudgetExhaustedError``, which propagates out of ``acompletion``
and is handled by the graph node as a fatal incident error.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import re
from collections.abc import Mapping
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

Message = Mapping[str, Any]

# HTTP status codes that warrant a retry with backoff.
_RETRYABLE_STATUS_CODES: frozenset[int] = frozenset({408, 429, 500, 502, 503, 504})

# Substrings in error messages that indicate daily quota exhaustion.
# These should fast-fail rather than retry.
_DAILY_QUOTA_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"quota exceeded", re.IGNORECASE),
    re.compile(r"daily.*limit", re.IGNORECASE),
    re.compile(r"RPD", re.IGNORECASE),
    re.compile(r"requests per day", re.IGNORECASE),
    re.compile(r"resource has been exhausted", re.IGNORECASE),
    re.compile(r"exceeded your current quota", re.IGNORECASE),
)


class LLMBudgetExhaustedError(RuntimeError):
    """Raised when retries are exhausted or daily quota is depleted.

    Graph nodes must not retry on this exception; the incident should be
    marked failed and left for human investigation.
    """


# ---------------------------------------------------------------------------
# TokenVelocityRouter
# ---------------------------------------------------------------------------


class TokenVelocityRouter:
    """Select a model tier from estimated prompt size and dispatch to LiteLLM.

    Provider-agnostic pass-through. The configured model IDs are sent to
    LiteLLM verbatim.
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
            config: LLM settings including model IDs, pricing, and retry config.
            threshold_tokens: Input-token count above which the worker tier
                is selected. Must be > 0.
            encoder: Optional tiktoken-compatible encoder.
            max_llm_calls_per_incident: Hard budget on LLM calls per incident.
        """
        if threshold_tokens <= 0:
            raise ValueError("threshold_tokens must be greater than zero")

        self.config = config
        self.threshold_tokens = threshold_tokens

        self.api_key = self._secret_value(getattr(config, "api_key", None))
        self.base_url = getattr(config, "base_url", None)

        self.max_retries = config.max_retries
        self.initial_backoff = config.initial_backoff_seconds
        self.max_backoff = config.max_backoff_seconds
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

        logger.info(
            "TokenVelocityRouter initialized: fast=%s slow=%s "
            "threshold=%d max_retries=%d backoff=%.1fs..%.1fs max_calls=%d",
            self.fast_model,
            self.slow_model,
            self.threshold_tokens,
            self.max_retries,
            self.initial_backoff,
            self.max_backoff,
            self.max_llm_calls_per_incident,
        )

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
        alias = model.strip().lower()

        if alias in self.model_map:
            return self.model_map[alias]

        # Pass-through: no normalization.
        return model.strip()

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

    @staticmethod
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

    @classmethod
    def _is_retryable(cls, error: BaseException) -> bool:
        """Return True if the error warrants a retry with backoff."""
        status_code = cls._extract_status_code(error)
        if status_code is not None and status_code in _RETRYABLE_STATUS_CODES:
            return True

        error_text = str(error).lower()
        return (
            "rate limit" in error_text
            or "too many requests" in error_text
            or "service unavailable" in error_text
            or "overloaded" in error_text
            or "timeout" in error_text
            or "connection error" in error_text
        )

    @classmethod
    def _is_daily_quota_exhausted(cls, error: BaseException) -> bool:
        """Return True if the error indicates daily quota is depleted.

        Daily quota exhaustion should fast-fail: no amount of backoff
        will restore the bucket until the next reset.
        """
        error_text = str(error)
        return any(pattern.search(error_text) for pattern in _DAILY_QUOTA_PATTERNS)

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
                        return float(retry_after)
                    except TypeError, ValueError:
                        pass

        # Fall back to parsing the error message for "try again in X.Ys".
        match = re.search(r"try again in ([\d.]+)\s*s", str(error), re.IGNORECASE)
        if match:
            try:
                return float(match.group(1))
            except TypeError, ValueError:
                pass

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
        then exponential, capped at min(max_backoff, 30.0).

        Honors Retry-After header when present.
        """
        retry_after = self._extract_retry_after(error)

        if retry_after is not None:
            # Honor provider hint but cap at max_backoff.
            base = min(retry_after, self.max_backoff)
        else:
            # Linear backoff for first 3 attempts: initial * (attempt + 1)
            # Exponential after that: initial * 2^attempt
            if attempt < 3:
                raw = self.initial_backoff * (attempt + 1)
            else:
                raw = self.initial_backoff * (2**attempt)
            # Cap at max_backoff, then hard-cap at 30s.
            base = min(raw, self.max_backoff)
            base = min(base, 30.0)

        # Add jitter: up to 10% of the base duration to prevent thundering herd.
        jitter = random.uniform(0.0, base * 0.1)
        return base + jitter

    async def _call(
        self,
        model: str,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> Any:
        """Perform one physical LiteLLM call with retry and backoff.

        Raises:
            LLMBudgetExhaustedError: When retries are exhausted, daily
                quota is depleted, or per-incident call budget is exceeded.
            Exception: Non-retryable provider errors propagate unchanged.
        """
        # Enforce per-incident call budget.
        if (
            run_metrics is not None
            and run_metrics.llm_call_count >= self.max_llm_calls_per_incident
        ):
            raise LLMBudgetExhaustedError(
                f"Incident exceeded LLM call budget: "
                f"{run_metrics.llm_call_count}/{self.max_llm_calls_per_incident}"
            )

        call_kwargs = self._build_call_kwargs(kwargs)
        last_error: BaseException | None = None

        for attempt in range(self.max_retries + 1):
            if run_metrics is not None:
                run_metrics.record_llm_call()

            logger.debug(
                "Calling litellm.acompletion: model=%s messages=%d attempt=%d/%d",
                model,
                len(messages),
                attempt + 1,
                self.max_retries + 1,
            )

            try:
                response = await litellm.acompletion(
                    model=model,
                    messages=messages,
                    **call_kwargs,
                )
            except Exception as exc:
                last_error = exc

                if run_metrics is not None:
                    run_metrics.record_llm_failure()

                # Daily quota exhaustion: fast-fail.
                if self._is_daily_quota_exhausted(exc):
                    raise LLMBudgetExhaustedError(
                        f"Daily quota exhausted for {model}: {exc}"
                    ) from exc

                # Non-retryable error: propagate immediately.
                if not self._is_retryable(exc):
                    raise

                # Last attempt failed: budget exhausted.
                if attempt >= self.max_retries:
                    raise LLMBudgetExhaustedError(
                        f"LLM budget exhausted after {self.max_retries + 1} "
                        f"attempts for {model}. Last error: {exc}"
                    ) from exc

                # Backoff and retry.
                sleep_s = self._compute_backoff(attempt, exc)
                if run_metrics is not None:
                    run_metrics.record_backoff(sleep_s)

                logger.warning(
                    "LLM call to %s failed (attempt %d/%d): %s. Backing off %.2fs before retry.",
                    model,
                    attempt + 1,
                    self.max_retries + 1,
                    exc,
                    sleep_s,
                )

                await asyncio.sleep(sleep_s)
                continue

            # Success path.
            if run_metrics is not None:
                run_metrics.record_llm_success()

            self._log_usage(response, model)
            return response

        # Should be unreachable, but defensive.
        if last_error is not None:
            raise LLMBudgetExhaustedError(
                f"LLM budget exhausted for {model}. Last error: {last_error}"
            ) from last_error
        raise LLMBudgetExhaustedError(f"LLM budget exhausted for {model}")

    async def acompletion(
        self,
        messages: list[dict[str, Any]],
        model: str = "auto",
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> Any:
        """Call LiteLLM with automatic token routing and retry.

        Parameter order puts ``messages`` first so graph nodes can call
        ``acompletion(messages=..., response_format=...)`` without
        supplying a model; auto-routing is the default.
        """
        selected_model = self._resolve_model(model)

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
    ) -> Any:
        """Auto-routed call. Threshold decides fast vs worker per prompt size.

        Named for the coordinator stage (propose_node) but functionally
        equivalent to ``acompletion(model="auto")``.
        """
        return await self.acompletion(
            messages=messages,
            model="coordinator",
            run_metrics=run_metrics,
            **kwargs,
        )


__all__ = [
    "DEFAULT_TIKTOKEN_ENCODING",
    "DEFAULT_TOKEN_THRESHOLD",
    "LLMBudgetExhaustedError",
    "TokenVelocityRouter",
]
