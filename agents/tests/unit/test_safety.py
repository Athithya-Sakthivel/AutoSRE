"""Unit tests for the Phase 6 safety policy and execution boundary."""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock

import pytest
from pydantic import BaseModel, Field

from autosre.core.state import ProposedAction, SREContext
from autosre.safety.executor import NeedsApprovalError, SafeExecutor
from autosre.safety.policy import PolicyEngine, PolicyRejectionError, RiskTier
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)


class _DummyInput(ToolInputModel):
    namespace: str = Field(default="rivulet")
    name: str = Field(default="api-gateway")
    reason: str = Field(default="")  # accepted by all tool arg dicts in tests


class _DummyOutput(BaseModel):
    ok: bool = True


def _make_registry_with_tools(
    *names_and_tiers: tuple[str, int],
    fail_on: set[str] | None = None,
) -> ToolRegistry:
    """Build a registry of dummy tools, optionally making some fail."""
    fail_set = fail_on or set()
    registry = ToolRegistry()

    for name, tier in names_and_tiers:

        async def _maybe_fail(
            args: BaseModel,
            context: SREContext,
            _name: str = name,
        ) -> _DummyOutput:
            del args, context

            if _name in fail_set:
                raise ToolExecutionError(
                    _name,
                    RuntimeError(f"{_name} simulated failure"),
                )

            return _DummyOutput(ok=True)

        registry.register(
            Tool(
                name=name,
                description=f"dummy tool {name}",
                input_model=_DummyInput,
                output_model=_DummyOutput,
                handler=_maybe_fail,
                risk_tier=tier,
            )
        )

    return registry


def _make_context() -> SREContext:
    """SREContext with no external clients.

    Tools that require pg_pool/valkey_client/k8s_client will raise
    ToolExecutionError, which is what the safety tests expect.
    """
    return SREContext()


def _proposed(
    tool_name: str,
    args: dict[str, Any] | None = None,
    risk_tier: int = 0,
    requires_approval: bool = False,
) -> ProposedAction:
    return ProposedAction(
        tool_name=tool_name,
        tool_args=args or {},
        risk_tier=risk_tier,
        rationale="unit test",
        requires_approval=requires_approval,
    )


