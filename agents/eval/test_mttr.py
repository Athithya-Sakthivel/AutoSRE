"""Mean-Time-To-Resolution (MTTR) evaluation tests."""

from __future__ import annotations

import os

import pytest

from eval.conftest import AgentClient, incident_by_id, incident_ids

MAX_MTTR_SECONDS = float(os.getenv("EVAL_MAX_MTTR_SECONDS", "120.0"))


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_slo(incident_id: str, agent_client: AgentClient) -> None:
    """Verify incident resolution meets MTTR SLO."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Check MTTR
    wall_clock = result.get("wall_clock_seconds", 0.0)
    assert wall_clock <= MAX_MTTR_SECONDS, f"MTTR {wall_clock:.2f}s exceeds SLO {MAX_MTTR_SECONDS}s"


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_is_positive(incident_id: str, agent_client: AgentClient) -> None:
    """Verify MTTR measurement is positive."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Check MTTR
    wall_clock = result.get("wall_clock_seconds", 0.0)
    assert wall_clock > 0, "Wall clock time should be positive"


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_iterations_are_bounded(incident_id: str, agent_client: AgentClient) -> None:
    """Verify agent doesn't exceed iteration limit."""
    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Check iterations
    iterations = result.get("iterations", 0)
    max_iterations = 10  # From graph_helpers.py

    assert iterations <= max_iterations, (
        f"Agent used {iterations} iterations, exceeding limit of {max_iterations}"
    )
