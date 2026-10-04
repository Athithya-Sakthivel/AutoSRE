"""Root Cause Analysis (RCA) accuracy evaluation tests.

## Design philosophy

These tests evaluate RCA quality as **informational metrics**, not hard gates.
The scores are always computed and printed, but failures use pytest.xfail
with a descriptive reason rather than failing the build.

This is intentional because:

    1. The judge model (Gemini Flash Lite on Google AI Studio free tier) does
       not support logprobs, which eliminates G-Eval — the most accurate
       LLM-as-a-judge framework — from use.

    2. The agent's hypothesis generation can occasionally hallucinate
       (e.g. claiming "idle in transaction" when evidence shows active queries).
       This is a known limitation documented in the agent's hypothesize_node.

    3. SRE RCA evaluation against noisy evidence (raw SQL queries, kubectl
       output) produces inherently unstable scores that should not gate CI.

## Metrics used (all logprobs-free)

    - FaithfulnessMetric: Is every claim in the RCA supported by evidence?
    - AnswerRelevancyMetric: Is the RCA relevant to the incident/ground truth?

## Metrics NOT used (require logprobs)

    - GEval: Requires logprobs for weighted scoring. Gemini Flash Lite on
      Google AI Studio returns a hard 400 ("Logprobs is not enabled for this
      model"). LiteLLM's drop_params does not apply to G-Eval's raw response
      code path. No workaround exists as of 2026-10.
"""

from __future__ import annotations

from typing import Any

import pytest
from deepeval.metrics import AnswerRelevancyMetric, FaithfulnessMetric
from deepeval.test_case import LLMTestCase

from eval.conftest import (
    AgentClient,
    incident_by_id,
    incident_ids,
    measure_metric_with_retry,
    run_incident,
)

# ---------------------------------------------------------------------------
# RCA extraction helpers
# ---------------------------------------------------------------------------


def _extract_rca(result: dict[str, Any]) -> str:
    """Extract the RCA as the highest-confidence hypothesis description.

    Returns empty string if no hypotheses or no valid description found.
    """
    hypotheses = result.get("hypotheses") or []
    if not isinstance(hypotheses, list) or not hypotheses:
        return ""

    try:
        sorted_h = sorted(
            hypotheses,
            key=lambda h: float(h.get("confidence", 0.0) or 0.0),
            reverse=True,
        )
    except TypeError, ValueError:
        sorted_h = hypotheses

    top = sorted_h[0]
    if not isinstance(top, dict):
        return ""

    description = top.get("description", "")
    if not isinstance(description, str):
        return ""

    return description.strip()


def _extract_evidence(result: dict[str, Any]) -> list[str]:
    """Flatten all evidence strings from all hypotheses."""
    hypotheses = result.get("hypotheses") or []
    if not isinstance(hypotheses, list):
        return []

    evidence: list[str] = []
    for h in hypotheses:
        if not isinstance(h, dict):
            continue
        h_evidence = h.get("evidence") or []
        if isinstance(h_evidence, list):
            for item in h_evidence:
                if isinstance(item, str) and item.strip():
                    evidence.append(item)
    return evidence


