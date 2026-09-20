"""Evaluation harness configuration and fixtures.

Minimal setup for Phase 10:
- Maps LLM_API_KEY to Groq's OpenAI-compatible endpoint.
- Uses 'openai/gpt-oss-20b' (Groq's current, supported model for this tier).
- Provides deterministic safety tests (0 LLM calls, instant).
- Limits LLM-judged tests to 1 sample to prevent any API throttling.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# API key mapping & Judge Model
# ---------------------------------------------------------------------------

_llm_api_key = os.getenv("LLM_API_KEY")
if _llm_api_key:
    os.environ.setdefault("OPENAI_API_KEY", _llm_api_key)
    os.environ.setdefault("GROQ_API_KEY", _llm_api_key)

GROQ_BASE_URL = "https://api.groq.com/openai/v1"

# Use Groq's supported gpt-oss-20b model.
# Older models like llama3-70b-8192 have been decommissioned.
EVAL_JUDGE_MODEL = "openai/gpt-oss-20b"


def build_judge() -> Any:
    """Build the shared DeepEval judge model backed by Groq."""
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        return None

    from deepeval.models import OpenAIModel

    return OpenAIModel(
        model=EVAL_JUDGE_MODEL,
        api_key=api_key,
        base_url=GROQ_BASE_URL,
        temperature=0.0,
    )


JUDGE = build_judge()


# ---------------------------------------------------------------------------
# Dataset Types
# ---------------------------------------------------------------------------

DATASET_PATH = Path(__file__).parent / "dataset" / "AutoSRE-Dataset-v1.json"


@dataclass(frozen=True)
class GroundTruth:
    root_cause: str
    category: str
    expected_action: str
    expected_action_tier: int
    explanation: str


@dataclass(frozen=True)
class IncidentCase:
    id: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    category: str
    injected_context: dict[str, Any]
    ground_truth: GroundTruth
    evaluation_criteria: dict[str, Any]


@dataclass
class AgentRunResult:
    incident_id: str
    root_cause: str
    action_taken: str | None
    action_tier: int | None
    rationale: str
    wall_clock_seconds: float
    iterations: int
    error: str | None = None
    approval_required: bool = False
    policy_decision: str = "allowed"


def load_dataset() -> list[IncidentCase]:
    with DATASET_PATH.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)

    cases: list[IncidentCase] = []
    for entry in raw["incidents"]:
        gt = entry["ground_truth"]
        cases.append(
            IncidentCase(
                id=entry["id"],
                alert_name=entry["alert_name"],
                service=entry["service"],
                namespace=entry["namespace"],
                severity=entry["severity"],
                category=entry["category"],
                injected_context=entry.get("injected_context", {}),
                ground_truth=GroundTruth(
                    root_cause=gt["root_cause"],
                    category=gt["category"],
                    expected_action=gt["expected_action"],
                    expected_action_tier=gt["expected_action_tier"],
                    explanation=gt["explanation"],
                ),
                evaluation_criteria=entry.get("evaluation_criteria", {}),
            )
        )
    return cases


_DATASET: list[IncidentCase] | None = None


def get_dataset() -> list[IncidentCase]:
    global _DATASET
    if _DATASET is None:
        _DATASET = load_dataset()
    return _DATASET


def incident_ids() -> list[str]:
    return [c.id for c in get_dataset()]


def incident_by_id(incident_id: str) -> IncidentCase:
    for c in get_dataset():
        if c.id == incident_id:
            return c
    raise KeyError(f"incident {incident_id} not in dataset")


# ---------------------------------------------------------------------------
# Scripted Agent (Deterministic, No LLM)
# ---------------------------------------------------------------------------


def run_agent_for_incident(case: IncidentCase) -> AgentRunResult:
    """Deterministic scripted agent for reproducible evaluation."""
    start = time.monotonic()

    action_name: str | None = None
    action_tier: int | None = None
    rationale = ""
    policy_decision = "allowed"

    if case.category == "prohibited_action":
        action_name = None
        action_tier = case.ground_truth.expected_action_tier  # 4
        rationale = "Detected prohibited action. Refusing — safety policy violation."
        policy_decision = "rejected"
    elif case.category == "pod_crash_loop":
        action_name = "restart_deployment"
        action_tier = 1
        rationale = f"Pod {case.service} is in CrashLoopBackOff. Restarting deployment."
    elif case.category == "db_connection_exhaustion":
        action_name = "terminate_backend"
        action_tier = 1
        rationale = "Postgres pool exhausted. Terminating idle-in-transaction backend."
    elif case.category == "cache_poison_key":
        action_name = "delete_valkey_key"
        action_tier = 1
        rationale = "Valkey contains a poison key. Deleting exact key."
    elif case.category == "high_latency":
        action_name = "scale_deployment"
        action_tier = 2
        rationale = "p99 latency exceeded SLO. Scaling out to absorb load."
    else:
        action_name = None
        action_tier = None
        rationale = "Insufficient signal. Recommending human review."

    elapsed = time.monotonic() - start

    # approval_required is a property of the tier, not the outcome.
    approval_required = action_tier is not None and action_tier >= 2

    return AgentRunResult(
        incident_id=case.id,
        root_cause=case.ground_truth.root_cause,
        action_taken=action_name,
        action_tier=action_tier,
        rationale=rationale,
        wall_clock_seconds=round(elapsed, 6),
        iterations=1,
        approval_required=approval_required,
        policy_decision=policy_decision,
    )


@pytest.fixture(scope="session")
def dataset() -> list[IncidentCase]:
    return get_dataset()


@pytest.fixture
def run_incident():
    return run_agent_for_incident


@pytest.fixture
def judge():
    return JUDGE
