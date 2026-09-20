"""Token-velocity routing for Groq Qwen 3.8 27B and Compound.

The router estimates the input context size before an LLM call and routes
large prompts away from the lower-TPM model. Groq model IDs are sent through
LiteLLM's OpenAI-compatible transport so Compound keeps its exact Groq model
ID instead of being rewritten by LiteLLM's native Groq provider handling.
"""

from __future__ import annotations

import json
import logging
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
    """Select a fast or large-context model from estimated prompt size.

    ``coordinator``/``auto`` aliases perform token-based routing.
    ``fast`` and ``worker``/``slow`` aliases force a specific tier.

    For Groq, requests use LiteLLM's OpenAI-compatible transport with the
    Groq API base URL. This preserves exact Groq model IDs such as
    ``qwen/qwen3.8-27b`` and ``groq/compound``.
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
        self.provider = str(config.provider).strip().lower()
        self.api_key = self._secret_value(getattr(config, "api_key", None))
        self.base_url = getattr(config, "base_url", None) or (
            DEFAULT_GROQ_BASE_URL if self.provider == "groq" else None
        )
        self.fallback_on_rate_limit = fallback_on_rate_limit
        self.encoder = encoder or tiktoken.get_encoding(DEFAULT_TIKTOKEN_ENCODING)

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

        return str(resolved)

    def _normalize_model(self, model: str) -> str:
        """Normalize configured IDs without changing the Groq API model ID."""
        model = model.strip()

        if not model or self.provider != "groq":
            return model

        if model in {"compound", "compound-mini"}:
            return f"groq/{model}"

        if model.startswith("groq/"):
            suffix = model.removeprefix("groq/")

            if suffix in {"compound", "compound-mini"}:
                return model

            return suffix

        return model

    def count_tokens(
        self,
        messages: list[dict[str, Any]],
        *,
        tools: list[dict[str, Any]] | None = None,
        tool_choice: Any | None = None,
    ) -> int:
        """Estimate prompt tokens using a deterministic local tokenizer.

        The estimate includes message text, structured tool-call fields,
        tool definitions, and message-format overhead. It deliberately does
        not add a fake response-token allowance: routing is based on input
        context size, not predicted output size.
        """
        total = 0

        for message in messages:
            # Chat-message framing estimate.
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
                    item_type = item.get("type")

                    if item_type == "text":
                        total += self._count_text(item.get("text"))

                    elif item_type == "image_url":
                        # Groq documents Qwen image inputs as 2048 input
                        # tokens per image.
                        total += 2048
                        total += self._count_text(item.get("image_url"))

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
        """Select a tier from prompt size, with Compound tool compatibility."""
        token_count = self.count_tokens(
            messages,
            tools=tools,
            tool_choice=tool_choice,
        )

        if token_count < self.threshold_tokens:
            selected = self.fast_model

        elif tools and self.provider == "groq" and self._is_compound_model(self.slow_model):
            # Groq Compound does not accept customer-supplied function tools.
            # Keep tool-using requests on Qwen, which supports local tool use.
            selected = self.fast_model

            logger.warning(
                "Keeping tool-using request on fast model because Groq "
                "Compound does not support custom user-provided tools"
            )

        else:
            selected = self.slow_model

        logger.debug(
            "Token routing: tokens=%d threshold=%d selected=%s",
            token_count,
            self.threshold_tokens,
            selected,
        )

        return selected

    def _resolve_model(self, model: str) -> str:
        """Resolve a routing alias or normalize an explicit model ID."""
        if model in self.model_map:
            return self.model_map[model]

        return self._normalize_model(model)

    def _build_call_kwargs(self, kwargs: dict[str, Any]) -> dict[str, Any]:
        """Build LiteLLM call arguments without duplicating caller settings."""
        call_kwargs = dict(kwargs)

        # LiteLLM's current public completion signature uses base_url.
        if "api_base" in call_kwargs and "base_url" not in call_kwargs:
            call_kwargs["base_url"] = call_kwargs.pop("api_base")

        if "api_key" not in call_kwargs and self.api_key:
            call_kwargs["api_key"] = self.api_key

        if "base_url" not in call_kwargs and self.base_url:
            call_kwargs["base_url"] = self.base_url

        if self.provider == "groq":
            # Deliberately use the OpenAI-compatible transport. This prevents
            # LiteLLM from rewriting Groq Compound's exact model ID.
            call_kwargs.setdefault("custom_llm_provider", "openai")

        return call_kwargs

    @staticmethod
    def _is_compound_model(model: str) -> bool:
        return model.lower() in {
            "groq/compound",
            "groq/compound-mini",
        }

    @staticmethod
    def _is_rate_limit_error(error: BaseException) -> bool:
        if getattr(error, "status_code", None) == 429:
            return True

        text = str(error).lower()

        return "rate limit" in text or "too many requests" in text or "status code 429" in text

    @staticmethod
    def _log_usage(response: Any, model: str) -> None:
        usage = getattr(response, "usage", None)

        if usage is None:
            return

        def value(name: str) -> Any:
            if isinstance(usage, Mapping):
                return usage.get(name)

            return getattr(usage, name, None)

        logger.debug(
            "LLM call complete: model=%s prompt=%s completion=%s total=%s",
            model,
            value("prompt_tokens"),
            value("completion_tokens"),
            value("total_tokens"),
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

        self._log_usage(response, model)

        return response

    async def acompletion(
        self,
        model: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> Any:
        """Call LiteLLM with automatic token-based routing.

        ``coordinator``/``auto`` use the threshold. ``fast`` and
        ``worker``/``slow`` are explicit overrides. An auto-routed Qwen call
        that receives a 429 can be retried once on Compound when enabled.
        """
        if model in self.AUTO_ALIASES:
            selected_model = self.select_model(
                messages,
                tools=kwargs.get("tools"),
                tool_choice=kwargs.get("tool_choice"),
            )
            auto_routed = True

        elif model in self.FAST_ALIASES | self.SLOW_ALIASES:
            selected_model = self._resolve_model(model)
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
                and not kwargs.get("tools")
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
                "Fast model rate-limited; retrying once on worker model=%s",
                self.slow_model,
            )

            return await self._call(
                self.slow_model,
                messages,
                **kwargs,
            )

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
