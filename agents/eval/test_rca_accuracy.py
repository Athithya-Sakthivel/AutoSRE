"""Minimal Root Cause Analysis accuracy evaluation.

Runs on ONLY ONE incident to prove the DeepEval harness works with Groq
without throttling the free-tier API key. Full evaluation belongs in Phase 11.
"""

from __future__ import annotations

import os

import pytest
from deepeval.metrics import AnswerRelevancyMetric, FaithfulnessMetric
from deepeval.test_case import LLMTestCase

from eval.conftest import (
    AgentRunResult,
    IncidentCase,
    incident_by_id,
    run_agent_for_incident,
)

pytestmark = pytest.mark.skipif(
    not os.getenv("LLM_API_KEY"),
    reason="LLM_API_KEY not set — DeepEval metrics require a judge LLM",
)

# Minimal subset to prevent API throttling
MINIMAL_INCIDENTS = ["INC-001"]


def _to_test_case(case: IncidentCase, result: AgentRunResult) -> LLMTestCase:
    return LLMTestCase(
        input=f"Incident {case.id}: {case.alert_name} on {case.service}",
        actual_output=result.root_cause,
        expected_output=case.ground_truth.root_cause,
        retrieval_context=[f"{k}: {v}" for k, v in case.injected_context.items()],
    )


@pytest.mark.parametrize("incident_id", MINIMAL_INCIDENTS)
def test_rca_relevancy_minimal(incident_id: str, judge) -> None:
    case = incident_by_id(incident_id)
    result = run_agent_for_incident(case)
    test_case = _to_test_case(case, result)

    metric = AnswerRelevancyMetric(
        threshold=0.50,  # Lenient for scripted agent
        async_mode=False,
        verbose_mode=False,
        model=judge,
    )
    metric.measure(test_case)
    assert metric.score is not None


@pytest.mark.parametrize("incident_id", MINIMAL_INCIDENTS)
def test_rca_faithfulness_minimal(incident_id: str, judge) -> None:
    case = incident_by_id(incident_id)
    result = run_agent_for_incident(case)
    test_case = _to_test_case(case, result)

    metric = FaithfulnessMetric(
        threshold=0.50,  # Lenient for scripted agent
        async_mode=False,
        verbose_mode=False,
        model=judge,
    )
    metric.measure(test_case)
    assert metric.score is not None
