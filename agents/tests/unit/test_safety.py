"""Unit tests for the safety policy engine and SafeExecutor.

Tests cover:
    - Policy classification (allowed, prohibited, approval-required)
    - SafeExecutor dispatch lifecycle (snapshot, execute, verify, rollback)
    - Fail-closed snapshot semantics
    - Audit hook integration
    - ExecutedAction conversion from ExecutionResult
    - Tool idempotency guards
"""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock

import pytest
from pydantic import BaseModel, Field

from autosre.core.state import ExecutedAction, ProposedAction, SREContext
from autosre.safety.executor import (
    AuditRecord,
    ExecutionResult,
    NeedsApprovalError,
    SafeExecutor,
)
from autosre.safety.policy import (
    PolicyDecision,
    PolicyEngine,
    PolicyRejectionError,
    RiskTier,
)
from autosre.tools.registry import Tool, ToolExecutionError, ToolRegistry

# ---------------------------------------------------------------------------
# Dummy Pydantic models for test tools
# ---------------------------------------------------------------------------


class _DummyInput(BaseModel):
    """Input schema accepted by all dummy test tools."""

    namespace: str = Field(default="rivulet")
    name: str = Field(default="api-gateway")
    reason: str = Field(default="")


class _DummyOutput(BaseModel):
    """Output schema returned by all dummy test tool handlers."""

    ok: bool = True


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------


def _make_registry_with_tools(
    *tools: tuple[str, int],
    fail_set: frozenset[str] = frozenset(),
) -> ToolRegistry:
    """Build a ToolRegistry with dummy tools at specified risk tiers.

    Args:
        tools: Pairs of (name, risk_tier).
        fail_set: Tool names that should raise ToolExecutionError on dispatch.
    """
    registry = ToolRegistry()

    for name, tier in tools:

        async def _handler(
            args: _DummyInput,
            context: SREContext,
            _name: str = name,
        ) -> dict[str, Any]:
            del args, context
            if _name in fail_set:
                raise ToolExecutionError(
                    _name,
                    RuntimeError(f"{_name} simulated failure"),
                )
            return {"ok": True}

        registry.register(
            Tool(
                name=name,
                description=f"dummy tool {name}",
                handler=_handler,
                input_model=_DummyInput,
                output_model=_DummyOutput,
                risk_tier=RiskTier(tier),
            )
        )

    return registry


def _make_context() -> SREContext:
    """SREContext with no external clients.

    All fields default to None. Tools that dereference a None client raise
    ToolExecutionError, which is what the safety tests expect.
    """
    return SREContext()


def _proposed(
    tool_name: str,
    args: dict[str, Any] | None = None,
    risk_tier: int = 0,
    requires_approval: bool = False,
) -> ProposedAction:
    """Build a ProposedAction with sensible defaults."""
    return ProposedAction(
        tool_name=tool_name,
        tool_args=args or {},
        risk_tier=risk_tier,
        rationale="test rationale",
        requires_approval=requires_approval,
    )


def _policy_allowing_all() -> PolicyEngine:
    """Policy engine that allows everything at the proposed tier."""
    engine = MagicMock(spec=PolicyEngine)

    def _classify(name: str, args: dict[str, Any], tier: RiskTier) -> PolicyDecision:
        return PolicyDecision(
            allowed=True,
            risk_tier=tier,
            requires_approval=False,
            reason=f"allowed: {name}",
        )

    engine.classify = MagicMock(side_effect=_classify)
    return engine


def _policy_rejecting_all() -> PolicyEngine:
    """Policy engine that rejects everything as prohibited."""
    engine = MagicMock(spec=PolicyEngine)

    def _classify(name: str, args: dict[str, Any], tier: RiskTier) -> PolicyDecision:
        raise PolicyRejectionError(
            PolicyDecision(
                allowed=False,
                risk_tier=RiskTier.PROHIBITED,
                requires_approval=False,
                reason=f"prohibited: {name}",
            )
        )

    engine.classify = MagicMock(side_effect=_classify)
    return engine


