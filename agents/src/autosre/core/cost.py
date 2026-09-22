"""Cost calculation utilities for LLM token usage."""

from __future__ import annotations

from typing import Any

from autosre.config import LLMConfig


def calculate_cost(
    usage: Any,
    model_name: str,
    config: LLMConfig | None,
) -> tuple[int, int, float]:
    """Calculate cost from LiteLLM usage object.

    Args:
        usage: LiteLLM usage object with prompt_tokens and completion_tokens
        model_name: The RESOLVED model ID from LiteLLM response
        config: LLM configuration with pricing (may be None in tests)

    Returns:
        (prompt_tokens, completion_tokens, cost_usd)
    """
    if usage is None:
        return 0, 0, 0.0

    prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
    completion_tokens = int(getattr(usage, "completion_tokens", 0) or 0)

    # If no config (e.g., tests), return tokens but zero cost
    if config is None:
        return prompt_tokens, completion_tokens, 0.0

    # Match against the actual configured model IDs
    is_coordinator = model_name == config.model_coordinator or model_name.endswith(
        config.model_coordinator.split("/")[-1]
    )

    if is_coordinator:
        input_cost_per_1k = config.input_cost_per_1k_coordinator
        output_cost_per_1k = config.output_cost_per_1k_coordinator
    else:
        input_cost_per_1k = config.input_cost_per_1k_worker
        output_cost_per_1k = config.output_cost_per_1k_worker

    input_cost = (prompt_tokens / 1000.0) * input_cost_per_1k
    output_cost = (completion_tokens / 1000.0) * output_cost_per_1k
    total_cost = input_cost + output_cost

    return prompt_tokens, completion_tokens, round(total_cost, 6)
