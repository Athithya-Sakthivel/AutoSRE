"""Cost and token usage evaluation tests."""

from __future__ import annotations

import os

import pytest

from eval.conftest import AgentClient, incident_by_id, incident_ids

MAX_COST_PER_INCIDENT = float(os.getenv("EVAL_MAX_COST_USD", "0.15"))


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_cost_efficiency(incident_id: str, agent_client: AgentClient) -> None:
    """Verify agent cost stays within budget."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Check cost
    cost = result.get("cost_usd", 0.0)
    assert cost <= MAX_COST_PER_INCIDENT, (
        f"Cost ${cost:.4f} exceeds budget ${MAX_COST_PER_INCIDENT}"
    )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_token_usage_is_tracked(incident_id: str, agent_client: AgentClient) -> None:
    """Verify token usage is accurately tracked."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Check tokens
    tokens_used = result.get("tokens_used", 0)
    assert tokens_used > 0, "Agent should have used some tokens"

    cost = result.get("cost_usd", 0.0)

    # If using free tier, cost may be 0 but tokens should still be tracked
    if cost > 0:
        # Rough sanity check: cost should be proportional to tokens
        # Assuming ~$0.001 per 1000 tokens as upper bound
        expected_max_cost = (tokens_used / 1000) * 0.001
        assert cost <= expected_max_cost * 10, (
            f"Cost ${cost:.4f} seems too high for {tokens_used} tokens"
        )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_cost_matches_token_count(incident_id: str, agent_client: AgentClient) -> None:
    """Verify cost calculation is consistent with token count."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    tokens_used = result.get("tokens_used", 0)
    cost = result.get("cost_usd", 0.0)

    # Skip if using free tier (cost = 0)
    if cost == 0.0:
        pytest.skip("Using free tier, cost is 0")

    # Both should be positive
    assert tokens_used > 0
    assert cost > 0

    # Cost should be reasonable for token count
    cost_per_1k_tokens = (cost / tokens_used) * 1000
    assert cost_per_1k_tokens < 0.01, (
        f"Cost per 1K tokens (${cost_per_1k_tokens:.6f}) seems too high"
    )
