"""
Agent state and context definitions for LangGraph orchestration.

AgentState: TypedDict for LangGraph state (fast, no validation overhead on transitions)
SREContext: Dataclass for dependency injection (kr8s, DB sessions, LLM router,
            psycopg pool, valkey client, OpenObserve client)

Why TypedDict for state?
- LangGraph state transitions happen 10-20 times per investigation
- Pydantic validation on every transition adds 50-100ms overhead
- TypedDict is validated once at the boundary (API ingress), not internally

Why dataclass for context?
- Infrastructure clients (kr8s, DB sessions, psycopg pools, redis clients,
  httpx clients) are not serializable
- They can't be checkpointed to Postgres
- They're created once at startup and injected via LangGraph's context_schema
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Annotated, Any, Literal, TypedDict

from langgraph.graph.message import add_messages
from sqlalchemy.ext.asyncio import AsyncSession


class IncidentMetadata(TypedDict):
    """
    Metadata about the current incident.

    Set once at the start of an investigation from the incoming alert webhook.
    Immutable throughout the investigation lifecycle.
    """

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
    """
    LangGraph state for the SRE agent investigation loop.

    Uses TypedDict for performance (no Pydantic validation on every node
    transition). The ``messages`` field uses LangGraph's add_messages reducer
    for automatic history management and tool-result eviction.
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


@dataclass
class SREContext:
    """
    Runtime context for dependency injection into LangGraph nodes.

    This is NOT part of the graph state (not serializable to Postgres).
    Injected via LangGraph's context_schema / Runtime mechanism.

    Contents:
    - db_session: Async SQLAlchemy session for Agent's own state DB
    - k8s_client: kr8s API client for Kubernetes operations
    - llm_router: LiteLLM Router for token-velocity model selection
    - openobserve_client: HTTP client for querying OpenObserve
    - pg_pool: psycopg AsyncConnectionPool for Postgres diagnostic tools
    - valkey_client: redis.asyncio client for Valkey diagnostic tools

    All infrastructure clients are typed as ``Any`` to avoid importing
    heavy I/O libraries (psycopg_pool, redis, httpx) into the core module.
    The concrete types are constructed in ``api/main.py`` at startup and
    injected here.
    """

    db_session: AsyncSession = field(repr=False)

    # Infrastructure clients — all optional, all Any-typed to keep this
    # module free of hard dependencies on I/O libraries.
    k8s_client: Any = field(default=None, repr=False)
    llm_router: Any = field(default=None, repr=False)
    openobserve_client: Any = field(default=None, repr=False)
    pg_pool: Any = field(default=None, repr=False)
    valkey_client: Any = field(default=None, repr=False)

    def __post_init__(self) -> None:
        """Validate that the required db_session is provided."""
        if self.db_session is None:
            raise ValueError("db_session is required for SREContext")


def create_initial_state(incident_metadata: IncidentMetadata) -> AgentState:
    """
    Create the initial state for a new incident investigation.

    Called by the API ingress when a new alert webhook is received.
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
    )