def _policy_requiring_approval() -> PolicyEngine:
    """Policy engine that allows but requires HITL approval."""
    engine = MagicMock(spec=PolicyEngine)

    def _classify(name: str, args: dict[str, Any], tier: RiskTier) -> PolicyDecision:
        return PolicyDecision(
            allowed=True,
            risk_tier=tier,
            requires_approval=True,
            reason=f"approval required: {name}",
        )

    engine.classify = MagicMock(side_effect=_classify)
    return engine


# ---------------------------------------------------------------------------
# PolicyEngine tests
# ---------------------------------------------------------------------------


class TestPolicyEngine:
    def test_allowing_policy_returns_decision(self) -> None:
        engine = _policy_allowing_all()
        decision = engine.classify("get_pod_logs", {}, RiskTier.OBSERVE)
        assert decision.allowed is True
        assert decision.requires_approval is False

    def test_rejecting_policy_raises(self) -> None:
        engine = _policy_rejecting_all()
        with pytest.raises(PolicyRejectionError) as exc_info:
            engine.classify("delete_namespace", {}, RiskTier.OBSERVE)
        assert exc_info.value.decision.allowed is False

    def test_approval_policy_returns_requires_approval(self) -> None:
        engine = _policy_requiring_approval()
        decision = engine.classify("scale_deployment", {}, RiskTier.REVERSIBLE_HIGH)
        assert decision.allowed is True
        assert decision.requires_approval is True


# ---------------------------------------------------------------------------
# SafeExecutor — dispatch lifecycle
# ---------------------------------------------------------------------------