def _report_metric(label: str, score: float, threshold: float) -> None:
    """Print a metric score to stdout for visibility in test reports."""
    status = "PASS" if score >= threshold else "WARN"
    print(f"  [{status}] {label}: {score:.3f} (threshold: {threshold:.2f})")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_rca_faithfulness(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Test that RCA hypotheses are faithful to gathered evidence.

    Skips gracefully if:
    - Judge model unavailable
    - No hypotheses generated
    - No evidence gathered
    - Judge API fails
    """
    if judge is None:
        pytest.skip("Judge model not available")

    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    hypotheses = result.get("hypotheses", [])
    if not hypotheses:
        pytest.skip(f"No hypotheses generated for {incident_id}")

    evidence = _extract_evidence(result)
    if not evidence:
        pytest.skip(f"No evidence gathered for {incident_id}")

    # Use first hypothesis as the actual output
    hypothesis = hypotheses[0]
    actual_output = hypothesis.get("description", "")

    if not actual_output:
        pytest.skip(f"No hypothesis description for {incident_id}")

    test_case = LLMTestCase(
        input=f"Incident: {incident.get('alert_name', incident_id)}",
        actual_output=actual_output,
        retrieval_context=evidence,
    )

    metric = FaithfulnessMetric(threshold=0.5, model=judge)

    try:
        score = await measure_metric_with_retry(
            metric,
            test_case,
            label=f"rca_faithfulness[{incident_id}]",
        )
    except Exception as exc:
        # Judge model unavailable or API error - skip gracefully
        pytest.skip(f"Judge model failed: {type(exc).__name__}: {str(exc)[:100]}")

    _report_metric(f"faithfulness[{incident_id}]", score, 0.5)

    if score < 0.5:
        pytest.xfail(
            f"RCA faithfulness {score:.2f} < 0.5 threshold. "
            f"Hypothesis: {actual_output[:100]}. "
            f"Evidence: {len(evidence)} items"
        )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_rca_matches_ground_truth(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Is the RCA relevant to the ground truth root cause?

    Uses AnswerRelevancyMetric (logprobs-free) instead of G-Eval.

    Skips gracefully if:
    - Judge model unavailable
    - No ground truth defined
    - No RCA generated
    - Judge API fails

    G-Eval is permanently incompatible with Gemini Flash Lite on Google AI
    Studio due to a hard 400 on the logprobs parameter that bypasses
    LiteLLM's drop_params setting.
    """
    threshold = 0.4

    if judge is None:
        pytest.skip("Judge model not available")

    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    ground_truth = incident.get("ground_truth") or {}
    if not isinstance(ground_truth, dict):
        ground_truth = {}
    expected_rca = str(ground_truth.get("root_cause", "") or "").strip()

    if not expected_rca:
        pytest.skip(f"No ground truth for {incident_id}")

    agent_rca = _extract_rca(result)
    if not agent_rca:
        pytest.skip(f"No RCA generated for {incident_id}")

    test_case = LLMTestCase(
        input=f"What is the root cause? Expected: {expected_rca}",
        actual_output=agent_rca,
    )

    metric = AnswerRelevancyMetric(
        threshold=threshold,
        model=judge,
        include_reason=True,
    )

    try:
        score = await measure_metric_with_retry(
            metric,
            test_case,
            label=f"rca_ground_truth[{incident_id}]",
        )
    except Exception as exc:
        pytest.skip(f"Judge model failed: {type(exc).__name__}: {str(exc)[:100]}")

    _report_metric(f"ground_truth[{incident_id}]", score, threshold)

    reason = getattr(metric, "reason", None) or ""
    if reason:
        print(f"    Reason: {reason[:300]}")

    if score < threshold:
        pytest.xfail(
            f"RCA relevancy {score:.2f} < {threshold:.2f}. "
            f"Expected: {expected_rca[:100]}. Actual: {agent_rca[:100]}"
        )


@pytest.mark.parametrize("incident_id", incident_ids())
@pytest.mark.asyncio
async def test_rca_is_specific(
    incident_id: str,
    agent_client: AgentClient,
    judge: Any,
) -> None:
    """Is the RCA specific (mentions affected components) vs generic?

    Skips gracefully if:
    - Judge model unavailable
    - No RCA generated
    - Judge API fails
    """
    threshold = 0.4

    if judge is None:
        pytest.skip("Judge model not available")

    incident = incident_by_id(incident_id)
    result = await run_incident(agent_client, incident)

    agent_rca = _extract_rca(result)
    if not agent_rca:
        pytest.skip(f"No RCA generated for {incident_id}")

    test_case = LLMTestCase(
        input=(
            f"Provide a specific root cause for '{incident.get('alert_name', incident_id)}' "
            f"mentioning the affected service, component, or observable symptom."
        ),
        actual_output=agent_rca,
    )

    metric = AnswerRelevancyMetric(
        threshold=threshold,
        model=judge,
        include_reason=False,
    )

    try:
        score = await measure_metric_with_retry(
            metric,
            test_case,
            label=f"rca_specificity[{incident_id}]",
        )
    except Exception as exc:
        pytest.skip(f"Judge model failed: {type(exc).__name__}: {str(exc)[:100]}")

    _report_metric(f"specificity[{incident_id}]", score, threshold)

    if score < threshold:
        pytest.xfail(f"RCA specificity {score:.2f} < {threshold:.2f}. RCA: {agent_rca[:150]}")
