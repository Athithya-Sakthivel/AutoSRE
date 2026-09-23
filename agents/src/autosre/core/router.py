"""Token-velocity routing for LiteLLM-backed Groq models.

Groq's native API uses model IDs such as ``openai/gpt-oss-20b`` and
``qwen/qwen3.8-27b``. LiteLLM's Groq provider is selected by prefixing the model
with ``groq/``; for example:

    groq/openai/gpt-oss-20b
    groq/qwen/qwen3.8-27b

This is different from calling Groq's OpenAI-compatible HTTP endpoint directly,
where the request model must remain ``openai/gpt-oss-20b``. Do not force
``custom_llm_provider="openai"`` for native Groq calls.

Groq prompt caching is automatic on supported models and only benefits exact
prefix matches. Static system instructions and deterministically ordered tool
schemas should remain unchanged; dynamic incident data should be appended after
that stable prefix.
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

logger = logging.getLogger(__name__)

DEFAULT_TOKEN_THRESHOLD = 6000
DEFAULT_TIKTOKEN_ENCODING = "cl100k_base"
DEFAULT_GROQ_BASE_URL = "https://api.groq.com/openai/v1"

Message = Mapping[str, Any]


class TokenVelocityRouter:
    """Select a configured model tier from estimated prompt size.

    Routing aliases:

        coordinator / auto
            Threshold-based routing.

        fast
            Force the coordinator model.

        worker / slow
            Force the worker model.

    When ``provider == "groq"``, configured model IDs are converted to the
    LiteLLM form ``groq/<native-groq-model-id>``. This preserves namespaces such
    as ``openai/`` inside the actual Groq model ID.
    """

    AUTO_ALIASES = frozenset({"coordinator", "auto"})
    FAST_ALIASES = frozenset({"fast"})
    SLOW_ALIASES = frozenset({"worker", "slow"})
    ALIASES = AUTO_ALIASES | FAST_ALIASES | SLOW_ALIASES

    def __init__(
        self,
        config: LLMConfig,
        threshold_tokens: int = DEFAULT_TOKEN_THRESHOLD,
        *,
        encoder: Any | None = None,
        fallback_on_rate_limit: bool = True,
    ) -> None:
        if threshold_tokens <= 0:
            raise ValueError("threshold_tokens must be greater than zero")

        self.config = config
        self.threshold_tokens = threshold_tokens

        raw_provider = getattr(
            config.provider,
            "value",
            config.provider,
        )
        self.provider = str(raw_provider).strip().lower()

        self.api_key = self._secret_value(getattr(config, "api_key", None))

        configured_base_url = getattr(config, "base_url", None)

        self.base_url: str | None

        if configured_base_url:
            self.base_url = str(configured_base_url)
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

        self.model_map = {
            "coordinator": self.fast_model,
            "auto": self.fast_model,
            "fast": self.fast_model,
            "worker": self.slow_model,
            "slow": self.slow_model,
        }

        logger.info(
            "TokenVelocityRouter initialized: fast=%s slow=%s threshold=%d",
            self.fast_model,
            self.slow_model,
            self.threshold_tokens,
        )

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

            openai/gpt-oss-20b
                -> groq/openai/gpt-oss-20b

            qwen/qwen3.8-27b
                -> groq/qwen/qwen3.8-27b

            groq/openai/gpt-oss-20b
                -> unchanged

        Groq retired ``groq/compound`` and ``groq/compound-mini`` on
        2026-09-21, so this router rejects those legacy IDs instead of carrying a
        dead fallback path into production.
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

    def count_tokens(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any | None = None,
    ) -> int:
        """Estimate input tokens deterministically for routing decisions.

        The estimate includes message fields, structured tool-call data, tool
        schemas, image inputs, and lightweight chat framing. It intentionally
        excludes predicted output tokens because routing is based on input
        context size.
        """
        total = 0

        for message in messages:
            # Approximate chat-message framing.
            total += 4

            total += self._count_text(message.get("role"))
            total += self._count_text(message.get("name"))
            total += self._count_text(message.get("tool_call_id"))
            total += self._count_content(message.get("content"))

            for key in (
                "tool_calls",
                "function_call",
            ):
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

    def _build_call_kwargs(
        self,
        kwargs: dict[str, Any],
    ) -> dict[str, Any]:
        """Build LiteLLM call arguments without duplicating caller settings."""
        call_kwargs = dict(kwargs)

        # LiteLLM's Python completion API uses api_base. Accept base_url as a
        # compatibility convenience because the project config may expose that
        # spelling, but never pass both names to LiteLLM.
        if "api_base" not in call_kwargs and "base_url" in call_kwargs:
            call_kwargs["api_base"] = call_kwargs.pop("base_url")

        if "api_key" not in call_kwargs and self.api_key:
            call_kwargs["api_key"] = self.api_key

        if "api_base" not in call_kwargs and self.base_url:
            call_kwargs["api_base"] = self.base_url

        # Native Groq models are selected by the groq/ provider prefix in the
        # model string. Do not force custom_llm_provider="openai".
        return call_kwargs

    @staticmethod
    def _is_rate_limit_error(
        error: BaseException,
    ) -> bool:
        """Return True for a provider/LiteLLM 429 rate-limit failure."""
        status_code = getattr(
            error,
            "status_code",
            None,
        )

        if str(status_code) == "429":
            return True

        response = getattr(
            error,
            "response",
            None,
        )

        response_status = getattr(
            response,
            "status_code",
            None,
        )

        if str(response_status) == "429":
            return True

        text = str(error).lower()

        return (
            "rate limit" in text
            or "too many requests" in text
            or "status code 429" in text
            or "http 429" in text
        )

    @staticmethod
    def _log_usage(
        response: Any,
        model: str,
    ) -> None:
        """Log normalized usage fields without logging prompt content."""
        usage = getattr(
            response,
            "usage",
            None,
        )

        if usage is None and isinstance(response, Mapping):
            usage = response.get("usage")

        if usage is None:
            return

        def value(name: str) -> Any:
            if isinstance(usage, Mapping):
                return usage.get(name)

            return getattr(
                usage,
                name,
                None,
            )

        prompt_details = value("prompt_tokens_details")

        if isinstance(prompt_details, Mapping):
            cached = prompt_details.get("cached_tokens")
        else:
            cached = getattr(
                prompt_details,
                "cached_tokens",
                None,
            )

        logger.debug(
            "LLM call complete: model=%s prompt=%s completion=%s total=%s cached=%s",
            model,
            value("prompt_tokens"),
            value("completion_tokens"),
            value("total_tokens"),
            cached,
        )

    async def _call(
        self,
        model: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> Any:
        call_kwargs = self._build_call_kwargs(kwargs)

        logger.debug(
            "Calling litellm.acompletion: model=%s messages=%d kwargs=%s",
            model,
            len(messages),
            sorted(call_kwargs.keys()),
        )

        response = await litellm.acompletion(
            model=model,
            messages=messages,
            **call_kwargs,
        )

        self._log_usage(
            response,
            model,
        )

        return response

    async def acompletion(
        self,
        model: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> Any:
        """Call LiteLLM with automatic token routing and rate-limit fallback.

        ``coordinator``/``auto`` use the configured threshold; ``fast`` and
        ``worker``/``slow`` are explicit overrides.

        Automatically routed fast-tier requests that receive a rate-limit
        error immediately fall back to the worker tier. Rate-limited worker
        retries use exponential backoff before the final exception is raised.
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
                **kwargs,
            )

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

            # The worker is the fallback deployment. Preserve the existing
            # fast -> worker behavior expected by the router tests.
            max_worker_attempts = 3
            last_exc: Exception = exc

            for attempt in range(max_worker_attempts):
                try:
                    return await self._call(
                        self.slow_model,
                        messages,
                        **kwargs,
                    )

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

                    if attempt == max_worker_attempts - 1:
                        break

                    # Default exponential backoff:
                    # attempt 0 -> 30s
                    # attempt 1 -> 60s
                    wait_seconds: float = 30.0 * (2**attempt)

                    # Respect a larger provider-supplied delay when present.
                    error_str = str(worker_exc).lower()
                    match = re.search(
                        r"try again in ([\d.]+)s",
                        error_str,
                    )

                    if match:
                        with contextlib.suppress(ValueError):
                            wait_seconds = max(
                                wait_seconds,
                                float(match.group(1)) + 1.0,
                            )

                    logger.warning(
                        "Worker model rate-limited (attempt %d/%d). Waiting %.1fs before retry...",
                        attempt + 1,
                        max_worker_attempts,
                        wait_seconds,
                    )

                    await asyncio.sleep(wait_seconds)

            raise last_exc from None

    async def coordinator_call(
        self,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> Any:
        """Convenience wrapper for an auto-routed coordinator call."""
        return await self.acompletion(
            model="coordinator",
            messages=messages,
            **kwargs,
        )
