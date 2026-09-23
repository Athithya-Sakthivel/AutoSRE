"""Agent state and context definitions for LangGraph orchestration.

This module defines:
- IncidentMetadata: typed webhook payload metadata
- Hypothesis, ProposedAction, ExecutedAction: investigation artifacts
- AgentState: the LangGraph state schema
- SREContext: runtime dependency injection container
- create_initial_state: factory for new incident investigations
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Annotated, Any, Literal, NotRequired, TypedDict

from langgraph.graph.message import add_messages
from sqlalchemy.ext.asyncio import AsyncSession

# ---------------------------------------------------------------------------
# Metadata and artifact types
# ---------------------------------------------------------------------------


class IncidentMetadata(TypedDict):
    """Metadata associated with an incident alert.

    Required fields come from AlertPayload in routes.py.
    Optional fields (description, labels, annotations) are populated
    when present in the incoming webhook payload.
    """

    incident_id: str
    alert_name: str
    service: str
    namespace: str
    severity: str
    started_at: str
    fingerprint: str

    # Optional alert payload fields
    description: NotRequired[str]
    labels: NotRequired[dict[str, str]]
    annotations: NotRequired[dict[str, str]]


class Hypothesis(TypedDict):
    """A hypothesis about the root cause of an incident."""

    id: str
    description: str
    confidence: float
    evidence: list[str]
    status: Literal["proposed", "confirmed", "rejected"]


class ProposedAction(TypedDict):
    """An action proposed by the agent for remediation."""

    tool_name: str
    tool_args: dict[str, Any]
    risk_tier: int
    rationale: str
    requires_approval: bool


class ExecutedAction(TypedDict):
    """An action that was executed by the SafeExecutor."""

    tool_name: str
    tool_args: dict[str, Any]
    tool_call_id: str
    result: Any
    success: bool
    executed_at: str
    verification_passed: bool | None


# ---------------------------------------------------------------------------
# LangGraph state schema
# ---------------------------------------------------------------------------


class AgentState(TypedDict):
    """LangGraph state for the SRE agent investigation loop.

    The ``messages`` field uses LangGraph's ``add_messages`` reducer so that
    each node can append messages without overwriting previous ones.

    ``consecutive_tool_failures`` tracks tool execution failures to prevent
    infinite loops when tools are misconfigured or unavailable.
    """

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
    consecutive_tool_failures: int


# ---------------------------------------------------------------------------
# Runtime dependency injection
# ---------------------------------------------------------------------------


@dataclass
class SREContext:
    """Runtime context for dependency injection into LangGraph nodes.

    Carries all external resources that tools and nodes need:
    database sessions, LLM clients, K8s client, observability client,
    and diagnostic pools.

    ``db_session`` may be None when the agent uses ``pg_pool`` directly
    for raw SQL queries rather than SQLAlchemy ORM.
    """

    db_session: AsyncSession | None = field(default=None, repr=False)
    llm_config: Any = field(default=None, repr=False)
    k8s_client: Any = field(default=None, repr=False)
    llm_router: Any = field(default=None, repr=False)
    openobserve_client: Any = field(default=None, repr=False)
    pg_pool: Any = field(default=None, repr=False)
    valkey_client: Any = field(default=None, repr=False)


# ---------------------------------------------------------------------------
# State factory
# ---------------------------------------------------------------------------


def create_initial_state(
    incident_metadata: IncidentMetadata,
) -> AgentState:
    """Create the initial state for a new incident investigation.

    All investigation artifacts start empty. The agent begins in the
    ``triage`` phase with zero iterations and no cost accrued.
    """
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
