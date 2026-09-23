"""Cost and token-usage evaluation tests."""

from __future__ import annotations

import os

import pytest

from eval.conftest import (
    AgentClient,
    incident_by_id,
    incident_ids,
    required_nonnegative_int,
    required_nonnegative_number,
    run_incident,
)

MAX_COST_PER_INCIDENT = float(os.getenv("EVAL_MAX_COST_USD", "0.15"))


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_cost_efficiency(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify that a completed incident stays within the configured budget."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    cost = required_nonnegative_number(
        result,
        "cost_usd",
    )

    assert cost <= MAX_COST_PER_INCIDENT, (
        f"Incident {incident_id}: cost ${cost:.4f} exceeds budget ${MAX_COST_PER_INCIDENT:.4f}"
    )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_token_usage_is_tracked(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify positive token usage and a sane cost/token relationship."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    tokens_used = required_nonnegative_int(
        result,
        "tokens_used",
    )

    assert tokens_used > 0, f"Incident {incident_id}: agent should have used some tokens"

    cost = required_nonnegative_number(
        result,
        "cost_usd",
    )

    # Sanity check: cost should be proportional to token usage.
    if cost > 0:
        cost_per_1k = (cost / tokens_used) * 1000

        assert cost_per_1k < 0.01, (
            f"Incident {incident_id}: cost per 1K tokens (${cost_per_1k:.6f}) seems too high"
        )
