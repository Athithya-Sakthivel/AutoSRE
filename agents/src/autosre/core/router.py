"""Token-velocity routing for LiteLLM-backed Groq models.

## Provider contract

Groq's native API uses model IDs such as ``openai/gpt-oss-20b`` and
``qwen/qwen3.8-27b``. LiteLLM's Groq provider is selected by prefixing
the model with ``groq/``:

    groq/openai/gpt-oss-20b
    groq/qwen/qwen3.8-27b

This is different from calling Groq's OpenAI-compatible HTTP endpoint
directly, where the request model must remain ``openai/gpt-oss-20b``.
Do not force ``custom_llm_provider="openai"`` for native Groq calls.

Groq prompt caching is automatic on supported models and only benefits
exact prefix matches. Static system instructions and deterministically
ordered tool schemas must remain unchanged; dynamic incident data must
be appended after that stable prefix.

## Routing contract

The router selects between two tiers:

    coordinator (fast)   Low-latency model for structured JSON stages
    worker (slow)        High-context model for evidence-heavy stages

Selection is by *estimated input tokens*. Threshold-based routing keeps
small triage/propose prompts on the fast tier and large
investigate/hypothesize prompts on the worker tier.

Explicit overrides:
    "coordinator" / "auto"   Threshold-based routing
    "fast"                   Force the coordinator model
    "worker" / "slow"        Force the worker model
    <explicit model id>      Normalized and passed through

## Failure and budget contract

Every physical HTTP call is counted in ``RunMetrics.llm_call_count``.
Every failed call increments ``RunMetrics.llm_consecutive_failures``,
and every successful call resets it to 0. When the counter reaches
``max_consecutive_failures`` the router raises
``LLMBudgetExhaustedError``, which propagates out of ``acompletion``
and is handled by the graph node as a fatal incident error.

Rate-limit fallback (fast -> worker) is transparent. Rate-limit sleeps
are recorded in ``RunMetrics.backoff_seconds`` so that ``complete_node``
can report the honest active work time.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
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
DEFAULT_GROQ_BASE_URL = "https://api.groq.com/openai/v1"
DEFAULT_MAX_CONSECUTIVE_FAILURES = 3
DEFAULT_MAX_WORKER_ATTEMPTS = 3

Message = Mapping[str, Any]


class LLMBudgetExhaustedError(RuntimeError):
    """Raised when consecutive LLM failures exceed the configured budget.

    Indicates a persistent provider outage rather than a transient error.
    Graph nodes must not retry on this exception; the incident should be
    marked failed and left for human investigation.
    """


# ---------------------------------------------------------------------------
# TokenVelocityRouter
# ---------------------------------------------------------------------------


class TokenVelocityRouter:
    """Select a model tier from estimated prompt size and dispatch to LiteLLM.

    Aliases:

        coordinator / auto      Threshold-based routing
        fast                    Force the coordinator model
        worker / slow           Force the worker model

    When ``provider == "groq"``, configured model IDs are converted to the
    LiteLLM form ``groq/<native-groq-model-id>``. This preserves namespaces
    such as ``openai/`` inside the actual Groq model ID.
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
        fallback_on_rate_limit: bool = True,
        max_consecutive_failures: int = DEFAULT_MAX_CONSECUTIVE_FAILURES,
    ) -> None:
        """Initialize the router.

        Args:
            config: LLM settings including provider, model IDs, and pricing.
            threshold_tokens: Input-token count above which the worker tier
                is selected. Must be > 0.
            encoder: Optional tiktoken-compatible encoder. Defaults to
                cl100k_base.
            fallback_on_rate_limit: When True, auto-routed fast-tier calls
                that receive HTTP 429 retry on the worker tier.
            max_consecutive_failures: Number of consecutive failed physical
                calls after which ``LLMBudgetExhaustedError`` is raised.
        """
        if threshold_tokens <= 0:
            raise ValueError("threshold_tokens must be greater than zero")

        if max_consecutive_failures <= 0:
            raise ValueError("max_consecutive_failures must be greater than zero")

        self.config = config
        self.threshold_tokens = threshold_tokens
        self.max_consecutive_failures = max_consecutive_failures

        raw_provider = getattr(config.provider, "value", config.provider)
        self.provider = str(raw_provider).strip().lower()

        self.api_key = self._secret_value(getattr(config, "api_key", None))

        configured_base_url = getattr(config, "base_url", None)
        if configured_base_url:
            self.base_url: str | None = str(configured_base_url)
        elif self.provider == "groq":
            self.base_url = DEFAULT_GROQ_BASE_URL
        else:
            self.base_url = None

        self.fallback_on_rate_limit = fallback_on_rate_limit

        self.encoder = (
            encoder if encoder is not None else tiktoken.get_encoding(DEFAULT_TIKTOKEN_ENCODING)
        )

        self.fast_model = self._normalize_model(str(config.model_coordinator))
        self.slow_model = self._normalize_model(str(config.model_worker))

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
            "threshold=%d max_consecutive_failures=%d",
            self.fast_model,
            self.slow_model,
            self.threshold_tokens,
            self.max_consecutive_failures,
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

    def _normalize_model(self, model: str) -> str:
        """Normalize a model for the configured LiteLLM provider.

        For Groq:

            openai/gpt-oss-20b     -> groq/openai/gpt-oss-20b
            qwen/qwen3.8-27b       -> groq/qwen/qwen3.8-27b
            groq/openai/gpt-oss-20b -> unchanged

        Groq retired ``groq/compound`` and ``groq/compound-mini`` on
        2026-09-21, so this router rejects those legacy IDs instead of
        carrying a dead fallback path into production.
        """
        model = model.strip()

        if not model or self.provider != "groq":
            return model

        lower = model.lower()

        if lower in {
            "compound",
            "compound-mini",
            "groq/compound",
            "groq/compound-mini",
        }:
            raise ValueError(
                "Groq Compound models were retired on 2026-09-21; "
                "configure an active Groq model instead"
            )

        if lower.startswith("groq/"):
            return model

        if "/" not in model:
            raise ValueError(
                f"Groq model names must use the canonical provider/model form, got {model!r}"
            )

        return f"groq/{model}"

    # ------------------------------------------------------------- tokenizing

    def count_tokens(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any | None = None,
    ) -> int:
        """Estimate input tokens deterministically for routing decisions.

        Includes message fields, structured tool-call data, tool schemas,
        image inputs, and lightweight chat framing. Excludes predicted
        output tokens because routing is based on input context size.
        """
        total = 0

        for message in messages:
            # Approximate chat-message framing.
            total += 4

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
                        # Groq documents 2048 input tokens per image for
                        # Qwen 3.8 27B. Do not also count the URL as text.
                        total += 2048
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
        """Resolve a routing alias or normalize an explicit model ID."""
        alias = model.strip().lower()

        if alias in self.model_map:
            return self.model_map[alias]

        return self._normalize_model(model)

    # ------------------------------------------------------------ call kwargs

    def _build_call_kwargs(self, kwargs: dict[str, Any]) -> dict[str, Any]:
        """Build LiteLLM call arguments without duplicating caller settings.

        LiteLLM's Python completion API uses ``api_base``. Accept
        ``base_url`` as a compatibility convenience but never pass both
        names to LiteLLM.
        """
        call_kwargs = dict(kwargs)

        if "api_base" not in call_kwargs and "base_url" in call_kwargs:
            call_kwargs["api_base"] = call_kwargs.pop("base_url")

        if "api_key" not in call_kwargs and self.api_key:
            call_kwargs["api_key"] = self.api_key

        if "api_base" not in call_kwargs and self.base_url:
            call_kwargs["api_base"] = self.base_url

        return call_kwargs

    # ---------------------------------------------------------- error helpers

    @staticmethod
    def _is_rate_limit_error(error: BaseException) -> bool:
        """Return True for a provider/LiteLLM 429 rate-limit failure."""
        status_code = getattr(error, "status_code", None)
        if status_code == 429:
            return True

        response = getattr(error, "response", None)
        response_status = getattr(response, "status_code", None)
        if response_status == 429:
            return True

        text = str(error).lower()

        return (
            "rate limit" in text
            or "too many requests" in text
            or "status code 429" in text
            or "http 429" in text
        )

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

        if isinstance(prompt_details, Mapping):
            cached = prompt_details.get("cached_tokens")
        else:
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

    async def _call(
        self,
        model: str,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> Any:
        """Perform one physical LiteLLM call and record its outcome.

        Raises:
            LLMBudgetExhaustedError: When this failure pushes the
                consecutive-failure counter over the configured limit.
            Exception: The original provider error, on any other failure.
        """
        call_kwargs = self._build_call_kwargs(kwargs)

        if run_metrics is not None:
            run_metrics.record_llm_call()

        logger.debug(
            "Calling litellm.acompletion: model=%s messages=%d kwargs=%s",
            model,
            len(messages),
            sorted(call_kwargs.keys()),
        )

        try:
            response = await litellm.acompletion(
                model=model,
                messages=messages,
                **call_kwargs,
            )
        except Exception as exc:
            if run_metrics is not None:
                run_metrics.record_llm_failure()
                if run_metrics.llm_consecutive_failures >= self.max_consecutive_failures:
                    raise LLMBudgetExhaustedError(
                        "LLM budget exhausted: "
                        f"{run_metrics.llm_consecutive_failures} consecutive "
                        f"failures (limit="
                        f"{self.max_consecutive_failures}). "
                        f"Last error: {exc}"
                    ) from exc
            raise

        if run_metrics is not None:
            run_metrics.record_llm_success()

        self._log_usage(response, model)
        return response

    async def acompletion(
        self,
        messages: list[dict[str, Any]],
        model: str = "auto",
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> Any:
        """Call LiteLLM with automatic token routing and rate-limit fallback.

        Parameter order puts ``messages`` first so graph nodes can call
        ``acompletion(messages=..., response_format=...)`` without
        supplying a model; auto-routing is the default.

        Rate-limit fallback:

            Auto-routed fast-tier requests that receive HTTP 429 retry
            immediately on the worker tier. Worker retries use exponential
            backoff up to ``DEFAULT_MAX_WORKER_ATTEMPTS`` attempts before
            re-raising. Every sleep is recorded in ``RunMetrics`` so the
            incident's reported active time excludes it.
        """
        requested_model = model.strip().lower()

        if requested_model in self.AUTO_ALIASES:
            selected_model = self.select_model(
                messages,
                tools=kwargs.get("tools"),
                tool_choice=kwargs.get("tool_choice"),
            )
            auto_routed = True

        elif requested_model in (self.FAST_ALIASES | self.SLOW_ALIASES):
            selected_model = self._resolve_model(requested_model)
            auto_routed = False

        else:
            selected_model = self._resolve_model(model)
            auto_routed = False

        try:
            return await self._call(
                selected_model,
                messages,
                run_metrics=run_metrics,
                **kwargs,
            )

        except LLMBudgetExhaustedError:
            # Budget exhaustion is fatal and must not trigger fallback.
            raise

        except Exception as exc:
            can_fallback = (
                auto_routed
                and self.fallback_on_rate_limit
                and selected_model == self.fast_model
                and self.fast_model != self.slow_model
                and self._is_rate_limit_error(exc)
            )

            if not can_fallback:
                logger.error(
                    "LLM call failed: model=%s error=%s",
                    selected_model,
                    exc,
                    exc_info=True,
                )
                raise

            logger.warning(
                "Fast model rate-limited; switching immediately to worker model=%s",
                self.slow_model,
            )

            last_exc: Exception = exc

            for attempt in range(DEFAULT_MAX_WORKER_ATTEMPTS):
                if run_metrics is not None:
                    run_metrics.llm_retry_count += 1

                try:
                    return await self._call(
                        self.slow_model,
                        messages,
                        run_metrics=run_metrics,
                        **kwargs,
                    )

                except LLMBudgetExhaustedError:
                    raise

                except Exception as worker_exc:
                    if not self._is_rate_limit_error(worker_exc):
                        logger.error(
                            "LLM call failed: model=%s error=%s",
                            self.slow_model,
                            worker_exc,
                            exc_info=True,
                        )
                        raise

                    last_exc = worker_exc

                    if attempt == DEFAULT_MAX_WORKER_ATTEMPTS - 1:
                        break

                    # Default exponential backoff:
                    # attempt 0 -> 30s, attempt 1 -> 60s
                    wait_seconds: float = 30.0 * (2**attempt)

                    # Respect a larger provider-supplied delay when present.
                    error_str = str(worker_exc).lower()
                    match = re.search(r"try again in ([\d.]+)s", error_str)

                    if match:
                        with contextlib.suppress(ValueError):
                            wait_seconds = max(
                                wait_seconds,
                                float(match.group(1)) + 1.0,
                            )

                    if run_metrics is not None:
                        run_metrics.record_backoff(wait_seconds)

                    logger.warning(
                        "Worker model rate-limited (attempt %d/%d). Waiting %.1fs before retry...",
                        attempt + 1,
                        DEFAULT_MAX_WORKER_ATTEMPTS,
                        wait_seconds,
                    )

                    await asyncio.sleep(wait_seconds)

            raise last_exc from None

    async def coordinator_call(
        self,
        messages: list[dict[str, Any]],
        *,
        run_metrics: RunMetrics | None = None,
        **kwargs: Any,
    ) -> Any:
        """Auto-routed call. Threshold decides fast vs worker per prompt size.

        Named for the coordinator stage (propose_node) but functionally
        equivalent to ``acompletion(model="auto")``. Kept as a distinct
        method so the graph reads as intent, not mechanism.
        """
        return await self.acompletion(
            messages=messages,
            model="coordinator",
            run_metrics=run_metrics,
            **kwargs,
        )


__all__ = [
    "DEFAULT_GROQ_BASE_URL",
    "DEFAULT_MAX_CONSECUTIVE_FAILURES",
    "DEFAULT_MAX_WORKER_ATTEMPTS",
    "DEFAULT_TIKTOKEN_ENCODING",
    "DEFAULT_TOKEN_THRESHOLD",
    "LLMBudgetExhaustedError",
    "TokenVelocityRouter",
]
