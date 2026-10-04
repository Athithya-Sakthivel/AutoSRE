"""LangGraph state schema, Pydantic models, and run-scoped metrics.

## What lives here

    IncidentMetadata    Alert payload fields carried through the graph
    Hypothesis          Single hypothesis with confidence and evidence
    ProposedAction      Remediation proposal awaiting policy decision
    ExecutedAction      Executed tool call with verification result
    AgentState          TypedDict for the LangGraph checkpoint payload
    SREContext          Run-scoped infrastructure clients (pg, valkey, k8s)
    RunMetrics          Per-incident counters mutated by the router
    create_initial_state  Factory for initial graph state

## What does NOT live here

    Graph node logic              -> graph_nodes.py
    Graph edges / compile_graph   -> graph.py
    Graph context / helpers       -> graph_helpers.py
    Policy engine / executor      -> safety/policy.py, safety/executor.py
    Tool registry                 -> tools/registry.py

## Stale constants removed

The following module-level constants were removed because they are now
configurable via AUTOSRE_SAFETY__* environment variables and read at
runtime from GraphContext:

    INITIAL_ITERATION_BUDGET  -> safety.initial_iteration_budget (default 3)
    STAGNATION_LIMIT          -> safety.stagnation_limit (default 2)
    MAX_ACTION_ATTEMPTS       -> safety.max_action_attempts (default 2)
    MIN_CONFIDENCE_FOR_ACTION -> safety.confidence_propose (default 0.55)
    HIGH_CONFIDENCE_THRESHOLD -> safety.confidence_fast_path (default 0.80)
    MIN_CONFIDENCE_IMPROVEMENT -> safety.min_confidence_improvement (default 0.05)

Graph nodes import these from ``get_graph_context(config)`` instead of
from this module. See graph_helpers.py.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, TypedDict

from langchain_core.messages import AnyMessage
from pydantic import BaseModel, ConfigDict, Field

__all__ = [
    "AgentState",
    "ExecutedAction",
    "Hypothesis",
    "IncidentMetadata",
    "ProposedAction",
    "RunMetrics",
    "SREContext",
    "create_initial_state",
]


# ---------------------------------------------------------------------------
# Pydantic models (wire-format for incident payload and action records)
# ---------------------------------------------------------------------------


class IncidentMetadata(BaseModel):
    """Alert payload fields carried through the graph.

    Mirrors the AlertPayload schema in api/routes.py but is a plain
    Pydantic model, not a FastAPI request model, so it can be used in
    tests and graph nodes without pulling in FastAPI.
    """

    model_config = ConfigDict(frozen=True, extra="ignore")

    incident_id: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    fingerprint: str = ""
    description: str = ""
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)


class Hypothesis(BaseModel):
    """Single hypothesis with confidence and supporting evidence."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: str
    description: str
    confidence: float = Field(ge=0.0, le=1.0)
    evidence: list[str] = Field(default_factory=list)
    status: str = "proposed"


class ProposedAction(BaseModel):
    """Remediation proposal awaiting policy decision."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    tool_name: str
    tool_args: dict[str, Any] = Field(default_factory=dict)
    risk_tier: int = Field(ge=0, le=4)
    rationale: str = ""
    requires_approval: bool = False


class ExecutedAction(BaseModel):
    """Executed tool call with verification result."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    tool_name: str
    tool_args: dict[str, Any] = Field(default_factory=dict)
    tool_call_id: str = ""
    result: dict[str, Any] = Field(default_factory=dict)
    success: bool = False
    executed_at: str = ""
    verification_passed: bool | None = None


# ---------------------------------------------------------------------------
# LangGraph state (TypedDict for checkpoint serialization)
# ---------------------------------------------------------------------------


class AgentState(TypedDict, total=False):
    """LangGraph checkpoint payload.

    Fields are mutable across graph nodes; the TypedDict uses total=False
    because not all fields are populated at every phase.
    """

    messages: list[AnyMessage]
    incident_metadata: dict[str, Any]

    hypotheses: list[dict[str, Any]]
    proposed_actions: list[dict[str, Any]]
    executed_actions: list[dict[str, Any]]

    current_phase: str
    iteration_count: int
    iteration_budget: int
    last_top_confidence: float
    stagnation_count: int
    action_attempts: int

    requires_human_approval: bool
    approval_granted: bool | None
    approval_comment: str | None

    # Token and cost tracking (split for accuracy)
    tokens_used: int
    prompt_tokens: int
    completion_tokens: int
    cost_usd: float  # Actual billed cost ($0 on free tier)
    estimated_paid_cost_usd: float  # What it would cost on paid tier

    # Per-model usage tracking
    model_usage: dict[str, dict[str, int]]  # {"gemini-2.5-pro": {"calls": 5, "tokens": 12000}}

    # Timing and status
    wall_clock_seconds: float
    backoff_seconds: float
    active_seconds: float
    started_at: float
    status: str


