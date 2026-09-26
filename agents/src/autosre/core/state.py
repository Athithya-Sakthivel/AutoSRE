"""Agent state schema, run-scoped context, and metrics for AutoSRE.

This module defines four things every other module depends on:

    AgentState          LangGraph checkpointed state schema (pure TypedDict).
    RunMetrics          Mutable per-run counters, NOT part of AgentState.
    SREContext          Run-scoped dependencies, injected via RunnableConfig.
    create_initial_state / validate_state
                        Deterministic constructors and validators.

## AgentState contract

AgentState MUST be a pure ``TypedDict``. LangGraph 1.2 introspects state
schemas with ``get_type_hints(..., include_extras=True)`` and uses the
result to build channel reducers. A ``dict`` subclass with class-level
annotations is *not* equivalent: the annotations are ignored at runtime
and the reducer for ``messages`` is never wired. The current schema uses
``Annotated[..., add_messages]`` on ``messages`` and relies on
last-write-wins for every other field. Nodes that need append semantics
must build a new list from the previous one and return the new list —
do not mutate the existing list in place.

## RunMetrics contract

RunMetrics is deliberately NOT part of AgentState. AgentState is
checkpointed to Postgres and must be JSON-serializable; RunMetrics holds
mutable counters that are updated by the router on every LLM call. It is
created once per incident in ``LangGraphRunner.run_incident`` and passed
to every node via ``config['configurable']['run_metrics']``.

This split guarantees that:

    1. The router can record backoff time without writing a state update
       on every retry (which would double the checkpoint volume).
    2. ``complete_node`` can compute ``active_seconds = wall − backoff``
       by reading from the same object the router mutated.
    3. Tests can construct a fresh RunMetrics and assert exactly what
       happened during a run.

## SREContext contract

SREContext holds non-serializable objects (DB pools, K8s clients, LLM
router). It is injected via ``config['configurable']['sre_context']`` and
is never persisted. Every field defaults to ``None`` so tests and partial
integrations can construct one with only the fields they need; missing
fields surface as ``ToolExecutionError`` when a tool tries to use them.

## Timing contract

``started_at`` uses ``time.time()`` (epoch seconds), not
``time.monotonic()``. Monotonic values are meaningless across process
boundaries and after checkpoint restore, so a durable timestamp must be
wall-clock-based. ``complete_node`` computes:

    wall_clock_seconds = time.time() − started_at
    active_seconds     = max(0, wall_clock_seconds − backoff_seconds)

## Status semantics

    running     Investigation in progress. May become any terminal state.
    resolved    Terminal. At least one executed action verified as successful.
    failed      Terminal. Executed an action, but verification failed, or
                the graph terminated on an error path with prior actions.
    no_action   Terminal. Agent declined to act — low confidence, budget
                exhausted, stagnation detected, or a duplicate/idempotent
                guard fired. NOT a failure; the incident may still be live.
    blocked     Terminal. Policy rejected the only viable action.

"resolved" without an executed+verified action is a contract violation.
``complete_node`` enforces this by returning ``no_action`` when the
executed_actions list is empty.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Annotated, Any, Literal, TypedDict

from langgraph.graph.message import add_messages

# ---------------------------------------------------------------------------
# Type aliases
# ---------------------------------------------------------------------------

HypothesisStatus = Literal["proposed", "confirmed", "rejected"]

IncidentStatus = Literal[
    "running",
    "resolved",
    "failed",
    "no_action",
    "blocked",
]

GraphPhase = Literal[
    "triage",
    "investigate",
    "hypothesize",
    "propose",
    "approve",
    "execute",
    "verify",
    "complete",
]

# ---------------------------------------------------------------------------
# Graph-wide constants
#
# These live in this module (not graph_helpers) because AgentState's default
# values reference them and importing graph_helpers here would create a
# cycle. graph_helpers re-exports these names for compatibility.
# ---------------------------------------------------------------------------

INITIAL_ITERATION_BUDGET: int = 5
STAGNATION_LIMIT: int = 2
MAX_ACTION_ATTEMPTS: int = 2
MIN_CONFIDENCE_FOR_ACTION: float = 0.70
HIGH_CONFIDENCE_THRESHOLD: float = 0.75
MIN_CONFIDENCE_IMPROVEMENT: float = 0.15

# ---------------------------------------------------------------------------
# Run-scoped mutable metrics
# ---------------------------------------------------------------------------


@dataclass
class RunMetrics:
    """Per-incident counters, mutated by the router and read by complete_node.

    Not part of AgentState. Instantiated once per incident by
    ``LangGraphRunner.run_incident`` and passed to every graph node via
    ``config['configurable']['run_metrics']``.
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
# Nested state schemas
# ---------------------------------------------------------------------------


