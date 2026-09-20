"""Policy-gated, rollback-capable asynchronous tool executor.

``SafeExecutor`` is the single dispatch boundary for agent actions. Every
call is policy-classified first; prohibited calls are rejected and actions
above the autonomous threshold raise :class:`NeedsApprovalError` before any
tool dispatch occurs.

Rollback and verification handlers are deliberately injected. A fake default
rollback that merely writes an audit message is unsafe because it can make
the caller believe state was restored when it was not. Real pre-state capture
and rollback must therefore be provided by the integration layer that knows
the actual cluster/database/cache APIs.
"""

from __future__ import annotations

import datetime as _dt
import logging
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from autosre.core.state import ExecutedAction, ProposedAction, SREContext
from autosre.safety.policy import (
    PolicyDecision,
    PolicyEngine,
    PolicyRejectionError,
    RiskTier,
)
from autosre.tools.registry import (
    ToolExecutionError,
    ToolNotFoundError,
    ToolRegistry,
)

logger = logging.getLogger(__name__)


class NeedsApprovalError(Exception):
    """Raised when an allowed action requires human approval before dispatch."""

    def __init__(
        self,
        decision: PolicyDecision,
        action: ProposedAction,
    ) -> None:
        super().__init__(decision.reason)
        self.decision = decision
        self.action = action


@dataclass
class ExecutionResult:
    """Outcome of a safe execution attempt.

    ``executed`` means the tool was dispatched to the registry, even when the
    registry later returned an execution error.
    """

    action: ProposedAction
    decision: PolicyDecision
    executed: bool = False
    verified: bool | None = None
    rolled_back: bool = False
    error: BaseException | None = None
    output: dict[str, Any] | None = None
    snapshot: dict[str, Any] | None = None
    executed_at: str | None = None

    def to_executed_action(self) -> ExecutedAction:
        """Render the result as an :class:`ExecutedAction`."""
        executed_at = self.executed_at or _utc_now()

        # ProposedAction.get() returns object | None for undeclared keys.
        # Narrow to str; fall back to a generated UUID otherwise.
        raw_id = self.action.get("tool_call_id")
        tool_call_id = raw_id if isinstance(raw_id, str) else uuid.uuid4().hex

        return ExecutedAction(
            tool_name=self.action["tool_name"],
            tool_args=self.action["tool_args"],
            tool_call_id=tool_call_id,
            result=self.output if self.output is not None else {},
            success=(self.executed and self.error is None and self.verified is not False),
            executed_at=executed_at,
            verification_passed=self.verified,
        )


_SnapshotFn = Callable[[dict[str, Any], SREContext], Awaitable[dict[str, Any]]]
_VerifyFn = Callable[[dict[str, Any], dict[str, Any] | None, SREContext], Awaitable[bool]]
_RollbackFn = Callable[[dict[str, Any], dict[str, Any], SREContext], Awaitable[bool]]


def _utc_now() -> str:
    """Return the current UTC time as an RFC 3339-compatible Z timestamp."""
    return _dt.datetime.now(_dt.UTC).isoformat().replace("+00:00", "Z")


def _policy_rejection(reason: str) -> PolicyRejectionError:
    """Create a hard policy rejection for an invalid execution boundary."""
    return PolicyRejectionError(
        PolicyDecision(
            allowed=False,
            risk_tier=RiskTier.PROHIBITED,
            requires_approval=False,
            reason=reason,
        )
    )