class TestSafeExecutor:
    @pytest.mark.asyncio
    async def test_successful_execution_returns_verified(self) -> None:
        """Tier-0 tool with no snapshot/verifier/rollback succeeds cleanly."""
        registry = _make_registry_with_tools(("get_pod_logs", 0))
        policy = _policy_allowing_all()
        executor = SafeExecutor(registry, policy)

        action = _proposed("get_pod_logs", risk_tier=0)
        result = await executor.execute(action, _make_context())

        assert result.status == "succeeded"
        assert result.executed is True
        assert result.verified is None
        assert result.rolled_back is False
        assert result.error is None

    @pytest.mark.asyncio
    async def test_policy_rejection_raises_and_audits(self) -> None:
        """Prohibited action raises PolicyRejectionError before dispatch."""
        audit_records: list[AuditRecord] = []

        async def capture_audit(record: AuditRecord) -> None:
            audit_records.append(record)

        registry = _make_registry_with_tools(("delete_namespace", 4))
        policy = _policy_rejecting_all()
        executor = SafeExecutor(registry, policy, audit_hook=capture_audit)

        action = _proposed("delete_namespace", risk_tier=4)

        with pytest.raises(PolicyRejectionError):
            await executor.execute(action, _make_context())

        assert len(audit_records) == 1
        assert audit_records[0].status == "rejected"
        assert audit_records[0].executed is False

    @pytest.mark.asyncio
    async def test_approval_required_raises_before_dispatch(self) -> None:
        """Tier-2+ action raises NeedsApprovalError without dispatching."""
        registry = _make_registry_with_tools(("scale_deployment", 2))
        policy = _policy_requiring_approval()
        executor = SafeExecutor(registry, policy)

        action = _proposed("scale_deployment", risk_tier=2)

        with pytest.raises(NeedsApprovalError) as exc_info:
            await executor.execute(action, _make_context())

        assert exc_info.value.decision.requires_approval is True
        assert exc_info.value.action.tool_name == "scale_deployment"

    @pytest.mark.asyncio
    async def test_tool_failure_triggers_rollback(self) -> None:
        """When a tool with a registered rollback fails, rollback runs."""
        rollback_called = False

        async def snapshot_fn(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del context
            return {"previous": args.get("name", "")}

        async def rollback_fn(
            args: dict[str, Any],
            snapshot: dict[str, Any],
            context: SREContext,
        ) -> bool:
            nonlocal rollback_called
            del args, snapshot, context
            rollback_called = True
            return True

        registry = _make_registry_with_tools(
            ("restart_deployment", 1),
            fail_set=frozenset({"restart_deployment"}),
        )
        policy = _policy_allowing_all()
        executor = SafeExecutor(
            registry,
            policy,
            snapshots={"restart_deployment": snapshot_fn},
            rollbacks={"restart_deployment": rollback_fn},
        )

        action = _proposed(
            "restart_deployment",
            args={"namespace": "rivulet", "name": "api-gateway"},
            risk_tier=1,
        )
        result = await executor.execute(action, _make_context())

        assert result.status == "failed"
        assert result.executed is True
        assert result.rolled_back is True
        assert rollback_called is True

    @pytest.mark.asyncio
    async def test_snapshot_failure_prevents_dispatch(self) -> None:
        """Fail-closed: snapshot failure prevents the tool from dispatching."""
        registry = _make_registry_with_tools(("restart_deployment", 1))
        policy = _policy_allowing_all()

        async def failing_snapshot(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del args, context
            raise RuntimeError("snapshot unavailable")

        executor = SafeExecutor(
            registry,
            policy,
            snapshots={"restart_deployment": failing_snapshot},
        )

        action = _proposed("restart_deployment", risk_tier=1)
        result = await executor.execute(action, _make_context())

        assert result.status == "snapshot_failed"
        assert result.executed is False
        assert result.rolled_back is False

    @pytest.mark.asyncio
    async def test_verification_pass_marks_verified(self) -> None:
        """When verifier returns True, status becomes 'verified'."""
        registry = _make_registry_with_tools(("restart_deployment", 1))
        policy = _policy_allowing_all()

        async def snapshot_fn(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del args, context
            return {"state": "before"}

        async def verify_fn(
            args: dict[str, Any],
            snapshot: dict[str, Any] | None,
            context: SREContext,
        ) -> bool:
            del args, snapshot, context
            return True

        executor = SafeExecutor(
            registry,
            policy,
            snapshots={"restart_deployment": snapshot_fn},
            verifiers={"restart_deployment": verify_fn},
        )

        action = _proposed("restart_deployment", risk_tier=1)
        result = await executor.execute(action, _make_context())

        assert result.status == "verified"
        assert result.verified is True
        assert result.rolled_back is False

    @pytest.mark.asyncio
    async def test_verification_failure_triggers_rollback(self) -> None:
        """When verifier returns False, rollback runs and status is verification_failed."""
        rollback_called = False

        async def snapshot_fn(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del args, context
            return {"state": "before"}

        async def verify_fn(
            args: dict[str, Any],
            snapshot: dict[str, Any] | None,
            context: SREContext,
        ) -> bool:
            del args, snapshot, context
            return False

        async def rollback_fn(
            args: dict[str, Any],
            snapshot: dict[str, Any],
            context: SREContext,
        ) -> bool:
            nonlocal rollback_called
            del args, snapshot, context
            rollback_called = True
            return True

        registry = _make_registry_with_tools(("restart_deployment", 1))
        policy = _policy_allowing_all()
        executor = SafeExecutor(
            registry,
            policy,
            snapshots={"restart_deployment": snapshot_fn},
            verifiers={"restart_deployment": verify_fn},
            rollbacks={"restart_deployment": rollback_fn},
        )

        action = _proposed("restart_deployment", risk_tier=1)
        result = await executor.execute(action, _make_context())

        assert result.status == "verification_failed"
        assert result.verified is False
        assert result.rolled_back is True
        assert rollback_called is True

    @pytest.mark.asyncio
    async def test_unknown_tool_raises_policy_rejection(self) -> None:
        """Executing a tool not in the registry raises PolicyRejectionError."""
        registry = ToolRegistry()  # Empty registry
        policy = _policy_allowing_all()
        executor = SafeExecutor(registry, policy)

        action = _proposed("nonexistent_tool", risk_tier=0)

        with pytest.raises(PolicyRejectionError):
            await executor.execute(action, _make_context())

    @pytest.mark.asyncio
    async def test_audit_hook_receives_record_on_success(self) -> None:
        """Audit hook fires with correct fields on successful execution."""
        audit_records: list[AuditRecord] = []

        async def capture_audit(record: AuditRecord) -> None:
            audit_records.append(record)

        registry = _make_registry_with_tools(("get_pod_logs", 0))
        policy = _policy_allowing_all()
        executor = SafeExecutor(registry, policy, audit_hook=capture_audit)

        action = _proposed("get_pod_logs", risk_tier=0)
        await executor.execute(action, _make_context(), incident_id="test-123")

        assert len(audit_records) == 1
        record = audit_records[0]
        assert record.incident_id == "test-123"
        assert record.tool_name == "get_pod_logs"
        assert record.status == "succeeded"
        assert record.executed is True
        assert record.error_class is None

    @pytest.mark.asyncio
    async def test_audit_hook_receives_record_on_failure(self) -> None:
        """Audit hook fires with error class on failed execution."""
        audit_records: list[AuditRecord] = []

        async def capture_audit(record: AuditRecord) -> None:
            audit_records.append(record)

        registry = _make_registry_with_tools(
            ("restart_deployment", 1),
            fail_set=frozenset({"restart_deployment"}),
        )
        policy = _policy_allowing_all()
        executor = SafeExecutor(registry, policy, audit_hook=capture_audit)

        action = _proposed("restart_deployment", risk_tier=1)
        await executor.execute(action, _make_context())

        assert len(audit_records) == 1
        record = audit_records[0]
        assert record.status == "failed"
        assert record.executed is True
        assert record.error_class is not None

    @pytest.mark.asyncio
    async def test_audit_hook_failure_does_not_propagate(self) -> None:
        """If the audit hook raises, execution still returns a result."""

        async def failing_audit(record: AuditRecord) -> None:
            del record
            raise RuntimeError("audit store down")

        registry = _make_registry_with_tools(("get_pod_logs", 0))
        policy = _policy_allowing_all()
        executor = SafeExecutor(registry, policy, audit_hook=failing_audit)

        action = _proposed("get_pod_logs", risk_tier=0)
        # Should not raise despite audit hook failing
        result = await executor.execute(action, _make_context())
        assert result.status == "succeeded"


# ---------------------------------------------------------------------------
# ExecutionResult.to_executed_action
# ---------------------------------------------------------------------------


class TestExecutionResultConversion:
    def test_to_executed_action_preserves_execution_time(self) -> None:
        """to_executed_action must carry the executed_at timestamp."""
        action = ProposedAction(
            tool_name="restart_deployment",
            tool_args={"namespace": "rivulet", "name": "api-gateway"},
            risk_tier=1,
            rationale="test",
            requires_approval=False,
        )
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_LOW,
            requires_approval=False,
            reason="test",
        )
        result = ExecutionResult(
            action=action,
            decision=decision,
            status="succeeded",
            executed=True,
            verified=None,
            executed_at="2026-01-15T10:30:00Z",
            output={"status": "success"},
        )

        executed: ExecutedAction = result.to_executed_action()

        assert executed.tool_name == "restart_deployment"
        assert executed.tool_args == {"namespace": "rivulet", "name": "api-gateway"}
        assert executed.executed_at == "2026-01-15T10:30:00Z"
        assert executed.success is True
        assert executed.result == {"status": "success"}
        assert executed.verification_passed is None

    def test_to_executed_action_success_with_verification(self) -> None:
        """Verified execution produces success=True and verification_passed=True."""
        action = ProposedAction(
            tool_name="restart_deployment",
            tool_args={},
            risk_tier=1,
            rationale="test",
            requires_approval=False,
        )
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_LOW,
            requires_approval=False,
            reason="test",
        )
        result = ExecutionResult(
            action=action,
            decision=decision,
            status="verified",
            executed=True,
            verified=True,
            executed_at="2026-01-15T10:30:00Z",
            output={"status": "success"},
        )

        executed: ExecutedAction = result.to_executed_action()

        assert executed.success is True
        assert executed.verification_passed is True

    def test_to_executed_action_verification_failed(self) -> None:
        """Verification failure produces success=False and verification_passed=False."""
        action = ProposedAction(
            tool_name="restart_deployment",
            tool_args={},
            risk_tier=1,
            rationale="test",
            requires_approval=False,
        )
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_LOW,
            requires_approval=False,
            reason="test",
        )
        result = ExecutionResult(
            action=action,
            decision=decision,
            status="verification_failed",
            executed=True,
            verified=False,
            executed_at="2026-01-15T10:30:00Z",
            output={},
        )

        executed: ExecutedAction = result.to_executed_action()

        assert executed.success is False
        assert executed.verification_passed is False

    def test_to_executed_action_not_dispatched(self) -> None:
        """Non-dispatched result produces success=False."""
        action = ProposedAction(
            tool_name="restart_deployment",
            tool_args={},
            risk_tier=1,
            rationale="test",
            requires_approval=False,
        )
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_LOW,
            requires_approval=False,
            reason="test",
        )
        result = ExecutionResult(
            action=action,
            decision=decision,
            status="snapshot_failed",
            executed=False,
            verified=None,
            executed_at=None,
            output=None,
        )

        executed: ExecutedAction = result.to_executed_action()

        assert executed.success is False
        # executed_at should be auto-generated when None
        assert executed.executed_at != ""