class TestPolicyEngine:
    """Direct tests of the policy classifier."""

    def test_classifies_tier1_restart(self) -> None:
        decision = PolicyEngine().classify(
            "restart_deployment",
            {
                "namespace": "rivulet",
                "name": "api-gateway",
                "reason": "test",
            },
        )

        assert decision.allowed is True
        assert decision.risk_tier == RiskTier.REVERSIBLE_LOW
        assert decision.requires_approval is False

    def test_classifies_tier4_delete_namespace(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "delete_namespace",
                {"namespace": "rivulet"},
            )

        decision = exc_info.value.decision
        assert decision.risk_tier == RiskTier.PROHIBITED
        assert decision.allowed is False

    @pytest.mark.parametrize(
        ("tool_name", "args"),
        [
            ("flush_all", {}),
            ("drop_table", {"table": "users"}),
        ],
    )
    def test_classifies_prohibited_tools(
        self,
        tool_name: str,
        args: dict[str, Any],
    ) -> None:
        with pytest.raises(PolicyRejectionError):
            PolicyEngine().classify(tool_name, args)

    def test_rejects_system_namespace(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "restart_deployment",
                {
                    "namespace": "kube-system",
                    "name": "coredns",
                },
            )

        assert "kube-system" in exc_info.value.decision.reason

    def test_rejects_unlisted_namespace(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "restart_deployment",
                {
                    "namespace": "production",
                    "name": "api-gateway",
                },
            )

        assert "production" in exc_info.value.decision.reason

    def test_rejects_nested_wildcard_args(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "delete_valkey_key",
                {
                    "keys": ["session:*"],
                    "reason": "test",
                },
            )

        assert "wildcard" in exc_info.value.decision.reason

    def test_scale_to_zero_requires_approval(self) -> None:
        decision = PolicyEngine().classify(
            "scale_deployment",
            {
                "namespace": "rivulet",
                "name": "api-gateway",
                "replicas": 0,
            },
        )

        assert decision.allowed is True
        assert decision.risk_tier == RiskTier.REVERSIBLE_HIGH
        assert decision.requires_approval is True

    def test_scale_to_nonzero_autonomous(self) -> None:
        decision = PolicyEngine().classify(
            "scale_deployment",
            {
                "namespace": "rivulet",
                "name": "api-gateway",
                "replicas": 3,
            },
        )

        assert decision.risk_tier == RiskTier.REVERSIBLE_LOW
        assert decision.requires_approval is False

    def test_invalid_scale_request_is_rejected(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "scale_deployment",
                {
                    "namespace": "rivulet",
                    "name": "api-gateway",
                    "replicas": "not-an-int",
                },
            )

        assert "non-negative integer" in exc_info.value.decision.reason

    def test_set_feature_flag_is_tier2(self) -> None:
        decision = PolicyEngine().classify(
            "set_feature_flag",
            {
                "namespace": "rivulet",
                "name": "payments",
                "enabled": True,
            },
        )

        assert decision.risk_tier == RiskTier.REVERSIBLE_HIGH
        assert decision.requires_approval is True

    def test_unknown_tool_uses_base_tier(self) -> None:
        decision = PolicyEngine().classify(
            "some_future_readonly_tool",
            {"namespace": "rivulet"},
            base_tier=RiskTier.OBSERVE,
        )

        assert decision.risk_tier == RiskTier.OBSERVE
        assert decision.requires_approval is False

    def test_custom_rules_override_default(self) -> None:
        engine = PolicyEngine(
            rules=[
                {
                    "tool": "restart_deployment",
                    "tier": RiskTier.PROHIBITED,
                    "reason": "custom policy: no restarts in this environment",
                }
            ]
        )

        with pytest.raises(PolicyRejectionError):
            engine.classify(
                "restart_deployment",
                {
                    "namespace": "rivulet",
                    "name": "api-gateway",
                },
            )

    def test_hard_blocked_tools_cannot_be_overridden(self) -> None:
        engine = PolicyEngine(
            rules=[
                {
                    "tool": "delete_namespace",
                    "tier": RiskTier.OBSERVE,
                    "reason": "unsafe custom override",
                }
            ]
        )

        with pytest.raises(PolicyRejectionError):
            engine.classify(
                "delete_namespace",
                {"namespace": "rivulet"},
            )

    def test_prohibited_base_tier_raises(self) -> None:
        with pytest.raises(PolicyRejectionError) as exc_info:
            PolicyEngine().classify(
                "future_mutating_tool",
                {"namespace": "rivulet"},
                base_tier=RiskTier.PROHIBITED,
            )

        assert exc_info.value.decision.allowed is False

    def test_empty_namespace_is_rejected(self) -> None:
        with pytest.raises(PolicyRejectionError):
            PolicyEngine().classify(
                "restart_deployment",
                {
                    "namespace": "",
                    "name": "api-gateway",
                },
            )

    def test_max_autonomous_tier_can_be_raised(self) -> None:
        decision = PolicyEngine(max_autonomous_tier=RiskTier.REVERSIBLE_HIGH).classify(
            "scale_deployment",
            {
                "namespace": "rivulet",
                "name": "api-gateway",
                "replicas": 0,
            },
        )

        assert decision.requires_approval is False


