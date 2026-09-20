"""Integration tests for the LangGraph SRE investigation workflow.

These tests exercise the compiled graph with mocked dependencies:
- LLM router (TokenVelocityRouter) — scripted JSON responses
- Tool registry (ToolRegistry) — pre-configured read-only and remediation tools
- Safe executor (SafeExecutor) — scripted ExecutionResult objects
- Policy engine (PolicyEngine) — mocked
- Context eviction (ContextEviction) — real (pure logic, no deps)

Each test injects a RunnableConfig with `graph_context` and `sre_context`
into `config["configurable"]`, and a `recursion_limit` to prevent infinite
loops from causing OOM.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest

from autosre.core.context import ContextEviction
from autosre.core.graph import compile_graph
from autosre.core.graph_helpers import (
    MAX_ITERATIONS,
    PHASE_COMPLETE,
    PHASE_HYPOTHESIZE,
    GraphContext,
)
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import AgentState, IncidentMetadata, SREContext
from autosre.safety.executor import SafeExecutor
from autosre.safety.policy import PolicyEngine
from autosre.tools.registry import ToolRegistry

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _llm_response(payload: dict[str, Any]) -> SimpleNamespace:
    """Create an OpenAI-compatible response object for the router mock."""
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(payload)))]
    )


def _build_config(
    thread_id: str,
    graph_ctx: GraphContext,
    sre_ctx: SREContext,
) -> dict[str, Any]:
    """Build a RunnableConfig with graph_context, sre_context, and recursion_limit.

    The recursion_limit is critical: without it, a routing bug or mock
    misconfiguration can cause an infinite graph loop that accumulates
    unbounded state and OOMs the process.
    """
    return {
        "configurable": {
            "thread_id": thread_id,
            "graph_context": graph_ctx,
            "sre_context": sre_ctx,
        },
        "recursion_limit": 30,
    }


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_llm_router() -> MagicMock:
    router = MagicMock(spec=TokenVelocityRouter)
    router.acompletion = AsyncMock()
    return router


@pytest.fixture
def mock_tool_registry() -> MagicMock:
    registry = MagicMock(spec=ToolRegistry)
    registry.list_tools = MagicMock(
        return_value=[
            SimpleNamespace(
                name="get_pod_events",
                description="Retrieve Kubernetes events for a pod.",
                risk_tier=0,
            ),
            SimpleNamespace(
                name="get_pod_logs",
                description="Fetch recent logs from a pod.",
                risk_tier=0,
            ),
            SimpleNamespace(
                name="restart_deployment",
                description="Restart a Kubernetes deployment.",
                risk_tier=1,
            ),
            SimpleNamespace(
                name="terminate_backend",
                description="Terminate one PostgreSQL backend connection.",
                risk_tier=1,
            ),
            SimpleNamespace(
                name="delete_valkey_key",
                description="Delete one cache key.",
                risk_tier=1,
            ),
            SimpleNamespace(
                name="scale_deployment",
                description="Change the replica count for a deployment.",
                risk_tier=2,
            ),
        ]
    )
    return registry


@pytest.fixture
def mock_safe_executor() -> MagicMock:
    executor = MagicMock(spec=SafeExecutor)
    executor.execute = AsyncMock()
    return executor


@pytest.fixture
def mock_policy_engine() -> MagicMock:
    return MagicMock(spec=PolicyEngine)


@pytest.fixture
def context_eviction() -> ContextEviction:
    return ContextEviction()


@pytest.fixture
def mock_sre_context() -> MagicMock:
    return MagicMock(spec=SREContext)


@pytest.fixture
def investigation_context(
    mock_llm_router: MagicMock,
    mock_tool_registry: MagicMock,
    mock_safe_executor: MagicMock,
    mock_policy_engine: MagicMock,
    context_eviction: ContextEviction,
) -> GraphContext:
    """Build GraphContext with all 5 required fields."""
    return GraphContext(
        llm_router=mock_llm_router,
        registry=mock_tool_registry,
        executor=mock_safe_executor,
        policy_engine=mock_policy_engine,
        context_eviction=context_eviction,
    )


@pytest.fixture
def sample_metadata() -> IncidentMetadata:
    return IncidentMetadata(
        incident_id="test-incident-001",
        alert_name="PodCrashLooping",
        service="api-gateway",
        namespace="rivulet",
        severity="sev2",
        started_at="2026-09-20T10:00:00Z",
        fingerprint="crash-loop-123",
    )


@pytest.fixture
def initial_state(sample_metadata: IncidentMetadata) -> AgentState:
    return AgentState(
        messages=[],
        incident_metadata=sample_metadata,
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


# ---------------------------------------------------------------------------
# Mock configuration helpers
# ---------------------------------------------------------------------------


def _configure_full_flow(
    ctx: GraphContext,
    *,
    hypothesis_confidence: float = 0.9,
    risk_tier: int = 1,
) -> None:
    """Configure 4 LLM calls + 2 executor calls for a full triage→complete flow."""
    ctx.llm_router.acompletion.side_effect = [
        # 1. Triage
        _llm_response(
            {
                "hypotheses": [
                    {
                        "id": "H1",
                        "description": "Pod crash loop due to OOMKilled",
                        "confidence": 0.5,
                        "evidence": ["CrashLoopBackOff", "high restart count"],
                    }
                ],
            }
        ),
        # 2. Investigation tool selection
        _llm_response(
            {
                "tool_name": "get_pod_events",
                "tool_args": {"namespace": "rivulet", "pod_name": "api-gateway-abc123"},
                "rationale": "Checking pod events for OOMKilled",
            }
        ),
        # 3. Hypothesis refinement
        _llm_response(
            {
                "hypotheses": [
                    {
                        "id": "H1",
                        "description": "Pod crash loop due to OOMKilled",
                        "confidence": hypothesis_confidence,
                        "evidence": ["CrashLoopBackOff", "high restart count", "OOMKilled event"],
                        "status": "confirmed",
                    }
                ],
            }
        ),
        # 4. Proposal
        _llm_response(
            {
                "tool_name": "restart_deployment",
                "tool_args": {
                    "namespace": "rivulet",
                    "name": "api-gateway",
                    "reason": "CrashLoopBackOff with OOMKilled evidence",
                },
                "risk_tier": risk_tier,
                "rationale": "Restart the deployment after confirming the crash loop",
            }
        ),
    ]

    ctx.executor.execute.side_effect = [
        # Investigation tool result
        SimpleNamespace(
            output={"events": [{"reason": "OOMKilled"}]},
            executed=True,
            error=None,
            verified=True,
        ),
        # Remediation execution result
        SimpleNamespace(
            output={"status": "success"},
            executed=True,
            error=None,
            verified=True,
        ),
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_graph_triage_to_completion(
    initial_state: AgentState,
    investigation_context: GraphContext,
    mock_sre_context: MagicMock,
) -> None:
    """Full investigation reaches completion and executes remediation."""
    _configure_full_flow(investigation_context)

    graph = compile_graph()
    config = _build_config("test-thread-001", investigation_context, mock_sre_context)

    result = await graph.ainvoke(initial_state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert result["hypotheses"][0]["id"] == "H1"
    assert result["hypotheses"][0]["confidence"] == pytest.approx(0.9)
    assert result["proposed_actions"][0]["tool_name"] == "restart_deployment"
    assert result["proposed_actions"][0]["risk_tier"] == 1
    assert result["executed_actions"][0]["success"] is True
    assert result["executed_actions"][0]["verification_passed"] is True


@pytest.mark.asyncio
async def test_graph_high_confidence_hypothesis_skips_investigation(
    sample_metadata: IncidentMetadata,
    investigation_context: GraphContext,
    mock_sre_context: MagicMock,
) -> None:
    """High-confidence input skips the investigation loop."""
    investigation_context.llm_router.acompletion.return_value = _llm_response(
        {
            "tool_name": "restart_deployment",
            "tool_args": {"namespace": "rivulet", "name": "api-gateway"},
            "risk_tier": 1,
            "rationale": "Restart after confirmed OOM crash loop",
        }
    )

    investigation_context.executor.execute.return_value = SimpleNamespace(
        output={"status": "success"},
        executed=True,
        error=None,
        verified=True,
    )

    state = AgentState(
        messages=[],
        incident_metadata=sample_metadata,
        hypotheses=[
            {
                "id": "H1",
                "description": "Pod OOMKilled",
                "confidence": 0.9,
                "evidence": ["OOMKilled event"],
                "status": "confirmed",
            }
        ],
        proposed_actions=[],
        executed_actions=[],
        current_phase=PHASE_HYPOTHESIZE,
        iteration_count=2,
        requires_human_approval=False,
        approval_granted=None,
        tokens_used=0,
        cost_usd=0.0,
        wall_clock_seconds=0.0,
    )

    graph = compile_graph()
    config = _build_config("test-thread-002", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert result["proposed_actions"][0]["tool_name"] == "restart_deployment"
    # Only 1 LLM call: propose (hypothesize saw confidence >= 0.8 and routed to propose)
    investigation_context.llm_router.acompletion.assert_awaited_once()


@pytest.mark.asyncio
async def test_graph_respects_max_iterations(
    sample_metadata: IncidentMetadata,
    investigation_context: GraphContext,
    mock_sre_context: MagicMock,
) -> None:
    """At MAX_ITERATIONS, the graph moves to proposal even with low confidence."""
    investigation_context.llm_router.acompletion.return_value = _llm_response(
        {
            "tool_name": "restart_deployment",
            "tool_args": {"namespace": "rivulet", "name": "api-gateway"},
            "risk_tier": 1,
            "rationale": "Attempt a safe restart after exhausting evidence",
        }
    )

    investigation_context.executor.execute.return_value = SimpleNamespace(
        output={"status": "success"},
        executed=True,
        error=None,
        verified=True,
    )

    state = AgentState(
        messages=[],
        incident_metadata=sample_metadata,
        hypotheses=[
            {
                "id": "H1",
                "description": "Unknown issue",
                "confidence": 0.3,
                "evidence": ["Unclear logs"],
                "status": "proposed",
            }
        ],
        proposed_actions=[],
        executed_actions=[],
        current_phase=PHASE_HYPOTHESIZE,
        iteration_count=MAX_ITERATIONS,
        requires_human_approval=False,
        approval_granted=None,
        tokens_used=0,
        cost_usd=0.0,
        wall_clock_seconds=0.0,
    )

    graph = compile_graph()
    config = _build_config("test-thread-003", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert result["proposed_actions"][0]["tool_name"] == "restart_deployment"
    investigation_context.llm_router.acompletion.assert_awaited_once()


@pytest.mark.asyncio
async def test_graph_tier1_action_executes_without_hitl(
    sample_metadata: IncidentMetadata,
    investigation_context: GraphContext,
    mock_sre_context: MagicMock,
) -> None:
    """Tier-1 action executes directly without human approval.

    Starts at 'execute' phase to test only the execute→verify→complete path.
    This avoids entering the propose→investigate loop which would cause
    infinite recursion with mocked tools.
    """
    investigation_context.executor.execute.return_value = SimpleNamespace(
        output={"status": "success"},
        executed=True,
        error=None,
        verified=True,
    )

    state = AgentState(
        messages=[],
        incident_metadata=sample_metadata,
        hypotheses=[
            {
                "id": "H1",
                "description": "Crash loop",
                "confidence": 0.9,
                "evidence": ["CrashLoopBackOff"],
                "status": "confirmed",
            }
        ],
        proposed_actions=[
            {
                "tool_name": "restart_deployment",
                "tool_args": {"namespace": "rivulet", "name": "api-gateway"},
                "risk_tier": 1,
                "rationale": "Restart to clear crash loop",
                "requires_approval": False,
            }
        ],
        executed_actions=[],
        current_phase="execute",  # Start here to test execute→verify→complete only
        iteration_count=3,
        requires_human_approval=False,
        approval_granted=None,
        tokens_used=0,
        cost_usd=0.0,
        wall_clock_seconds=0.0,
    )

    graph = compile_graph()
    config = _build_config("test-thread-004", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert len(result["executed_actions"]) == 1
    assert result["executed_actions"][0]["success"] is True
    investigation_context.llm_router.acompletion.assert_not_awaited()
    investigation_context.executor.execute.assert_awaited_once()