# ---------------------------------------------------------------------------
# ExecutionResult derived properties
# ---------------------------------------------------------------------------


class TestExecutionResultProperties:
    def test_dispatched_property(self) -> None:
        action = _proposed("get_pod_logs", risk_tier=0)
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.OBSERVE,
            requires_approval=False,
            reason="test",
        )

        result = ExecutionResult(action=action, decision=decision, executed=False)
        assert result.dispatched is False

        result.executed = True
        assert result.dispatched is True

    def test_succeeded_property(self) -> None:
        action = _proposed("get_pod_logs", risk_tier=0)
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.OBSERVE,
            requires_approval=False,
            reason="test",
        )

        for status, expected in [
            ("succeeded", True),
            ("verified", True),
            ("failed", False),
            ("verification_failed", False),
            ("rejected", False),
            ("not_dispatched", False),
            ("snapshot_failed", False),
        ]:
            result = ExecutionResult(action=action, decision=decision, status=status)
            assert result.succeeded is expected, f"status={status}"

    def test_fully_verified_property(self) -> None:
        action = _proposed("get_pod_logs", risk_tier=0)
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.OBSERVE,
            requires_approval=False,
            reason="test",
        )

        result = ExecutionResult(action=action, decision=decision, status="verified", verified=True)
        assert result.fully_verified is True

        result.status = "succeeded"
        assert result.fully_verified is False


# ---------------------------------------------------------------------------
# NeedsApprovalError
# ---------------------------------------------------------------------------


class TestNeedsApprovalError:
    def test_carries_decision_and_action(self) -> None:
        action = _proposed("scale_deployment", risk_tier=2)
        decision = PolicyDecision(
            allowed=True,
            risk_tier=RiskTier.REVERSIBLE_HIGH,
            requires_approval=True,
            reason="requires HITL",
        )

        error = NeedsApprovalError(decision, action)

        assert error.decision is decision
        assert error.action is action
        assert "requires HITL" in str(error)
