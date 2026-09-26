"""Integration tests for the LangGraph SRE investigation workflow.

Mocked dependencies:
    LLM router — scripted JSON responses
    Tool registry — read-only + remediation tools
    Safe executor — real ExecutionResult objects
    Policy engine — mocked
    Context eviction — real (pure logic)

Each test injects a RunnableConfig with graph_context and sre_context in
config["configurable"], plus a recursion_limit to prevent infinite loops.
"""

from __future__ import annotations

import json
import time
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest
from pydantic import BaseModel

from autosre.core.context import ContextEviction
from autosre.core.graph import compile_graph
from autosre.core.graph_helpers import PHASE_COMPLETE, PHASE_HYPOTHESIZE
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import (
    INITIAL_ITERATION_BUDGET,
    AgentState,
    IncidentMetadata,
    ProposedAction,
    SREContext,
)
from autosre.safety.executor import ExecutionResult, SafeExecutor
from autosre.safety.policy import PolicyDecision, PolicyEngine, RiskTier
from autosre.tools.registry import ToolRegistry

# ---------------------------------------------------------------------------
# Mock tool input models
# ---------------------------------------------------------------------------


class GetPodEventsInput(BaseModel):
    namespace: str
    pod_name: str


class GetPodLogsInput(BaseModel):
    namespace: str
    pod_name: str
    tail_lines: int = 100


class RestartDeploymentInput(BaseModel):
    namespace: str
    name: str
    reason: str = ""


class TerminateBackendInput(BaseModel):
    pid: int
    reason: str = ""


class DeleteValkeyKeyInput(BaseModel):
    key: str
    reason: str = ""


class ScaleDeploymentInput(BaseModel):
    namespace: str
    name: str
    replicas: int
    reason: str = ""


class MockTool:
    def __init__(
        self,
        name: str,
        description: str,
        risk_tier: int,
        input_model: type[BaseModel],
    ) -> None:
        self.name = name
        self.description = description
        self.risk_tier = risk_tier
        self.input_model = input_model


def _create_mock_tools() -> list[MockTool]:
    return [
        MockTool("get_pod_events", "Retrieve K8s events.", 0, GetPodEventsInput),
        MockTool("get_pod_logs", "Fetch recent logs.", 0, GetPodLogsInput),
        MockTool(
            "restart_deployment",
            "Restart a K8s deployment.",
            RiskTier.REVERSIBLE_LOW,
            RestartDeploymentInput,
        ),
        MockTool(
            "terminate_backend",
            "Terminate one PG backend.",
            RiskTier.REVERSIBLE_LOW,
            TerminateBackendInput,
        ),
        MockTool(
            "delete_valkey_key",
            "Delete one cache key.",
            RiskTier.REVERSIBLE_LOW,
            DeleteValkeyKeyInput,
        ),
        MockTool(
            "scale_deployment",
            "Change replica count.",
            RiskTier.REVERSIBLE_HIGH,
            ScaleDeploymentInput,
        ),
    ]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _llm_response(payload: dict[str, Any]) -> SimpleNamespace:
    """Return an OpenAI-compatible response with JSON content."""
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=json.dumps(payload)))],
        usage=None,
    )


def _make_execution_result(
    *,
    tool_name: str,
    tool_args: dict[str, Any] | None = None,
    executed: bool = True,
    verified: bool | None = True,
    output: dict[str, Any] | None = None,
    risk_tier: int = 1,
) -> ExecutionResult:
    """Build a real ExecutionResult for mocking SafeExecutor.execute."""
    action = ProposedAction(
        tool_name=tool_name,
        tool_args=tool_args or {},
        risk_tier=risk_tier,
        rationale="test",
        requires_approval=False,
    )

    try:
        risk = RiskTier(risk_tier)
    except ValueError:
        risk = RiskTier.REVERSIBLE_LOW

    decision = PolicyDecision(
        allowed=True,
        risk_tier=risk,
        requires_approval=False,
        reason="test",
    )

    if verified is True:
        status = "verified"
    elif verified is False:
        status = "verification_failed"
    else:
        status = "succeeded"

    return ExecutionResult(
        action=action,
        decision=decision,
        status=status,
        executed=executed,
        verified=verified,
        output=output if output is not None else {"status": "success"},
    )


def _build_config(
    thread_id: str,
    graph_ctx: Any,
    sre_ctx: Any,
) -> dict[str, Any]:
    """Build a RunnableConfig with contexts and a recursion limit."""
    return {
        "configurable": {
            "thread_id": thread_id,
            "graph_context": graph_ctx,
            "sre_context": sre_ctx,
        },
        "recursion_limit": 30,
    }


