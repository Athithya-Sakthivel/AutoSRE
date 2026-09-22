"""Root Cause Analysis accuracy evaluation using DeepEval."""

from __future__ import annotations

import os

import pytest

from eval.conftest import AgentClient, incident_by_id, incident_ids

pytestmark_rca = [
    pytest.mark.skipif(
        not os.getenv("LLM_API_KEY"),
        reason="LLM_API_KEY not set - DeepEval metrics require a judge LLM",
    ),
]

# Only test a subset for RCA accuracy (expensive)
RCA_INCIDENTS = incident_ids()[:4] if incident_ids() else []


def extract_rca_from_result(result: dict) -> str:
    """Extract RCA text from incident result."""
    hypotheses = result.get("hypotheses", [])
    if not hypotheses:
        return "No hypothesis generated"

    # Get the top hypothesis
    top_hypothesis = max(hypotheses, key=lambda h: h.get("confidence", 0))

    return (
        f"Root Cause: {top_hypothesis.get('description', 'Unknown')}\n"
        f"Confidence: {top_hypothesis.get('confidence', 0):.2f}\n"
        f"Evidence: {', '.join(top_hypothesis.get('evidence', []))}"
    )


@pytest.mark.parametrize("incident_id", RCA_INCIDENTS)
@pytest.mark.asyncio
async def test_rca_faithfulness(
    incident_id: str,
    agent_client: AgentClient,
    judge,
) -> None:
    """Verify RCA is faithful to the incident context."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import FaithfulnessMetric
    from deepeval.test_case import LLMTestCase

    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Extract RCA
    rca_text = extract_rca_from_result(result)

    # Create test case
    test_case = LLMTestCase(
        input=f"Incident: {incident.get('alert_name', 'Unknown')}",
        actual_output=rca_text,
        retrieval_context=[
            f"Service: {incident.get('service', 'Unknown')}",
            f"Namespace: {incident.get('namespace', 'Unknown')}",
            f"Severity: {incident.get('severity', 'Unknown')}",
        ],
    )

    # Measure faithfulness
    metric = FaithfulnessMetric(threshold=0.7, model=judge, async_mode=False)
    metric.measure(test_case)

    assert metric.score >= 0.7, (
        f"RCA faithfulness score {metric.score:.2f} below threshold 0.7. Reason: {metric.reason}"
    )


@pytest.mark.parametrize("incident_id", RCA_INCIDENTS)
@pytest.mark.asyncio
async def test_rca_relevancy(
    incident_id: str,
    agent_client: AgentClient,
    judge,
) -> None:
    """Verify RCA is relevant to the alert."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import AnswerRelevancyMetric
    from deepeval.test_case import LLMTestCase

    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Extract RCA
    rca_text = extract_rca_from_result(result)

    # Create test case
    test_case = LLMTestCase(
        input=f"Alert: {incident.get('alert_name', 'Unknown')} on {incident.get('service', 'Unknown')}",
        actual_output=rca_text,
    )

    # Measure relevancy
    metric = AnswerRelevancyMetric(threshold=0.7, model=judge, async_mode=False)
    metric.measure(test_case)

    assert metric.score >= 0.7, (
        f"RCA relevancy score {metric.score:.2f} below threshold 0.7. Reason: {metric.reason}"
    )


@pytest.mark.parametrize("incident_id", RCA_INCIDENTS)
@pytest.mark.asyncio
async def test_rca_exact_match_rubric(
    incident_id: str,
    agent_client: AgentClient,
    judge,
) -> None:
    """Verify RCA matches expected root cause."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import GEval
    from deepeval.test_case import LLMTestCase, SingleTurnParams

    incident = incident_by_id(incident_id)

    # Trigger incident
    incident_id_result = await agent_client.trigger_incident(incident)

    # Wait for completion
    result = await agent_client.wait_for_completion(incident_id_result)

    # Extract RCA
    rca_text = extract_rca_from_result(result)

    # Get expected root cause
    ground_truth = incident.get("ground_truth", {})
    expected_rca = ground_truth.get("root_cause", "Unknown")

    # Create test case
    test_case = LLMTestCase(
        input=f"Incident: {incident.get('alert_name', 'Unknown')}",
        actual_output=rca_text,
        expected_output=expected_rca,
    )

    # Measure with GEval
    rubric = GEval(
        name="RCA_Accuracy",
        criteria=(
            "Score 1.0 if the root cause matches exactly. "
            "Score 0.5 if it's in the correct category but not exact. "
            "Score 0.0 if it's wrong."
        ),
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT, SingleTurnParams.EXPECTED_OUTPUT],
        threshold=0.8,
        model=judge,
        async_mode=False,
    )
    rubric.measure(test_case)

    assert rubric.score >= 0.8, (
        f"RCA accuracy score {rubric.score:.2f} below threshold 0.8. Reason: {rubric.reason}"
    )
