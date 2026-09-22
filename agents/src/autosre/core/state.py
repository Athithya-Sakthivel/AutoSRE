"""Agent state and context definitions for LangGraph orchestration."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Annotated, Any, Literal, TypedDict

from langgraph.graph.message import add_messages
from sqlalchemy.ext.asyncio import AsyncSession


class IncidentMetadata(TypedDict):
    """Metadata about the current incident."""

    incident_id: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    fingerprint: str


class Hypothesis(TypedDict):
    """A hypothesis about the root cause."""

    id: str
    description: str
    confidence: float
    evidence: list[str]
    status: Literal["proposed", "confirmed", "rejected"]


class ProposedAction(TypedDict):
    """An action proposed by the agent."""

    tool_name: str
    tool_args: dict[str, Any]
    risk_tier: int
    rationale: str
    requires_approval: bool


class ExecutedAction(TypedDict):
    """An action that was executed."""

    tool_name: str
    tool_args: dict[str, Any]
    tool_call_id: str
    result: Any
    success: bool
    executed_at: str
    verification_passed: bool | None


class AgentState(TypedDict):
    """LangGraph state for the SRE agent investigation loop."""

    messages: Annotated[list[dict[str, Any]], add_messages]
    incident_metadata: IncidentMetadata
    hypotheses: list[Hypothesis]
    proposed_actions: list[ProposedAction]
    executed_actions: list[ExecutedAction]
    current_phase: Literal[
        "triage",
        "investigate",
        "hypothesize",
        "propose",
        "execute",
        "verify",
        "complete",
    ]
    iteration_count: int
    requires_human_approval: bool
    approval_granted: bool | None
    tokens_used: int
    cost_usd: float
    wall_clock_seconds: float
    started_at: float
    # Tracks consecutive tool execution failures. When this exceeds a
    # threshold the investigate_node escalates to hypothesis refinement
    # rather than looping forever on broken tools.
    consecutive_tool_failures: int


@dataclass
class SREContext:
    """Runtime context for dependency injection into LangGraph nodes."""

    db_session: AsyncSession = field(repr=False)
    llm_config: Any = field(default=None, repr=False)
    k8s_client: Any = field(default=None, repr=False)
    llm_router: Any = field(default=None, repr=False)
    openobserve_client: Any = field(default=None, repr=False)
    pg_pool: Any = field(default=None, repr=False)
    valkey_client: Any = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if self.db_session is None:
            raise ValueError("db_session is required for SREContext")


def create_initial_state(incident_metadata: IncidentMetadata) -> AgentState:
    """Create the initial state for a new incident investigation."""
    return AgentState(
        messages=[],
        incident_metadata=incident_metadata,
        hypotheses=[],
        proposed_actions=[],
        executed_actions=[],
        current_phase="triage",
        iteration_count=0,
        requires_human_approval=False,
        approval_granted=None,
        tokens_used=0,
        cost_usd=0.0,
        wall_clock_seconds=0.0,
        started_at=time.monotonic(),
        consecutive_tool_failures=0,
    )