def _build_full_state(sample_metadata: IncidentMetadata, **overrides: Any) -> AgentState:
    """Build a fully-populated AgentState with sensible defaults."""
    base: dict[str, Any] = {
        "messages": [],
        "incident_metadata": sample_metadata,
        "hypotheses": [],
        "proposed_actions": [],
        "executed_actions": [],
        "current_phase": "triage",
        "iteration_count": 0,
        "iteration_budget": INITIAL_ITERATION_BUDGET,
        "last_top_confidence": 0.0,
        "stagnation_count": 0,
        "action_attempts": 0,
        "requires_human_approval": False,
        "approval_granted": None,
        "approval_comment": None,
        "tokens_used": 0,
        "cost_usd": 0.0,
        "wall_clock_seconds": 0.0,
        "backoff_seconds": 0.0,
        "active_seconds": 0.0,
        "started_at": time.time(),
        "status": "running",
    }
    base.update(overrides)
    return AgentState(**base)  # type: ignore[typeddict-item]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_llm_router() -> MagicMock:
    router = MagicMock(spec=TokenVelocityRouter)
    router.acompletion = AsyncMock()
    router.coordinator_call = AsyncMock()
    return router


@pytest.fixture
def mock_tool_registry() -> MagicMock:
    registry = MagicMock(spec=ToolRegistry)
    mock_tools = _create_mock_tools()
    registry.list_tools = MagicMock(return_value=mock_tools)
    registry.get = MagicMock(
        side_effect=lambda name: next((t for t in mock_tools if t.name == name), None)
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
) -> Any:
    from autosre.core.graph_helpers import GraphContext

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
        description="",
        labels={},
        annotations={},
    )


@pytest.fixture
def initial_state(sample_metadata: IncidentMetadata) -> AgentState:
    return _build_full_state(sample_metadata)


# ---------------------------------------------------------------------------
# Full flow configuration
# ---------------------------------------------------------------------------