class SafeExecutor:
    """Policy-gated, rollback-capable tool executor.

    ``snapshots``, ``verifiers`` and ``rollbacks`` are integration-provided.

    Snapshot failures are fail-closed: when a snapshot handler exists but
    cannot capture pre-state, the mutating action is not dispatched.
    """

    def __init__(
        self,
        registry: ToolRegistry,
        policy: PolicyEngine,
        snapshots: dict[str, _SnapshotFn] | None = None,
        verifiers: dict[str, _VerifyFn] | None = None,
        rollbacks: dict[str, _RollbackFn] | None = None,
    ) -> None:
        self._registry = registry
        self._policy = policy
        self._snapshots = dict(snapshots or {})
        self._verifiers = dict(verifiers or {})
        self._rollbacks = dict(rollbacks or {})

    async def execute(
        self,
        action: ProposedAction,
        context: SREContext,
    ) -> ExecutionResult:
        """Policy-check, snapshot, execute, verify, and rollback on failure."""
        tool_name = action["tool_name"]
        args = dict(action["tool_args"])

        # Never downgrade a tool's registered risk because the proposal says
        # a lower tier. The effective fallback is the conservative maximum of
        # registry metadata and proposal metadata.
        try:
            tool = self._registry.get(tool_name)
        except ToolNotFoundError as exc:
            raise _policy_rejection(
                f"tool '{tool_name}' is not registered and cannot be executed"
            ) from exc

        try:
            registered_tier = RiskTier(tool.risk_tier)
            proposed_tier = RiskTier(action.get("risk_tier", RiskTier.OBSERVE))
        except (TypeError, ValueError) as exc:
            raise _policy_rejection(f"invalid risk tier metadata for tool '{tool_name}'") from exc

        base_tier = max(registered_tier, proposed_tier)
        decision = self._policy.classify(tool_name, args, base_tier)

        # A proposal requesting approval is treated conservatively. Policy
        # still controls the actual risk tier; this only prevents a planner
        # annotation from accidentally being discarded.
        if action.get("requires_approval", False) and not decision.requires_approval:
            decision = PolicyDecision(
                allowed=decision.allowed,
                risk_tier=decision.risk_tier,
                requires_approval=True,
                reason=(f"{decision.reason}; proposal explicitly requires approval"),
            )

        if not decision.allowed:
            raise PolicyRejectionError(decision)

        result = ExecutionResult(action=action, decision=decision)

        # HITL happens before snapshotting and, critically, before dispatch.
        if decision.requires_approval:
            raise NeedsApprovalError(decision, action)

        # Capture pre-state before any mutation. If the integration explicitly
        # registered a snapshot handler, failure is fail-closed rather than
        # executing without the state required for rollback/verification.
        snapshot_fn = self._snapshots.get(tool_name)
        if snapshot_fn is not None:
            try:
                snapshot = await snapshot_fn(args, context)
                if not isinstance(snapshot, dict):
                    raise TypeError("snapshot handler must return a dict")
                result.snapshot = snapshot
            except Exception as exc:  # noqa: BLE001 - integration boundary
                result.error = exc
                logger.exception("snapshot failed for %s", tool_name)
                return result

        # Mark the action as dispatched before awaiting the registry. If the
        # handler raises after partially applying a change, rollback semantics
        # still need to treat the tool as having been dispatched.
        result.executed = True
        result.executed_at = _utc_now()

        try:
            output = await self._registry.execute(tool_name, args, context)
            if not isinstance(output, dict):
                raise TypeError("tool registry must return a dict output")
            result.output = output
        except ToolExecutionError as exc:
            result.error = exc
            logger.warning("tool %s failed: %s", tool_name, exc)
            await self._maybe_rollback(tool_name, args, result, context)
            return result
        except Exception as exc:  # noqa: BLE001 - registry boundary
            result.error = exc
            logger.exception("unexpected error executing %s", tool_name)
            await self._maybe_rollback(tool_name, args, result, context)
            return result

        verify_fn = self._verifiers.get(tool_name)
        if verify_fn is not None:
            try:
                verified = await verify_fn(args, result.snapshot, context)
                if not isinstance(verified, bool):
                    raise TypeError("verifier must return bool")
                result.verified = verified
            except Exception as exc:  # noqa: BLE001 - integration boundary
                result.verified = False
                result.error = exc
                logger.exception("verification failed for %s", tool_name)

        if result.verified is False:
            await self._maybe_rollback(tool_name, args, result, context)

        return result

    async def _maybe_rollback(
        self,
        tool_name: str,
        args: dict[str, Any],
        result: ExecutionResult,
        context: SREContext,
    ) -> None:
        """Invoke a registered rollback when trustworthy pre-state exists."""
        rollback_fn = self._rollbacks.get(tool_name)
        snapshot = result.snapshot

        if rollback_fn is None or snapshot is None:
            return

        try:
            rolled_back = await rollback_fn(args, snapshot, context)
            if not isinstance(rolled_back, bool):
                raise TypeError("rollback handler must return bool")
            result.rolled_back = rolled_back
        except Exception as exc:  # noqa: BLE001 - rollback boundary
            logger.exception("rollback failed for %s", tool_name)
            result.rolled_back = False
            if result.error is None:
                result.error = exc
