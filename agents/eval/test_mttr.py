"""Mean-Time-To-Resolution (MTTR) evaluation tests."""

from __future__ import annotations

import os
from typing import Any

import pytest

from eval.conftest import (
    AgentClient,
    incident_by_id,
    incident_ids,
    required_nonnegative_int,
    required_nonnegative_number,
    run_incident,
)

# ---------------------------------------------------------------------------
# Incident-specific SLOs
# ---------------------------------------------------------------------------

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

# Must remain synchronized with the agent's INITIAL_ITERATION_BUDGET in config.py.
MAX_ITERATIONS = 3


def _get_slo(incident_id: str) -> float:
    """Return the MTTR SLO for a specific incident."""
    return MTTR_SLOS.get(incident_id, DEFAULT_MTTR_SLO)


def _safe_float(value: Any, default: float) -> float:
    """Safely convert a value to float, returning default on failure.

    Accepts Any because result dicts from the API may contain ints, floats,
    strings, or None for timing fields. The TypeError/ValueError guards
    catch everything that cannot be converted.
    """
    if value is None:
        return default
    try:
        result = float(value)
        return result if result >= 0 else default
    except TypeError, ValueError:
        return default


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_slo(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify incident resolution meets the incident-specific MTTR SLO.

    The SLO measures active work time (excluding provider rate-limit backoff),
    which is the honest measure of how long the agent spent investigating.
    """
    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    wall_clock = required_nonnegative_number(result, "wall_clock_seconds")
    slo = _get_slo(incident_id)

    # Use active_seconds (excludes backoff) for the SLO check
    active_seconds = _safe_float(result.get("active_seconds"), wall_clock)

    assert active_seconds <= slo, (
        f"Incident {incident_id}: Active MTTR {active_seconds:.2f}s exceeds SLO {slo:.2f}s "
        f"(wall_clock={wall_clock:.2f}s includes {wall_clock - active_seconds:.2f}s backoff)"
    )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_mttr_is_positive(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify MTTR is measured rather than omitted/defaulted to zero."""
    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    wall_clock = required_nonnegative_number(result, "wall_clock_seconds")

    assert wall_clock > 0, f"Incident {incident_id}: wall clock time should be positive"


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_iterations_are_bounded(
    incident_id: str,
    agent_client: AgentClient,
) -> None:
    """Verify the agent does not exceed its configured iteration limit."""
    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    iterations = required_nonnegative_int(result, "iterations")

    assert iterations <= MAX_ITERATIONS, (
        f"Incident {incident_id}: agent used {iterations} iterations, "
        f"exceeding limit of {MAX_ITERATIONS}"
    )
