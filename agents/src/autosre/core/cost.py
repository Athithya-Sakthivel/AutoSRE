"""Cost calculation utilities for LLM token usage.

Provider-agnostic calculator. Reads standard OpenAI-compatible usage
objects (``prompt_tokens``, ``completion_tokens``) and applies per-1K
rates from the LLMConfig.

On free tiers (Gemini, etc.), the configured rates may be 0.0. The
calculator handles zero-cost gracefully without division-by-zero errors.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from autosre.config import LLMConfig


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
    """Extract cached prompt tokens from an OpenAI-compatible usage object.

    Returns 0 when the provider does not report cached tokens (common
    on free tiers or providers without prompt caching).
    """
    details = _usage_value(usage, "prompt_tokens_details")
    if details is None:
        return 0

    raw_cached: Any
    if isinstance(details, Mapping):
        raw_cached = details.get("cached_tokens", 0)
    else:
        raw_cached = getattr(details, "cached_tokens", 0)

    return _non_negative_int(raw_cached)


def calculate_cost(
    usage: Any,
    model_name: str,
    config: LLMConfig | None,
) -> tuple[int, int, int, float]:
    """Calculate input/output cost from a LiteLLM usage object.

    Args:
        usage: LiteLLM usage object or mapping.
        model_name: The resolved model identifier returned by LiteLLM.
        config: LLM configuration containing per-1K-token pricing.
            ``None`` keeps the token counts but returns zero cost.

    Returns:
        ``(prompt_tokens, completion_tokens, cached_tokens, cost_usd)``.
    """
    if usage is None:
        return 0, 0, 0, 0.0

    prompt_tokens = _non_negative_int(_usage_value(usage, "prompt_tokens", 0))
    completion_tokens = _non_negative_int(_usage_value(usage, "completion_tokens", 0))

    # Defensively clamp cached tokens to not exceed total prompt tokens.
    cached_tokens = min(_cached_prompt_tokens(usage), prompt_tokens)

    if config is None:
        return prompt_tokens, completion_tokens, cached_tokens, 0.0

    if _is_coordinator_model(model_name, config):
        input_cost_per_1k = float(config.input_cost_per_1k_coordinator)
        output_cost_per_1k = float(config.output_cost_per_1k_coordinator)
    else:
        input_cost_per_1k = float(config.input_cost_per_1k_worker)
        output_cost_per_1k = float(config.output_cost_per_1k_worker)

    # On free tiers, both rates are 0.0. The math still works: 0 * N = 0.
    # Cached tokens are priced the same as uncached tokens on most
    # providers; override this in config if your provider offers a
    # cache discount.
    uncached_prompt_tokens = prompt_tokens - cached_tokens

    input_cost = (uncached_prompt_tokens / 1000.0) * input_cost_per_1k
    cached_input_cost = (cached_tokens / 1000.0) * input_cost_per_1k
    output_cost = (completion_tokens / 1000.0) * output_cost_per_1k

    total_cost = input_cost + cached_input_cost + output_cost

    return (
        prompt_tokens,
        completion_tokens,
        cached_tokens,
        round(total_cost, 6),
    )


def _canonical_model_id(model_name: Any) -> str:
    """Normalize a LiteLLM model ID for comparison.

    Strips whitespace and lowercases for case-insensitive matching.
    Provider-agnostic: does not strip any specific prefix.
    """
    return str(model_name or "").strip().lower()


def _is_coordinator_model(
    model_name: str,
    config: LLMConfig,
) -> bool:
    """Return whether ``model_name`` identifies the configured coordinator.

    Accepts any provider prefix. Compares the full canonical ID first,
    then falls back to comparing the final path segment for robustness
    against provider-prefix drift.
    """
    coordinator = _canonical_model_id(config.model_coordinator)
    resolved = _canonical_model_id(model_name)

    if not coordinator or not resolved:
        return False

    if resolved == coordinator:
        return True

    # Fallback: compare the model portion after the last slash.
    return resolved.rsplit("/", 1)[-1] == coordinator.rsplit("/", 1)[-1]


__all__ = ["calculate_cost"]
