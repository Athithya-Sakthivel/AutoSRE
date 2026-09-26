"""Policy-gated, rollback-capable asynchronous tool executor.

``SafeExecutor`` is the single dispatch boundary for every agent action.
Every call is policy-classified first; prohibited calls are rejected and
actions above the autonomous threshold raise ``NeedsApprovalError`` before
any tool dispatch occurs.

## Design invariants

1. **Policy is authoritative.** A proposal cannot downgrade a tool's
   registered risk tier. The effective tier is
   ``max(registered_tier, proposed_tier)``.

2. **Fail-closed on pre-state capture.** When a snapshot handler is
   registered for a mutating tool, a snapshot failure prevents dispatch.
   This is deliberate: the executor never mutates without the state
   required for rollback and verification.

3. **Dispatched-before-await.** ``result.executed`` is set to True *before*
   the registry handler is awaited. If the handler raises after partially
   applying a change, rollback semantics still treat the tool as having
   been dispatched.

4. **Rollback runs at most once.** ``result.rolled_back`` guards against
   double execution on concurrent failure paths.

5. **Every integration handler is timeout-bounded.** Snapshot, verify, and
   rollback handlers are wrapped in ``asyncio.wait_for``. A hung handler
   cannot block the graph indefinitely.

6. **Every dispatch produces a terminal ``status``.** Callers switch on
   ``result.status`` rather than inferring behavior from ad-hoc boolean
   combinations.

## Rollback and verification handlers are injected

A fake default rollback that merely writes an audit message is unsafe
because it can make the caller believe state was restored when it was
not. Real pre-state capture and rollback must be provided by the
integration layer that knows the actual cluster/database/cache APIs.

## Status lifecycle

    rejected              Policy said no. Nothing dispatched.
    approval_required     Tier above autonomous threshold. Nothing dispatched.
    not_dispatched        Other pre-dispatch failure (unknown tool, bad args).
    snapshot_failed       Snapshot handler raised or timed out. Not dispatched.
    succeeded             Dispatched with no error; no verifier registered.
    verified              Dispatched with no error; verifier returned True.
    verification_failed   Dispatched with no error; verifier returned False
                          or raised. Rollback attempted if registered.
    failed                Dispatched but raised before completing.
                          Rollback attempted if registered.
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import hashlib
import json
import logging
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, Literal

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

# ---------------------------------------------------------------------------
# Public exception
# ---------------------------------------------------------------------------


class NeedsApprovalError(Exception):
    """Raised when an allowed action requires human approval before dispatch.

    Carries both the policy decision and the original action so the HITL
    layer can build a request payload without re-running classification.
    """

    def __init__(
        self,
        decision: PolicyDecision,
        action: ProposedAction,
    ) -> None:
        super().__init__(decision.reason)
        self.decision = decision
        self.action = action


# ---------------------------------------------------------------------------
# Status and result
# ---------------------------------------------------------------------------

ExecutionStatus = Literal[
    "rejected",
    "approval_required",
    "not_dispatched",
    "snapshot_failed",
    "succeeded",
    "verified",
    "verification_failed",
    "failed",
]


@dataclass
class ExecutionResult:
    """Outcome of one safe execution attempt.

    ``executed`` is True if the tool was dispatched to the registry, even
    when the registry later returned an error. ``status`` is the
    authoritative terminal classification; callers should switch on it.

    Terminal statuses and their meaning:

        rejected              Policy rejected the action. Not dispatched.
        approval_required     Tier above autonomous threshold. Not dispatched.
        not_dispatched        Unknown tool or malformed action. Not dispatched.
        snapshot_failed       Pre-state capture failed. Not dispatched.
        succeeded             Dispatched, no error, no verifier registered.
        verified              Dispatched, no error, verifier returned True.
        verification_failed   Dispatched, no error, verifier returned False
                              or raised. Rollback attempted if registered.
        failed                Dispatched, raised. Rollback attempted if
                              registered.
    """

    action: ProposedAction
    decision: PolicyDecision

    status: ExecutionStatus = "not_dispatched"
    executed: bool = False
    verified: bool | None = None
    rolled_back: bool = False
    cancelled: bool = False

    error: BaseException | None = None
    output: dict[str, Any] | None = None
    snapshot: dict[str, Any] | None = None

    executed_at: str | None = None
    duration_ms: int | None = None

    # ------------------------------------------------------------------
    # Derived properties
    # ------------------------------------------------------------------

    @property
    def dispatched(self) -> bool:
        """Return True if the tool was actually invoked."""
        return self.executed

    @property
    def succeeded(self) -> bool:
        """Return True if the tool completed without error.

        Note: succeeded does not imply verified. A tool may succeed and
        not be verified (no verifier registered) or succeed and fail
        verification (verifier returned False).
        """
        return self.status in ("succeeded", "verified")

    @property
    def fully_verified(self) -> bool:
        """Return True only when verification ran and passed."""
        return self.status == "verified"

    def to_executed_action(self) -> ExecutedAction:
        """Render the result as an ``ExecutedAction`` for graph state.

        success is True only when the tool completed without error AND
        verification did not explicitly fail. verification_passed is
        passed through unchanged: True, False, or None (no verifier).

        ``execute_node`` in graph_nodes.py relies on this contract:
            success and verification_passed is None    -> Tier-1 implied OK
            success and verification_passed is True    -> verified
            success and verification_passed is False   -> retry path
            not success                                -> retry path
        """
        executed_at = self.executed_at or _utc_now()

        raw_id = self.action.get("tool_call_id")
        tool_call_id = raw_id if isinstance(raw_id, str) else uuid.uuid4().hex

        success = self.executed and self.error is None and self.verified is not False

        return ExecutedAction(
            tool_name=self.action["tool_name"],
            tool_args=self.action["tool_args"],
            tool_call_id=tool_call_id,
            result=self.output if self.output is not None else {},
            success=success,
            executed_at=executed_at,
            verification_passed=self.verified,
        )


# ---------------------------------------------------------------------------
# Hook signatures
# ---------------------------------------------------------------------------

_SnapshotFn = Callable[
    [dict[str, Any], SREContext],
    Awaitable[dict[str, Any]],
]
_VerifyFn = Callable[
    [dict[str, Any], dict[str, Any] | None, SREContext],
    Awaitable[bool],
]
_RollbackFn = Callable[
    [dict[str, Any], dict[str, Any], SREContext],
    Awaitable[bool],
]


@dataclass(frozen=True)
class AuditRecord:
    """One audit-log entry for a single execute() call.

    Emitted to the injected audit_hook after the result is terminal.
    Contains a hash of tool args rather than the args themselves so
    credentials embedded in arguments never reach the audit store.
    """

    ts: str
    incident_id: str | None
    tool_name: str
    tool_args_hash: str
    risk_tier: int
    policy_reason: str
    status: ExecutionStatus
    executed: bool
    verified: bool | None
    rolled_back: bool
    duration_ms: int | None
    error_class: str | None


AuditHook = Callable[[AuditRecord], Awaitable[None]]

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _utc_now() -> str:
    """Return the current UTC time as an RFC 3339-compatible Z timestamp."""
    return _dt.datetime.now(_dt.UTC).isoformat().replace("+00:00", "Z")


def _hash_args(args: dict[str, Any]) -> str:
    """Return a stable SHA256 hex digest of tool arguments.

    Sorting keys and using default=str ensures the digest is deterministic
    across process runs. Used by the audit hook so credential-bearing
    arguments never land in the audit store.
    """
    try:
        encoded = json.dumps(
            args,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        ).encode("utf-8")
    except TypeError, ValueError:
        encoded = repr(args).encode("utf-8")

    return hashlib.sha256(encoded).hexdigest()


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


# ---------------------------------------------------------------------------
# SafeExecutor
# ---------------------------------------------------------------------------


@dataclass
class _ExecutorConfig:
    """Grouped configuration for SafeExecutor to keep the constructor flat."""

    snapshots: dict[str, _SnapshotFn] = field(default_factory=dict)
    verifiers: dict[str, _VerifyFn] = field(default_factory=dict)
    rollbacks: dict[str, _RollbackFn] = field(default_factory=dict)
    audit_hook: AuditHook | None = None
    handler_timeout: float = 10.0


class SafeExecutor:
    """Policy-gated, rollback-capable tool executor.

    Snapshots, verifiers, and rollbacks are integration-provided. Snapshot
    failures are fail-closed: when a snapshot handler exists but cannot
    capture pre-state, the mutating action is not dispatched.

    Every handler invocation is bounded by ``handler_timeout`` seconds to
    prevent a hung integration from blocking the graph.
    """

    def __init__(
        self,
        registry: ToolRegistry,
        policy: PolicyEngine,
        snapshots: dict[str, _SnapshotFn] | None = None,
        verifiers: dict[str, _VerifyFn] | None = None,
        rollbacks: dict[str, _RollbackFn] | None = None,
        *,
        audit_hook: AuditHook | None = None,
        handler_timeout: float = 10.0,
    ) -> None:
        if handler_timeout <= 0:
            raise ValueError("handler_timeout must be greater than zero")

        self._registry = registry
        self._policy = policy
        self._cfg = _ExecutorConfig(
            snapshots=dict(snapshots or {}),
            verifiers=dict(verifiers or {}),
            rollbacks=dict(rollbacks or {}),
            audit_hook=audit_hook,
            handler_timeout=handler_timeout,
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def execute(
        self,
        action: ProposedAction,
        context: SREContext,
        *,
        incident_id: str | None = None,
    ) -> ExecutionResult:
        """Policy-check, snapshot, execute, verify, and rollback on failure.

        Args:
            action: Validated ProposedAction.
            context: SREContext carrying registry clients.
            incident_id: Optional, forwarded to the audit hook.

        Returns:
            ExecutionResult with a terminal status.

        Raises:
            PolicyRejectionError: Action was prohibited by policy. The
                rejection is always audited before the exception is
                re-raised, so a prohibited attempt is never silent.
            NeedsApprovalError: Action requires HITL before dispatch.
        """
        tool_name = action["tool_name"]
        args = dict(action["tool_args"])

        # ------------------------------------------------------------------
        # Step 1 — registry lookup.
        # ------------------------------------------------------------------
        try:
            tool = self._registry.get(tool_name)
        except ToolNotFoundError as exc:
            await self._safe_audit(
                incident_id=incident_id,
                tool_name=tool_name,
                args=args,
                risk_tier=int(RiskTier.PROHIBITED),
                policy_reason=f"tool '{tool_name}' is not registered",
                status="not_dispatched",
                executed=False,
                verified=None,
                rolled_back=False,
                duration_ms=None,
                error=exc,
            )
            raise _policy_rejection(
                f"tool '{tool_name}' is not registered and cannot be executed"
            ) from exc

        # ------------------------------------------------------------------
        # Step 2 — risk tier reconciliation. Never downgrade a tool's
        # registered risk because the proposal says a lower tier.
        # ------------------------------------------------------------------
        try:
            registered_tier = RiskTier(tool.risk_tier)
            proposed_tier = RiskTier(action.get("risk_tier", RiskTier.OBSERVE))
        except (TypeError, ValueError) as exc:
            await self._safe_audit(
                incident_id=incident_id,
                tool_name=tool_name,
                args=args,
                risk_tier=int(RiskTier.PROHIBITED),
                policy_reason="invalid risk tier metadata",
                status="not_dispatched",
                executed=False,
                verified=None,
                rolled_back=False,
                duration_ms=None,
                error=exc,
            )
            raise _policy_rejection(f"invalid risk tier metadata for tool '{tool_name}'") from exc

        base_tier = max(registered_tier, proposed_tier)

        # ------------------------------------------------------------------
        # Step 3 — policy classification. `classify` raises
        # PolicyRejectionError for prohibited actions. We audit the
        # rejection here before re-raising, so a prohibited attempt is
        # recorded even though the raise short-circuits the rest of this
        # method.
        # ------------------------------------------------------------------
        try:
            decision = self._policy.classify(tool_name, args, base_tier)
        except PolicyRejectionError as exc:
            await self._safe_audit(
                incident_id=incident_id,
                tool_name=tool_name,
                args=args,
                risk_tier=int(exc.decision.risk_tier),
                policy_reason=exc.decision.reason,
                status="rejected",
                executed=False,
                verified=None,
                rolled_back=False,
                duration_ms=None,
                error=exc,
            )
            raise

        # ------------------------------------------------------------------
        # Step 4 — a proposal explicitly requesting approval is treated
        # conservatively: policy still controls the tier, but we never
        # discard a planner's explicit approval annotation.
        # ------------------------------------------------------------------
        if action.get("requires_approval", False) and not decision.requires_approval:
            decision = PolicyDecision(
                allowed=decision.allowed,
                risk_tier=decision.risk_tier,
                requires_approval=True,
                reason=(f"{decision.reason}; proposal explicitly requires approval"),
            )

        result = ExecutionResult(action=action, decision=decision)

        # ------------------------------------------------------------------
        # Step 5 — hard rejection from a non-raising path.
        #
        # The default PolicyEngine raises for prohibited actions, so this
        # branch is only reachable when a custom engine returns a decision
        # with allowed=False instead of raising. Kept as a defensive
        # backstop with the same audit-then-raise contract as Step 3.
        # ------------------------------------------------------------------
        if not decision.allowed:
            result.status = "rejected"
            await self._safe_audit(
                incident_id=incident_id,
                tool_name=tool_name,
                args=args,
                risk_tier=int(decision.risk_tier),
                policy_reason=decision.reason,
                status=result.status,
                executed=False,
                verified=None,
                rolled_back=False,
                duration_ms=None,
                error=None,
            )
            raise PolicyRejectionError(decision)

        # ------------------------------------------------------------------
        # Step 6 — HITL gate. Raised before any snapshot or dispatch.
        # ------------------------------------------------------------------
        if decision.requires_approval:
            result.status = "approval_required"
            await self._safe_audit(
                incident_id=incident_id,
                tool_name=tool_name,
                args=args,
                risk_tier=int(decision.risk_tier),
                policy_reason=decision.reason,
                status=result.status,
                executed=False,
                verified=None,
                rolled_back=False,
                duration_ms=None,
                error=None,
            )
            raise NeedsApprovalError(decision, action)

        # ------------------------------------------------------------------
        # Step 7 — pre-state capture. Fail-closed.
        # ------------------------------------------------------------------
        snapshot_fn = self._cfg.snapshots.get(tool_name)
        if snapshot_fn is not None:
            try:
                snapshot = await asyncio.wait_for(
                    snapshot_fn(args, context),
                    timeout=self._cfg.handler_timeout,
                )
            except TimeoutError as exc:
                result.status = "snapshot_failed"
                result.error = exc
                logger.exception("Snapshot handler timed out for %s", tool_name)
                await self._audit_result(result, incident_id, args)
                return result
            except Exception as exc:  # noqa: BLE001 — integration boundary
                result.status = "snapshot_failed"
                result.error = exc
                logger.exception("Snapshot handler failed for %s", tool_name)
                await self._audit_result(result, incident_id, args)
                return result

            if not isinstance(snapshot, dict):
                result.status = "snapshot_failed"
                result.error = TypeError("snapshot handler must return a dict")
                logger.error(
                    "Snapshot handler for %s returned %s, expected dict",
                    tool_name,
                    type(snapshot).__name__,
                )
                await self._audit_result(result, incident_id, args)
                return result

            result.snapshot = snapshot

        # ------------------------------------------------------------------
        # Step 8 — dispatch.
        #
        # Mark as dispatched BEFORE awaiting the handler so that
        # cancellation or an exception leaving partial state still
        # triggers rollback semantics.
        # ------------------------------------------------------------------
        result.executed = True
        result.executed_at = _utc_now()
        started_monotonic = time.monotonic()

        try:
            output = await self._registry.execute(tool_name, args, context)

            if not isinstance(output, dict):
                raise TypeError("tool registry must return a dict output")

            result.output = output
            result.status = "succeeded"

        except ToolExecutionError as exc:
            result.status = "failed"
            result.error = exc
            logger.warning("Tool %s failed: %s", tool_name, exc)
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result

        except asyncio.CancelledError:
            result.status = "failed"
            result.error = asyncio.CancelledError("execution cancelled")
            result.cancelled = True
            logger.warning("Execution of %s cancelled; attempting rollback", tool_name)
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            raise

        except Exception as exc:  # noqa: BLE001 — registry boundary
            result.status = "failed"
            result.error = exc
            logger.exception("Unexpected error executing %s", tool_name)
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result

        # ------------------------------------------------------------------
        # Step 9 — verification.
        # ------------------------------------------------------------------
        verify_fn = self._cfg.verifiers.get(tool_name)

        if verify_fn is None:
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result

        try:
            verified = await asyncio.wait_for(
                verify_fn(args, result.snapshot, context),
                timeout=self._cfg.handler_timeout,
            )
        except TimeoutError as exc:
            result.verified = False
            result.status = "verification_failed"
            result.error = exc
            logger.exception("Verification timed out for %s", tool_name)
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result
        except Exception as exc:  # noqa: BLE001 — integration boundary
            result.verified = False
            result.status = "verification_failed"
            result.error = exc
            logger.exception("Verification handler failed for %s", tool_name)
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result

        if not isinstance(verified, bool):
            result.verified = False
            result.status = "verification_failed"
            result.error = TypeError("verifier must return bool")
            logger.error(
                "Verifier for %s returned %s, expected bool",
                tool_name,
                type(verified).__name__,
            )
            await self._maybe_rollback(tool_name, args, result, context)
            result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
            await self._audit_result(result, incident_id, args)
            return result

        result.verified = verified

        if verified:
            result.status = "verified"
        else:
            result.status = "verification_failed"
            logger.warning(
                "Verification returned False for %s; attempting rollback",
                tool_name,
            )
            await self._maybe_rollback(tool_name, args, result, context)

        result.duration_ms = int((time.monotonic() - started_monotonic) * 1000)
        await self._audit_result(result, incident_id, args)
        return result

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _maybe_rollback(
        self,
        tool_name: str,
        args: dict[str, Any],
        result: ExecutionResult,
        context: SREContext,
    ) -> None:
        """Invoke the registered rollback when a trustworthy snapshot exists.

        Idempotent: if ``result.rolled_back`` is already True, this returns
        without re-invoking the handler. This prevents double rollback when
        both dispatch and verification fail on the same call.
        """
        if result.rolled_back:
            logger.debug("Rollback for %s already performed; skipping", tool_name)
            return

        rollback_fn = self._cfg.rollbacks.get(tool_name)
        snapshot = result.snapshot

        if rollback_fn is None or snapshot is None:
            return

        try:
            rolled_back = await asyncio.wait_for(
                rollback_fn(args, snapshot, context),
                timeout=self._cfg.handler_timeout,
            )
        except TimeoutError as exc:
            logger.exception("Rollback timed out for %s", tool_name)
            result.rolled_back = False
            if result.error is None:
                result.error = exc
            return
        except Exception as exc:  # noqa: BLE001 — rollback boundary
            logger.exception("Rollback failed for %s", tool_name)
            result.rolled_back = False
            if result.error is None:
                result.error = exc
            return

        if not isinstance(rolled_back, bool):
            logger.error(
                "Rollback handler for %s returned %s, expected bool",
                tool_name,
                type(rolled_back).__name__,
            )
            result.rolled_back = False
            if result.error is None:
                result.error = TypeError("rollback handler must return bool")
            return

        result.rolled_back = rolled_back

    async def _audit_result(
        self,
        result: ExecutionResult,
        incident_id: str | None,
        args: dict[str, Any],
    ) -> None:
        """Emit a terminal audit record for a result that ran to completion."""
        tool_name = result.action["tool_name"]
        await self._safe_audit(
            incident_id=incident_id,
            tool_name=tool_name,
            args=args,
            risk_tier=int(result.decision.risk_tier),
            policy_reason=result.decision.reason,
            status=result.status,
            executed=result.executed,
            verified=result.verified,
            rolled_back=result.rolled_back,
            duration_ms=result.duration_ms,
            error=result.error,
        )

    async def _safe_audit(
        self,
        *,
        incident_id: str | None,
        tool_name: str,
        args: dict[str, Any],
        risk_tier: int,
        policy_reason: str,
        status: ExecutionStatus,
        executed: bool,
        verified: bool | None,
        rolled_back: bool,
        duration_ms: int | None,
        error: BaseException | None,
    ) -> None:
        """Fire the audit hook. Never propagates hook failures.

        Audit is best-effort: a failing audit store must not fail
        execution, because execution failures have safety consequences
        while audit failures have observability consequences.
        """
        hook = self._cfg.audit_hook
        if hook is None:
            return

        try:
            record = AuditRecord(
                ts=_utc_now(),
                incident_id=incident_id,
                tool_name=tool_name,
                tool_args_hash=_hash_args(args),
                risk_tier=risk_tier,
                policy_reason=policy_reason,
                status=status,
                executed=executed,
                verified=verified,
                rolled_back=rolled_back,
                duration_ms=duration_ms,
                error_class=type(error).__name__ if error is not None else None,
            )
            await hook(record)
        except Exception:
            logger.exception(
                "Audit hook failed for tool=%s incident=%s; not propagating",
                tool_name,
                incident_id,
            )


__all__ = [
    "AuditHook",
    "AuditRecord",
    "ExecutionResult",
    "ExecutionStatus",
    "NeedsApprovalError",
    "SafeExecutor",
]
