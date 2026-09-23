"""Root Cause Analysis accuracy evaluation using DeepEval."""

from __future__ import annotations

import json
import os
from math import isfinite
from typing import Any

import pytest

from eval.conftest import (
    AgentClient,
    build_incident_context,
    incident_by_id,
    incident_ids,
    is_rate_limit_error,
    run_incident,
)

pytestmark = pytest.mark.skipif(
    not os.getenv("LLM_API_KEY"),
    reason="LLM_API_KEY not set - RCA tests require a judge LLM",
)

# RCA metrics are deliberately limited because each incident generates
# additional judge LLM requests.
RCA_INCIDENTS = incident_ids()[:4]


def _confidence(value: Any) -> float:
    """Normalize a hypothesis confidence to a finite numeric value."""
    if isinstance(value, bool):
        return 0.0

    try:
        numeric = float(value)
    except TypeError, ValueError:
        return 0.0

    return numeric if isfinite(numeric) else 0.0


def _evidence_text(value: Any) -> str:
    """Serialize hypothesis evidence safely for the judge."""
    if value is None:
        return ""

    if isinstance(value, list):
        return ", ".join(str(item) for item in value)

    if isinstance(value, (dict, tuple, set)):
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            default=str,
        )

    return str(value)


def extract_rca_from_result(
    result: dict[str, Any],
) -> str:
    """Extract the highest-confidence RCA hypothesis."""
    hypotheses = result.get("hypotheses", [])

    if not isinstance(hypotheses, list):
        return "No hypothesis generated"

    valid_hypotheses = [item for item in hypotheses if isinstance(item, dict)]

    if not valid_hypotheses:
        return "No hypothesis generated"

    top = max(
        valid_hypotheses,
        key=lambda item: _confidence(item.get("confidence")),
    )

    confidence = _confidence(top.get("confidence"))

    return (
        f"Root Cause: {top.get('description', 'Unknown')}\n"
        f"Confidence: {confidence:.2f}\n"
        f"Status: {top.get('status', 'unknown')}\n"
        f"Evidence: {_evidence_text(top.get('evidence'))}"
    )


async def _measure_metric(
    metric: Any,
    test_case: Any,
    incident_id: str,
) -> float:
    """Measure a DeepEval metric asynchronously."""
    try:
        score = await metric.a_measure(test_case)
    except Exception as exc:
        if is_rate_limit_error(exc):
            pytest.skip(f"Judge rate-limited on {incident_id}: {exc}")
        raise

    numeric = float(score)

    assert isfinite(numeric), f"Incident {incident_id}: metric score must be finite"

    return numeric


@pytest.mark.parametrize(
    "incident_id",
    RCA_INCIDENTS,
)
@pytest.mark.asyncio
async def test_rca_faithfulness(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Verify the RCA is grounded in incident context exposed to the agent."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import FaithfulnessMetric
    from deepeval.test_case import LLMTestCase

    incident = incident_by_id(incident_id)
    result = await run_incident(
        agent_client,
        incident,
    )

    rca_text = extract_rca_from_result(result)

    retrieval_context = build_incident_context(incident)

    if not retrieval_context:
        pytest.fail(f"Incident {incident_id}: no evaluation context is available for faithfulness")

    test_case = LLMTestCase(
        input=(f"Incident: {incident.get('alert_name', 'Unknown')}"),
        actual_output=rca_text,
        retrieval_context=retrieval_context,
    )

    metric = FaithfulnessMetric(
        threshold=0.7,
        model=judge,
        async_mode=True,
    )

    score = await _measure_metric(
        metric,
        test_case,
        incident_id,
    )

    assert score >= 0.7, (
        f"Incident {incident_id}: RCA faithfulness {score:.2f} below 0.70. Reason: {metric.reason}"
    )


@pytest.mark.parametrize(
    "incident_id",
    RCA_INCIDENTS,
)
@pytest.mark.asyncio
async def test_rca_relevancy(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Verify the RCA is relevant to the alert."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import AnswerRelevancyMetric
    from deepeval.test_case import LLMTestCase

    incident = incident_by_id(incident_id)

    result = await run_incident(
        agent_client,
        incident,
    )

    rca_text = extract_rca_from_result(result)

    test_case = LLMTestCase(
        input=(
            f"Alert: "
            f"{incident.get('alert_name', 'Unknown')} "
            f"on "
            f"{incident.get('service', 'Unknown')}"
        ),
        actual_output=rca_text,
    )

    metric = AnswerRelevancyMetric(
        threshold=0.7,
        model=judge,
        async_mode=True,
    )

    score = await _measure_metric(
        metric,
        test_case,
        incident_id,
    )

    assert score >= 0.7, (
        f"Incident {incident_id}: RCA relevancy {score:.2f} below 0.70. Reason: {metric.reason}"
    )


@pytest.mark.parametrize(
    "incident_id",
    RCA_INCIDENTS,
)
@pytest.mark.asyncio
async def test_rca_matches_ground_truth(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Verify RCA matches the expected root cause from the dataset."""
    if judge is None:
        pytest.skip("Judge model not available")

    from deepeval.metrics import GEval
    from deepeval.test_case import (
        LLMTestCase,
        SingleTurnParams,
    )

    incident = incident_by_id(incident_id)

    result = await run_incident(
        agent_client,
        incident,
    )

    rca_text = extract_rca_from_result(result)

    ground_truth = incident.get(
        "ground_truth",
        {},
    )

    if not isinstance(ground_truth, dict):
        pytest.fail(f"Incident {incident_id}: 'ground_truth' must be an object")

    expected_rca = ground_truth.get("root_cause")

    if not isinstance(expected_rca, str) or not expected_rca.strip():
        pytest.fail(f"Incident {incident_id}: dataset has no ground-truth root cause")

    test_case = LLMTestCase(
        input=(f"Incident: {incident.get('alert_name', 'Unknown')}"),
        actual_output=rca_text,
        expected_output=expected_rca,
    )

    rubric = GEval(
        name="RCA_Accuracy",
        criteria=(
            "Score 1.0 when the root cause in the actual "
            "output matches the expected root cause. "
            "Score 0.5 when it is clearly the same root-cause "
            "category but not exact. "
            "Score 0.0 when the root cause is wrong or absent."
        ),
        evaluation_params=[
            SingleTurnParams.ACTUAL_OUTPUT,
            SingleTurnParams.EXPECTED_OUTPUT,
        ],
        threshold=0.5,
        model=judge,
        async_mode=True,
    )

    score = await _measure_metric(
        rubric,
        test_case,
        incident_id,
    )

    assert score >= 0.5, (
        f"Incident {incident_id}: RCA accuracy {score:.2f} below 0.50. Reason: {rubric.reason}"
    )