class IncidentMetadata(TypedDict, total=False):
    """Alert metadata, immutable after incident creation."""

    incident_id: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    fingerprint: str
    description: str
    labels: dict[str, str]
    annotations: dict[str, str]


class Hypothesis(TypedDict, total=False):
    """Root-cause hypothesis accumulated during investigation."""

    id: str
    description: str
    confidence: float
    evidence: list[str]
    status: HypothesisStatus


class ProposedAction(TypedDict, total=False):
    """Remediation action proposed by the agent before execution."""

    tool_name: str
    tool_args: dict[str, Any]
    risk_tier: int
    rationale: str
    requires_approval: bool


class ExecutedAction(TypedDict, total=False):
    """Executed action with its result and verification outcome."""

    tool_name: str
    tool_args: dict[str, Any]
    tool_call_id: str
    result: dict[str, Any]
    success: bool
    executed_at: str
    verification_passed: bool | None


# ---------------------------------------------------------------------------
# Graph state schema
# ---------------------------------------------------------------------------


class AgentState(TypedDict, total=False):
    """LangGraph checkpointed state schema.

    ``total=False`` because nodes return partial updates and LangGraph
    merges them into the existing checkpoint. A full state is guaranteed
    by ``create_initial_state``.

    Reducers:
        messages  add_messages     Append semantics (standard for chat).
        All others default          Last-write-wins. Nodes must return a
                                    complete replacement list to append
                                    to hypotheses, proposed_actions,
                                    executed_actions.
    """

    # Conversation history (managed by add_messages reducer)
    messages: Annotated[list[dict[str, Any]], add_messages]

    # Incident metadata, immutable after creation
    incident_metadata: IncidentMetadata

    # Investigation artifacts
    hypotheses: list[Hypothesis]
    proposed_actions: list[ProposedAction]
    executed_actions: list[ExecutedAction]

    # Control flow
    current_phase: GraphPhase
    iteration_count: int
    iteration_budget: int

    # Progress detection
    last_top_confidence: float
    stagnation_count: int
    action_attempts: int

    # Human-in-the-loop
    requires_human_approval: bool
    approval_granted: bool | None
    approval_comment: str | None

    # Cumulative metrics
    tokens_used: int
    cost_usd: float

    # Timing (all seconds)
    wall_clock_seconds: float
    backoff_seconds: float
    active_seconds: float

    # Durability: epoch seconds at incident start
    started_at: float

    # Terminal or in-progress status
    status: IncidentStatus


# ---------------------------------------------------------------------------
# Run-scoped context
# ---------------------------------------------------------------------------


@dataclass(frozen=False)
class SREContext:
    """Run-scoped dependencies injected via RunnableConfig.

    Not part of AgentState because connection objects are not
    JSON-serializable and cannot be checkpointed. Every field defaults to
    None so tests can construct a minimal context and rely on the tool
    layer to raise ToolExecutionError when a needed client is missing.
    """

    db_session: Any | None = None
    k8s_client: Any | None = None
    llm_router: Any = None
    openobserve_client: Any | None = None
    pg_pool: Any | None = None
    valkey_client: Any | None = None
    llm_config: Any | None = None


# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------