def _configure_full_flow(
    ctx: Any,
    *,
    hypothesis_confidence: float = 0.9,
    risk_tier: int = 1,
) -> None:
    """Configure LLM + executor mocks for triage → complete."""
    ctx.llm_router.coordinator_call.side_effect = [
        _llm_response(
            {
                "tool_name": "restart_deployment",
                "tool_args": {
                    "namespace": "rivulet",
                    "name": "api-gateway",
                    "reason": "CrashLoopBackOff with OOMKilled evidence",
                },
                "risk_tier": risk_tier,
                "rationale": "Restart the deployment",
            }
        ),
    ]

    ctx.llm_router.acompletion.side_effect = [
        # Triage
        _llm_response(
            {
                "hypotheses": [
                    {
                        "id": "H1",
                        "description": "Pod crash loop due to OOMKilled",
                        "confidence": 0.5,
                        "evidence": ["CrashLoopBackOff"],
                        "status": "proposed",
                    }
                ],
            }
        ),
        # Investigate
        _llm_response(
            {
                "tool_name": "get_pod_events",
                "tool_args": {
                    "namespace": "rivulet",
                    "pod_name": "api-gateway-abc123",
                },
                "rationale": "Checking pod events for OOMKilled",
            }
        ),
        # Hypothesize (refinement)
        _llm_response(
            {
                "hypotheses": [
                    {
                        "id": "H1",
                        "description": "Pod crash loop due to OOMKilled",
                        "confidence": hypothesis_confidence,
                        "evidence": [
                            "CrashLoopBackOff",
                            "OOMKilled event",
                        ],
                        "status": "confirmed",
                    }
                ],
            }
        ),
    ]

    ctx.executor.execute.side_effect = [
        _make_execution_result(
            tool_name="get_pod_events",
            tool_args={
                "namespace": "rivulet",
                "pod_name": "api-gateway-abc123",
            },
            risk_tier=0,
            output={"events": [{"reason": "OOMKilled"}]},
        ),
        _make_execution_result(
            tool_name="restart_deployment",
            tool_args={
                "namespace": "rivulet",
                "name": "api-gateway",
                "reason": "CrashLoopBackOff with OOMKilled evidence",
            },
            risk_tier=1,
            output={"status": "success", "restarted": True},
        ),
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_graph_triage_to_completion(
    initial_state: AgentState,
    investigation_context: Any,
    mock_sre_context: MagicMock,
) -> None:
    """Full investigation reaches completion and executes remediation."""
    _configure_full_flow(investigation_context)

    graph = compile_graph()
    config = _build_config("test-thread-001", investigation_context, mock_sre_context)

    result = await graph.ainvoke(initial_state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert len(result["hypotheses"]) >= 1
    assert result["hypotheses"][0]["id"] == "H1"

    assert len(result["proposed_actions"]) >= 1
    assert result["proposed_actions"][0]["tool_name"] == "restart_deployment"

    assert len(result["executed_actions"]) >= 1
    assert result["executed_actions"][0]["tool_name"] == "restart_deployment"
    assert result["executed_actions"][0]["success"] is True


@pytest.mark.asyncio
async def test_graph_high_confidence_hypothesis_skips_investigation(
    sample_metadata: IncidentMetadata,
    investigation_context: Any,
    mock_sre_context: MagicMock,
) -> None:
    """High-confidence input skips the investigation loop."""
    investigation_context.llm_router.coordinator_call.return_value = _llm_response(
        {
            "tool_name": "restart_deployment",
            "tool_args": {
                "namespace": "rivulet",
                "name": "api-gateway",
                "reason": "Restart after OOM crash loop",
            },
            "risk_tier": 1,
            "rationale": "Restart after OOM crash loop",
        }
    )

    investigation_context.executor.execute.return_value = _make_execution_result(
        tool_name="restart_deployment",
        tool_args={
            "namespace": "rivulet",
            "name": "api-gateway",
            "reason": "Restart after OOM crash loop",
        },
        risk_tier=1,
        output={"status": "success", "restarted": True},
    )

    state = _build_full_state(
        sample_metadata,
        hypotheses=[
            {
                "id": "H1",
                "description": "Pod OOMKilled",
                "confidence": 0.9,
                "evidence": ["OOMKilled event"],
                "status": "confirmed",
            }
        ],
        current_phase=PHASE_HYPOTHESIZE,
        iteration_count=2,
        last_top_confidence=0.9,
    )

    graph = compile_graph()
    config = _build_config("test-thread-002", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert len(result["proposed_actions"]) >= 1
    assert result["proposed_actions"][0]["tool_name"] == "restart_deployment"
    assert len(result["executed_actions"]) >= 1


@pytest.mark.asyncio
async def test_graph_tier1_action_executes_without_hitl(
    sample_metadata: IncidentMetadata,
    investigation_context: Any,
    mock_sre_context: MagicMock,
) -> None:
    """Tier-1 action executes directly without human approval."""
    tool_args = {
        "namespace": "rivulet",
        "name": "api-gateway",
        "reason": "Restart to clear crash loop",
    }

    investigation_context.executor.execute.return_value = _make_execution_result(
        tool_name="restart_deployment",
        tool_args=tool_args,
        risk_tier=1,
        output={"status": "success", "restarted": True},
    )

    state = _build_full_state(
        sample_metadata,
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
                "tool_args": tool_args,
                "risk_tier": 1,
                "rationale": "Restart to clear crash loop",
                "requires_approval": False,
            }
        ],
        current_phase="execute",
        iteration_count=3,
        last_top_confidence=0.9,
    )

    graph = compile_graph()
    config = _build_config("test-thread-004", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert len(result["executed_actions"]) == 1
    assert result["executed_actions"][0]["success"] is True

    # execute → verify → complete does not invoke the LLM.
    investigation_context.llm_router.acompletion.assert_not_awaited()
    investigation_context.executor.execute.assert_awaited_once()


@pytest.mark.asyncio
async def test_graph_respects_max_iterations(
    sample_metadata: IncidentMetadata,
    investigation_context: Any,
    mock_sre_context: MagicMock,
) -> None:
    """At budget exhaustion with low confidence, exit as no_action."""
    investigation_context.llm_router.acompletion.return_value = _llm_response(
        {
            "hypotheses": [
                {
                    "id": "H1",
                    "description": "Unknown issue",
                    "confidence": 0.3,
                    "evidence": ["Unclear logs"],
                    "status": "proposed",
                }
            ],
        }
    )

    state = _build_full_state(
        sample_metadata,
        hypotheses=[
            {
                "id": "H1",
                "description": "Unknown issue",
                "confidence": 0.3,
                "evidence": ["Unclear logs"],
                "status": "proposed",
            }
        ],
        current_phase=PHASE_HYPOTHESIZE,
        iteration_count=5,
        iteration_budget=0,
        last_top_confidence=0.3,
    )

    graph = compile_graph()
    config = _build_config("test-thread-003", investigation_context, mock_sre_context)

    result = await graph.ainvoke(state, config=config)

    assert result["current_phase"] == PHASE_COMPLETE
    assert result["status"] in ("no_action", "failed")
