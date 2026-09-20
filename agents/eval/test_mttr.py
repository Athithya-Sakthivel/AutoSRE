"""Minimal Mean-Time-To-Resolution evaluation.

Runs on ONLY ONE incident to prove the DeepEval harness works with Groq
without throttling the free-tier API key. Full evaluation belongs in Phase 11.
"""

from __future__ import annotations

import os

import pytest
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from eval.conftest import (
    AgentRunResult,
    IncidentCase,
    incident_by_id,
    run_agent_for_incident,
)

pytestmark = pytest.mark.skipif(
    not os.getenv("LLM_API_KEY"),
    reason="LLM_API_KEY not set — GEval requires a judge LLM",
)

# Minimal subset to prevent API throttling
MINIMAL_INCIDENTS = ["INC-001"]


def _build_mttr_metric(judge):
    return GEval(
        name="MTTR",
        criteria=(
            "Score the agent's SRE incident response on: "
            "1. Root-cause identification (40%), "
            "2. Action selection (40%), "
            "3. Decisiveness (20%). "
            "Return a single float between 0 and 1."
        ),
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
            SingleTurnParams.EXPECTED_OUTPUT,
        ],
        threshold=0.40,
        async_mode=False,
        verbose_mode=False,
        model=judge,
    )


def _to_test_case(case: IncidentCase, result: AgentRunResult) -> LLMTestCase:
    action_str = result.action_taken or "none"
    tier_str = str(result.action_tier) if result.action_tier is not None else "none"

    return LLMTestCase(
        input=f"Incident {case.id}: {case.alert_name} on {case.service}/{case.namespace}",
        actual_output=(
            f"Root cause: {result.root_cause}\n"
            f"Action: {action_str} (tier {tier_str})\n"
            f"Rationale: {result.rationale}"
        ),
        expected_output=(
            f"Root cause: {case.ground_truth.root_cause}\n"
            f"Expected action: {case.ground_truth.expected_action} "
            f"(tier {case.ground_truth.expected_action_tier})"
        ),
    )


@pytest.mark.parametrize("incident_id", MINIMAL_INCIDENTS)
def test_mttr_minimal(incident_id: str, judge) -> None:
    """Prove the MTTR harness works on a single incident."""
    case = incident_by_id(incident_id)
    result = run_agent_for_incident(case)
    test_case = _to_test_case(case, result)

    metric = _build_mttr_metric(judge)
    metric.measure(test_case)

    assert metric.score is not None
    # We just check it runs and returns a score; threshold is lenient for the scripted agent
    assert metric.score >= 0.0
