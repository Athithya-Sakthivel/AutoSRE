"""Cost calculation utilities for LLM token usage.

Two entry points:

    calculate_cost(usage, model_name, config)
        -> (prompt_tokens, completion_tokens, cached_tokens, actual_cost, estimated_cost)

    calculate_cost_from_counts(prompt_tokens, completion_tokens, model, config)
        -> (actual_cost, estimated_cost)

    estimate_tokens_from_messages(messages)
        -> int (rough estimate when usage object is unavailable)

Cost tracking strategy:
    - actual_cost_usd: Real billed cost ($0 on free tier)
    - estimated_paid_cost_usd: What tokens would cost on paid tier

Primary source: LiteLLM's cost_per_token() (most accurate, model-aware)
Fallback: Config rates from AUTOSRE_LLM__INPUT_COST_PER_1K_* env vars

Provider-agnostic calculator. Reads standard OpenAI-compatible usage
objects and applies per-1K rates from the LLMConfig.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

try:
    import litellm

    HAS_LITELLM = True
except ImportError:
    HAS_LITELLM = False

from autosre.config import LLMConfig


def _usage_value(usage: Any, name: str, default: Any = None) -> Any:
    """Read a field from mapping-like or attribute-style usage objects."""
    if isinstance(usage, Mapping):
        return usage.get(name, default)
    return getattr(usage, name, default)


def _non_negative_int(value: Any) -> int:
    if value is None or isinstance(value, bool):
        return 0
    try:
        return max(0, int(value))
    except TypeError, ValueError, OverflowError:
        return 0


def _cached_prompt_tokens(usage: Any) -> int:
    details = _usage_value(usage, "prompt_tokens_details")
    if details is None:
        return 0
    if isinstance(details, Mapping):
        raw_cached = details.get("cached_tokens", 0)
    else:
        raw_cached = getattr(details, "cached_tokens", 0)
    return _non_negative_int(raw_cached)


def _canonical_model_id(model_name: Any) -> str:
    return str(model_name or "").strip().lower()


def _is_coordinator_model(model_name: str, config: LLMConfig) -> bool:
    coordinator = _canonical_model_id(config.model_coordinator)
    resolved = _canonical_model_id(model_name)
    if not coordinator or not resolved:
        return False
    if resolved == coordinator:
        return True
    return resolved.rsplit("/", 1)[-1] == coordinator.rsplit("/", 1)[-1]


def _get_rates_from_config(model_name: str, config: LLMConfig | None) -> tuple[float, float]:
    """Get per-1K rates from config (fallback when LiteLLM doesn't know model)."""
    if config is None:
        return 0.0, 0.0
    if _is_coordinator_model(model_name, config):
        return (
            float(config.input_cost_per_1k_coordinator),
            float(config.output_cost_per_1k_coordinator),
        )
    return (
        float(config.input_cost_per_1k_worker),
        float(config.output_cost_per_1k_worker),
    )


def _get_rates_from_env() -> tuple[float, float]:
    """Get per-1K rates from environment variables (ultimate fallback)."""
    input_rate = float(os.getenv("AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR", "0.00075"))
    output_rate = float(os.getenv("AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR", "0.00375"))
    return input_rate, output_rate


def _compute_cost_from_counts(
    prompt_tokens: int,
    completion_tokens: int,
    cached_tokens: int,
    input_cost_per_1k: float,
    output_cost_per_1k: float,
) -> float:
    uncached_prompt = max(0, prompt_tokens - cached_tokens)
    input_cost = (uncached_prompt / 1000.0) * input_cost_per_1k
    cached_input_cost = (cached_tokens / 1000.0) * input_cost_per_1k
    output_cost = (completion_tokens / 1000.0) * output_cost_per_1k
    return round(input_cost + cached_input_cost + output_cost, 6)


def estimate_tokens_from_messages(messages: Any) -> int:
    """Rough token estimate: ~4 chars per token.

    Used as a fallback when the LLM response has no usage object
    (rare but possible on some providers or error paths).
    """
    if not messages or not isinstance(messages, list):
        return 0
    total_chars = 0
    for msg in messages:
        if isinstance(msg, dict):
            content = msg.get("content", "")
            if isinstance(content, str):
                total_chars += len(content)
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict):
                        total_chars += len(str(part.get("text", "")))
    return max(1, total_chars // 4)


def calculate_cost(
    usage: Any,
    model_name: str,
    config: LLMConfig | None,
) -> tuple[int, int, int, float, float]:
    """Calculate input/output cost from a LiteLLM usage object.

    Returns:
        (prompt_tokens, completion_tokens, cached_tokens, actual_cost, estimated_paid_cost)

        - actual_cost: Real billed cost ($0 on free tier)
        - estimated_paid_cost: What it would cost on paid tier
    """
    if usage is None:
        return 0, 0, 0, 0.0, 0.0

    prompt_tokens = _non_negative_int(_usage_value(usage, "prompt_tokens", 0))
    completion_tokens = _non_negative_int(_usage_value(usage, "completion_tokens", 0))
    cached_tokens = min(_cached_prompt_tokens(usage), prompt_tokens)

    # Try LiteLLM's cost map first (most accurate)
    actual_cost = 0.0
    estimated_paid_cost = 0.0

    if HAS_LITELLM:
        try:
            prompt_cost, completion_cost = litellm.cost_per_token(
                model=model_name,
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
            )
            total_cost = prompt_cost + completion_cost

            # If LiteLLM returned >0, use it for both actual and estimated
            if total_cost > 0:
                actual_cost = total_cost
                estimated_paid_cost = total_cost
            else:
                # LiteLLM returned 0 (free tier or unknown model)
                # Use config rates for estimated_paid_cost
                input_rate, output_rate = _get_rates_from_config(model_name, config)
                if input_rate > 0 or output_rate > 0:
                    estimated_paid_cost = _compute_cost_from_counts(
                        prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
                    )
                else:
                    # Config also has 0 rates, fall back to env vars
                    input_rate, output_rate = _get_rates_from_env()
                    estimated_paid_cost = _compute_cost_from_counts(
                        prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
                    )
        except Exception:
            # LiteLLM failed, use config rates
            input_rate, output_rate = _get_rates_from_config(model_name, config)
            if input_rate > 0 or output_rate > 0:
                estimated_paid_cost = _compute_cost_from_counts(
                    prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
                )
            else:
                # Fall back to env vars
                input_rate, output_rate = _get_rates_from_env()
                estimated_paid_cost = _compute_cost_from_counts(
                    prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
                )
    else:
        # No LiteLLM, use config rates
        input_rate, output_rate = _get_rates_from_config(model_name, config)
        if input_rate > 0 or output_rate > 0:
            estimated_paid_cost = _compute_cost_from_counts(
                prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
            )
        else:
            # Fall back to env vars
            input_rate, output_rate = _get_rates_from_env()
            estimated_paid_cost = _compute_cost_from_counts(
                prompt_tokens, completion_tokens, cached_tokens, input_rate, output_rate
            )

    return prompt_tokens, completion_tokens, cached_tokens, actual_cost, estimated_paid_cost


def calculate_cost_from_counts(
    prompt_tokens: int,
    completion_tokens: int,
    model: str,
    config: LLMConfig | None,
) -> tuple[float, float]:
    """Calculate USD cost from pre-extracted token counts.

    Returns:
        (actual_cost, estimated_paid_cost)
    """
    prompt_tokens = int(prompt_tokens or 0)
    completion_tokens = int(completion_tokens or 0)

    # Try LiteLLM first
    actual_cost = 0.0
    estimated_paid_cost = 0.0

    if HAS_LITELLM:
        try:
            prompt_cost, completion_cost = litellm.cost_per_token(
                model=model,
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
            )
            total_cost = prompt_cost + completion_cost

            if total_cost > 0:
                actual_cost = total_cost
                estimated_paid_cost = total_cost
            else:
                # Use config rates for estimated
                input_rate, output_rate = _get_rates_from_config(model, config)
                if input_rate > 0 or output_rate > 0:
                    estimated_paid_cost = _compute_cost_from_counts(
                        prompt_tokens, completion_tokens, 0, input_rate, output_rate
                    )
                else:
                    input_rate, output_rate = _get_rates_from_env()
                    estimated_paid_cost = _compute_cost_from_counts(
                        prompt_tokens, completion_tokens, 0, input_rate, output_rate
                    )
        except Exception:
            input_rate, output_rate = _get_rates_from_config(model, config)
            if input_rate > 0 or output_rate > 0:
                estimated_paid_cost = _compute_cost_from_counts(
                    prompt_tokens, completion_tokens, 0, input_rate, output_rate
                )
            else:
                input_rate, output_rate = _get_rates_from_env()
                estimated_paid_cost = _compute_cost_from_counts(
                    prompt_tokens, completion_tokens, 0, input_rate, output_rate
                )
    else:
        input_rate, output_rate = _get_rates_from_config(model, config)
        if input_rate > 0 or output_rate > 0:
            estimated_paid_cost = _compute_cost_from_counts(
                prompt_tokens, completion_tokens, 0, input_rate, output_rate
            )
        else:
            input_rate, output_rate = _get_rates_from_env()
            estimated_paid_cost = _compute_cost_from_counts(
                prompt_tokens, completion_tokens, 0, input_rate, output_rate
            )

    return actual_cost, estimated_paid_cost


__all__ = [
    "calculate_cost",
    "calculate_cost_from_counts",
    "estimate_tokens_from_messages",
]