def create_initial_state(incident_metadata: IncidentMetadata) -> AgentState:
    """Return a fully populated AgentState for a new incident.

    Deterministic except for ``started_at``, which is set to the current
    epoch time. Two calls with the same metadata produce states that differ
    only in that field.
    """
    return AgentState(
        messages=[],
        incident_metadata=incident_metadata,
        hypotheses=[],
        proposed_actions=[],
        executed_actions=[],
        current_phase="triage",
        iteration_count=0,
        iteration_budget=INITIAL_ITERATION_BUDGET,
        last_top_confidence=0.0,
        stagnation_count=0,
        action_attempts=0,
        requires_human_approval=False,
        approval_granted=None,
        approval_comment=None,
        tokens_used=0,
        cost_usd=0.0,
        wall_clock_seconds=0.0,
        backoff_seconds=0.0,
        active_seconds=0.0,
        started_at=time.time(),
        status="running",
    )


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------


def validate_state(state: AgentState) -> list[str]:
    """Return a list of validation errors. Empty list means valid.

    Checks presence, type, and range constraints. Does not raise; callers
    decide whether to fail, log, or ignore.
    """
    errors: list[str] = []

    required_fields = (
        "messages",
        "incident_metadata",
        "hypotheses",
        "proposed_actions",
        "executed_actions",
        "current_phase",
        "iteration_count",
        "iteration_budget",
        "last_top_confidence",
        "stagnation_count",
        "action_attempts",
        "requires_human_approval",
        "approval_granted",
        "tokens_used",
        "cost_usd",
        "wall_clock_seconds",
        "backoff_seconds",
        "active_seconds",
        "started_at",
        "status",
    )

    for field_name in required_fields:
        if field_name not in state:
            errors.append(f"Missing required field: {field_name}")

    status = state.get("status")
    valid_statuses = {"running", "resolved", "failed", "no_action", "blocked"}
    if status not in valid_statuses:
        errors.append(f"Invalid status: {status!r}")

    phase = state.get("current_phase")
    valid_phases = {
        "triage",
        "investigate",
        "hypothesize",
        "propose",
        "approve",
        "execute",
        "verify",
        "complete",
    }
    if phase not in valid_phases:
        errors.append(f"Invalid current_phase: {phase!r}")

    started_at = state.get("started_at", 0)
    if not isinstance(started_at, (int, float)) or started_at <= 0:
        errors.append(f"Invalid started_at: {started_at!r}")

    iteration_budget = state.get("iteration_budget")
    if not isinstance(iteration_budget, int) or iteration_budget < 0:
        errors.append(f"Invalid iteration_budget: {iteration_budget!r}")

    confidence = state.get("last_top_confidence")
    if not isinstance(confidence, (int, float)) or not (0.0 <= float(confidence) <= 1.0):
        errors.append(f"Invalid last_top_confidence: {confidence!r}")

    backoff = state.get("backoff_seconds")
    if not isinstance(backoff, (int, float)) or backoff < 0:
        errors.append(f"Invalid backoff_seconds: {backoff!r}")

    active = state.get("active_seconds")
    if not isinstance(active, (int, float)) or active < 0:
        errors.append(f"Invalid active_seconds: {active!r}")

    wall = state.get("wall_clock_seconds")
    if not isinstance(wall, (int, float)) or wall < 0:
        errors.append(f"Invalid wall_clock_seconds: {wall!r}")

    return errors


# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------


_TERMINAL_STATUSES: frozenset[str] = frozenset({"resolved", "failed", "no_action", "blocked"})


def is_terminal_status(status: str) -> bool:
    """Return whether the status is terminal (no further transitions)."""
    return status in _TERMINAL_STATUSES


def is_success_status(status: str) -> bool:
    """Return whether the status represents a verified resolution.

    Only ``resolved`` counts. ``no_action`` means the agent intentionally
    declined to act and must not be tallied as a resolution in any metric.
    """
    return status == "resolved"


def is_running_status(status: str) -> bool:
    """Return whether the incident is still being investigated."""
    return status == "running"