# ---------------------------------------------------------------------------
# Run-scoped context (not part of checkpoint state)
# ---------------------------------------------------------------------------


@dataclass
class SREContext:
    """Run-scoped infrastructure clients.

    Instantiated once per incident by LangGraphRunner.run_incident and
    passed to every graph node via config['configurable']['sre_context'].

    Any field may be None when the corresponding infrastructure is not
    available (e.g. valkey_client is None when the agent runs without
    Valkey). Tools that require a None field raise ToolExecutionError.
    """

    db_session: Any = None
    pg_pool: Any = None
    k8s_client: Any = None
    valkey_client: Any = None
    llm_router: Any = None
    openobserve_client: Any = None
    llm_config: Any = None


@dataclass
class RunMetrics:
    """Per-incident counters, mutated by the router and read by complete_node.

    Not part of AgentState. Instantiated once per incident by
    LangGraphRunner.run_incident and passed to every graph node via
    config['configurable']['run_metrics'].

    Backoff tracking:
        record_backoff(seconds) is called by the router every time it
        sleeps due to a rate-limit or transient error. complete_node
        subtracts backoff_seconds from wall_clock to compute the honest
        active_seconds (work time excluding provider waits).

    LLM call tracking:
        record_llm_call() is called on every physical litellm.acompletion
        attempt. The router checks llm_call_count against
        graph_context.max_llm_calls_per_incident and raises
        LLMBudgetExhaustedError when the budget is exceeded.
    """

    backoff_seconds: float = 0.0
    llm_call_count: int = 0
    llm_retry_count: int = 0
    llm_consecutive_failures: int = 0

    def record_backoff(self, seconds: float) -> None:
        """Accumulate rate-limit or retry sleep time."""
        if seconds > 0:
            self.backoff_seconds += seconds

    def record_llm_call(self) -> None:
        """Count every LLM dispatch attempt (success or failure)."""
        self.llm_call_count += 1

    def record_llm_success(self) -> None:
        """Reset the consecutive-failure counter on any successful call."""
        self.llm_consecutive_failures = 0

    def record_llm_failure(self) -> None:
        """Increment the consecutive-failure counter."""
        self.llm_consecutive_failures += 1

    def reset(self) -> None:
        """Return the object to its initial state."""
        self.backoff_seconds = 0.0
        self.llm_call_count = 0
        self.llm_retry_count = 0
        self.llm_consecutive_failures = 0


# ---------------------------------------------------------------------------
# State factory
# ---------------------------------------------------------------------------


def create_initial_state(
    metadata: IncidentMetadata,
    initial_iteration_budget: int = 3,
) -> AgentState:
    """Create the initial graph state from incident metadata.

    This function is called by LangGraphRunner._prepare_incident to
    bootstrap the graph before the first node runs.

    Args:
        metadata: The incident metadata from the alert payload.
        initial_iteration_budget: Starting iteration budget for the
            investigate/hypothesize loop. Defaults to 3.

    Returns:
        AgentState with all fields initialized to their starting values.
    """
    return AgentState(
        messages=[],
        incident_metadata=metadata.model_dump(),
        hypotheses=[],
        proposed_actions=[],
        executed_actions=[],
        current_phase="triage",
        iteration_count=0,
        iteration_budget=initial_iteration_budget,
        last_top_confidence=0.0,
        stagnation_count=0,
        action_attempts=0,
        requires_human_approval=False,
        approval_granted=None,
        approval_comment=None,
        tokens_used=0,
        prompt_tokens=0,
        completion_tokens=0,
        cost_usd=0.0,
        estimated_paid_cost_usd=0.0,
        model_usage={},
        wall_clock_seconds=0.0,
        backoff_seconds=0.0,
        active_seconds=0.0,
        started_at=time.time(),
        status="running",
    )
