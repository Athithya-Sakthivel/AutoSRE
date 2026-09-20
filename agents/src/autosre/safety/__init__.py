"""Safety layer: policy engine and safe execution wrapper.

Public API:

* :class:`RiskTier` -- integer enum 0-4 for action classification.
* :class:`PolicyDecision` -- result of a policy check.
* :class:`PolicyEngine` -- classifies proposed actions.
* :class:`ExecutionResult` -- result of a safe execution.
* :class:`NeedsApprovalError` -- raised when Tier 2+ actions need HITL.
* :class:`PolicyRejectionError` -- raised when Tier 4 actions are blocked.
* :class:`SafeExecutor` -- policy-gated, rollback-capable executor.
"""

from __future__ import annotations

from autosre.safety.executor import ExecutionResult, NeedsApprovalError, SafeExecutor
from autosre.safety.policy import (
    PolicyDecision,
    PolicyEngine,
    PolicyRejectionError,
    RiskTier,
)

__all__ = [
    "ExecutionResult",
    "NeedsApprovalError",
    "PolicyDecision",
    "PolicyEngine",
    "PolicyRejectionError",
    "RiskTier",
    "SafeExecutor",
]
