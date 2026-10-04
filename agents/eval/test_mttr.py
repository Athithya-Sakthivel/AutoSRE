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

# --- CHANGED: Incident-specific SLOs instead of a single global SLO ---
# Simple incidents (cache poison, pod restart) should resolve fast.
# Complex incidents (DB issues, cascading failures) need more time.
MTTR_SLOS: dict[str, float] = {
    "INC-001": 180.0,  # DB connection exhaustion — complex
    "INC-002": 180.0,  # High CPU — moderate (includes HITL wait)
    "INC-003": 180.0,  # Idle-in-transaction — complex
    "INC-004": 90.0,  # Cache poison — simple, should be fast
    "INC-005": 120.0,  # Consumer lag — moderate
    "INC-006": 90.0,  # Stale pod — simple
    "INC-007": 120.0,  # Upstream timeout — moderate
    "INC-008": 120.0,  # Memory pressure — moderate
    "INC-009": 90.0,  # Pod OOMKilled — simple
    "INC-010": 30.0,  # Webhook dedup — no remediation, very fast
    "INC-011": 30.0,  # Prohibited action — blocked immediately
    "INC-012": 300.0,  # Cascading failure — complex
}

# Default SLO for incidents not in the map.
DEFAULT_MTTR_SLO = float(os.getenv("EVAL_MAX_MTTR_SECONDS", "180.0"))

# Must remain synchronized with the agent's MAX_ITERATIONS in state.py.
MAX_ITERATIONS = 3  # CHANGED: was 10, now matches INITIAL_ITERATION_BUDGET
# --- END CHANGED ---


def _get_slo(incident_id: str) -> float:
    """Return the MTTR SLO for a specific incident."""
    return MTTR_SLOS.get(incident_id, DEFAULT_MTTR_SLO)


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_slo(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify incident resolution meets the incident-specific MTTR SLO."""
    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    wall_clock = required_nonnegative_number(
        result,
        "wall_clock_seconds",
    )

    slo = _get_slo(incident_id)

    assert wall_clock <= slo, (
        f"Incident {incident_id}: MTTR {wall_clock:.2f}s exceeds SLO {slo:.2f}s"
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
