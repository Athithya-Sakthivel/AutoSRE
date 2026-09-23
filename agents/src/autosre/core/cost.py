"""Cost calculation utilities for LLM token usage.

The calculator is intentionally small and provider-agnostic at the call site.
For Groq's supported prompt-caching models, ``prompt_tokens_details.cached_tokens``
contains the number of prompt tokens billed at the 50% cached-input rate.

Important: ``prompt_tokens`` is the total input-token count and therefore already
includes cached tokens. Cached tokens must be subtracted before applying the full
input-token price, then priced separately at the cached-input rate.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from autosre.config import LLMConfig

_CACHE_DISCOUNT = 0.5


def _usage_value(usage: Any, name: str, default: Any = None) -> Any:
    """Read a field from mapping-like or attribute-style usage objects."""
    if isinstance(usage, Mapping):
        return usage.get(name, default)
    return getattr(usage, name, default)


def _non_negative_int(value: Any) -> int:
    """Convert a usage value to a non-negative integer."""
    if value is None or isinstance(value, bool):
        return 0

    try:
        return max(0, int(value))
    except TypeError, ValueError, OverflowError:
        return 0


def _cached_prompt_tokens(usage: Any) -> int:
    """Extract Groq/OpenAI-compatible cached prompt tokens."""
    details = _usage_value(usage, "prompt_tokens_details")
    if details is None:
        return 0

    raw_cached = (
        details.get("cached_tokens", 0)
        if isinstance(details, Mapping)
        else getattr(details, "cached_tokens", 0)
    )
    return _non_negative_int(raw_cached)


def calculate_cost(
    usage: Any,
    model_name: str,
    config: LLMConfig | None,
) -> tuple[int, int, int, float]:
    """Calculate input/output cost from a LiteLLM usage object.

    Args:
        usage: LiteLLM usage object or mapping. ``prompt_tokens_details.cached_tokens``
            is read when present.
        model_name: The resolved model identifier returned by LiteLLM. It may be
            represented as a native Groq ID or with LiteLLM's ``groq/`` prefix.
        config: LLM configuration containing per-1K-token pricing. ``None`` keeps
            the token counts but returns zero cost, which is useful in tests.

    Returns:
        ``(prompt_tokens, completion_tokens, cached_tokens, cost_usd)``.
    """
    if usage is None:
        return 0, 0, 0, 0.0

    prompt_tokens = _non_negative_int(_usage_value(usage, "prompt_tokens", 0))
    completion_tokens = _non_negative_int(_usage_value(usage, "completion_tokens", 0))

    # Groq reports cached tokens inside prompt_tokens_details and those tokens are
    # included in prompt_tokens. Clamp defensively so malformed provider data can
    # never produce a negative uncached-token count or overcharge the request.
    cached_tokens = min(_cached_prompt_tokens(usage), prompt_tokens)

    if config is None:
        return prompt_tokens, completion_tokens, cached_tokens, 0.0

    if _is_coordinator_model(model_name, config):
        input_cost_per_1k = float(config.input_cost_per_1k_coordinator)
        output_cost_per_1k = float(config.output_cost_per_1k_coordinator)
    else:
        input_cost_per_1k = float(config.input_cost_per_1k_worker)
        output_cost_per_1k = float(config.output_cost_per_1k_worker)

    uncached_prompt_tokens = prompt_tokens - cached_tokens

    input_cost = (uncached_prompt_tokens / 1000.0) * input_cost_per_1k

    cached_input_cost = (cached_tokens / 1000.0) * input_cost_per_1k * _CACHE_DISCOUNT

    output_cost = (completion_tokens / 1000.0) * output_cost_per_1k

    total_cost = input_cost + cached_input_cost + output_cost

    return (
        prompt_tokens,
        completion_tokens,
        cached_tokens,
        round(total_cost, 6),
    )


def _canonical_model_id(model_name: Any) -> str:
    """Normalize a LiteLLM Groq model ID for comparison."""
    value = str(model_name or "").strip().lower()

    if value.startswith("groq/"):
        value = value[len("groq/") :]

    return value


def _is_coordinator_model(
    model_name: str,
    config: LLMConfig,
) -> bool:
    """Return whether ``model_name`` identifies the configured coordinator.

    The comparison accepts the common representations produced by this project:

        openai/gpt-oss-20b
        groq/openai/gpt-oss-20b

    The final path segment is also accepted for compatibility with older
    configuration that omitted the provider namespace.
    """
    coordinator = _canonical_model_id(config.model_coordinator)
    resolved = _canonical_model_id(model_name)

    if not coordinator or not resolved:
        return False

    if resolved == coordinator:
        return True

    return resolved.rsplit("/", 1)[-1] == coordinator.rsplit("/", 1)[-1]