class TestSafeExecutor:
    """Tests of the policy-gated executor."""

    @pytest.mark.asyncio
    async def test_tier4_action_is_rejected_without_dispatch(self) -> None:
        registry = _make_registry_with_tools(("delete_namespace", 4))
        registry.execute = AsyncMock(wraps=registry.execute)  # type: ignore[method-assign]

        executor = SafeExecutor(registry, PolicyEngine())

        with pytest.raises(PolicyRejectionError):
            await executor.execute(
                _proposed("delete_namespace", {"namespace": "rivulet"}),
                _make_context(),
            )

        registry.execute.assert_not_awaited()  # type: ignore[attr-defined]

    @pytest.mark.asyncio
    async def test_tier1_action_executes_autonomously(self) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))
        executor = SafeExecutor(registry, PolicyEngine())

        result = await executor.execute(
            _proposed(
                "restart_deployment",
                {
                    "namespace": "rivulet",
                    "name": "api-gateway",
                    "reason": "test",
                },
            ),
            _make_context(),
        )

        assert result.executed is True
        assert result.decision.risk_tier == RiskTier.REVERSIBLE_LOW
        assert result.error is None
        assert result.output == {"ok": True}
        assert result.executed_at is not None

    @pytest.mark.asyncio
    async def test_tier2_action_raises_needs_approval(self) -> None:
        registry = _make_registry_with_tools(("scale_deployment", 2))
        registry.execute = AsyncMock(wraps=registry.execute)  # type: ignore[method-assign]

        executor = SafeExecutor(registry, PolicyEngine())

        with pytest.raises(NeedsApprovalError) as exc_info:
            await executor.execute(
                _proposed(
                    "scale_deployment",
                    {
                        "namespace": "rivulet",
                        "name": "api-gateway",
                        "replicas": 0,
                    },
                ),
                _make_context(),
            )

        assert exc_info.value.decision.requires_approval is True
        registry.execute.assert_not_awaited()  # type: ignore[attr-defined]

    @pytest.mark.asyncio
    async def test_failed_tool_triggers_injected_rollback(self) -> None:
        registry = _make_registry_with_tools(
            ("restart_deployment", 1),
            fail_on={"restart_deployment"},
        )

        async def snapshot(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del context
            return {"previous": args["name"]}

        rollback = AsyncMock(return_value=True)

        executor = SafeExecutor(
            registry,
            PolicyEngine(),
            snapshots={"restart_deployment": snapshot},
            rollbacks={"restart_deployment": rollback},
        )

        result = await executor.execute(
            _proposed(
                "restart_deployment",
                {"namespace": "rivulet", "name": "api-gateway"},
            ),
            _make_context(),
        )

        assert result.executed is True
        assert result.error is not None
        assert result.rolled_back is True
        rollback.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_failed_tool_without_rollback_marks_not_rolled_back(
        self,
    ) -> None:
        registry = _make_registry_with_tools(
            ("terminate_backend", 1),
            fail_on={"terminate_backend"},
        )

        result = await SafeExecutor(registry, PolicyEngine()).execute(
            _proposed(
                "terminate_backend",
                {"pid": 12345, "reason": "test"},
            ),
            _make_context(),
        )

        assert result.executed is True
        assert result.error is not None
        assert result.rolled_back is False

    @pytest.mark.asyncio
    async def test_failed_verification_triggers_rollback(self) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))

        async def snapshot(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del args, context
            return {"state": "before"}

        async def verify(
            args: dict[str, Any],
            snapshot: dict[str, Any] | None,
            context: SREContext,
        ) -> bool:
            del args, snapshot, context
            return False

        rollback = AsyncMock(return_value=True)

        result = await SafeExecutor(
            registry,
            PolicyEngine(),
            snapshots={"restart_deployment": snapshot},
            verifiers={"restart_deployment": verify},
            rollbacks={"restart_deployment": rollback},
        ).execute(
            _proposed(
                "restart_deployment",
                {"namespace": "rivulet", "name": "api-gateway"},
            ),
            _make_context(),
        )

        assert result.executed is True
        assert result.verified is False
        assert result.rolled_back is True
        assert result.error is None

    @pytest.mark.asyncio
    async def test_verifier_runs_without_snapshot(self) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))
        context = _make_context()
        verify = AsyncMock(return_value=True)

        result = await SafeExecutor(
            registry,
            PolicyEngine(),
            verifiers={"restart_deployment": verify},
        ).execute(
            _proposed(
                "restart_deployment",
                {"namespace": "rivulet", "name": "api-gateway"},
            ),
            context,
        )

        assert result.verified is True
        verify.assert_awaited_once_with(
            {"namespace": "rivulet", "name": "api-gateway"},
            None,
            context,
        )

    @pytest.mark.asyncio
    async def test_snapshot_failure_fails_closed_without_dispatch(
        self,
    ) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))
        registry.execute = AsyncMock(wraps=registry.execute)  # type: ignore[method-assign]

        async def snapshot(args: dict[str, Any], context: SREContext) -> dict[str, Any]:
            del args, context
            raise RuntimeError("snapshot unavailable")

        result = await SafeExecutor(
            registry,
            PolicyEngine(),
            snapshots={"restart_deployment": snapshot},
        ).execute(
            _proposed(
                "restart_deployment",
                {"namespace": "rivulet", "name": "api-gateway"},
            ),
            _make_context(),
        )

        assert result.executed is False
        assert result.error is not None
        registry.execute.assert_not_awaited()  # type: ignore[attr-defined]

    @pytest.mark.asyncio
    async def test_proposal_cannot_downgrade_registered_risk(self) -> None:
        registry = _make_registry_with_tools(("scale_deployment", 2))
        executor = SafeExecutor(registry, PolicyEngine())

        with pytest.raises(NeedsApprovalError):
            await executor.execute(
                _proposed(
                    "scale_deployment",
                    {
                        "namespace": "rivulet",
                        "name": "api-gateway",
                        "replicas": 0,
                    },
                    risk_tier=RiskTier.OBSERVE,
                ),
                _make_context(),
            )

    @pytest.mark.asyncio
    async def test_unknown_tool_is_rejected_before_dispatch(self) -> None:
        registry = ToolRegistry()

        with pytest.raises(PolicyRejectionError) as exc_info:
            await SafeExecutor(registry, PolicyEngine()).execute(
                _proposed("missing_tool", {"namespace": "rivulet"}),
                _make_context(),
            )

        assert "not registered" in exc_info.value.decision.reason

    @pytest.mark.asyncio
    async def test_proposal_explicitly_requesting_approval_is_honored(
        self,
    ) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))
        registry.execute = AsyncMock(wraps=registry.execute)  # type: ignore[method-assign]

        with pytest.raises(NeedsApprovalError) as exc_info:
            await SafeExecutor(registry, PolicyEngine()).execute(
                _proposed(
                    "restart_deployment",
                    {"namespace": "rivulet", "name": "api-gateway"},
                    requires_approval=True,
                ),
                _make_context(),
            )

        assert exc_info.value.decision.requires_approval is True
        registry.execute.assert_not_awaited()  # type: ignore[attr-defined]

    @pytest.mark.asyncio
    async def test_to_executed_action_preserves_execution_time(self) -> None:
        registry = _make_registry_with_tools(("restart_deployment", 1))

        result = await SafeExecutor(registry, PolicyEngine()).execute(
            _proposed(
                "restart_deployment",
                {"namespace": "rivulet", "name": "api-gateway"},
            ),
            _make_context(),
        )

        executed = result.to_executed_action()

        assert executed["tool_name"] == "restart_deployment"
        assert executed["success"] is True
        assert executed["verification_passed"] is None
        assert executed["result"] == {"ok": True}
        assert executed["executed_at"] == result.executed_at

    @pytest.mark.asyncio
    async def test_unknown_registered_tool_uses_base_tier(self) -> None:
        registry = _make_registry_with_tools(("list_pods", 0))

        result = await SafeExecutor(registry, PolicyEngine()).execute(
            _proposed("list_pods", {"namespace": "rivulet"}),
            _make_context(),
        )

        assert result.executed is True
        assert result.decision.risk_tier == RiskTier.OBSERVE
