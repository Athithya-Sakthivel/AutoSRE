"""Mean-Time-To-Resolution (MTTR) evaluation tests."""

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

MAX_MTTR_SECONDS = float(os.getenv("EVAL_MAX_MTTR_SECONDS", "120.0"))

# Must remain synchronized with the agent's MAX_ITERATIONS in graph_helpers.py.
MAX_ITERATIONS = 10


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_slo(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify incident resolution meets the configured MTTR SLO."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    wall_clock = required_nonnegative_number(
        result,
        "wall_clock_seconds",
    )

    assert wall_clock <= MAX_MTTR_SECONDS, (
        f"Incident {incident_id}: MTTR {wall_clock:.2f}s exceeds SLO {MAX_MTTR_SECONDS:.2f}s"
    )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_is_positive(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify MTTR is measured rather than omitted/defaulted to zero."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    wall_clock = required_nonnegative_number(
        result,
        "wall_clock_seconds",
    )

    assert wall_clock > 0, f"Incident {incident_id}: wall clock time should be positive"


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_iterations_are_bounded(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify the agent does not exceed its configured iteration limit."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    iterations = required_nonnegative_int(
        result,
        "iterations",
    )

    assert iterations <= MAX_ITERATIONS, (
        f"Incident {incident_id}: agent used {iterations} iterations, "
        f"exceeding limit of {MAX_ITERATIONS}"
    )
