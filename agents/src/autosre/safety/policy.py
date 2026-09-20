"""Risk-tier policy engine for autonomous SRE actions.

The policy engine classifies a proposed tool call before execution. The
classifier is deliberately independent of :class:`SREContext`; runtime state
checks belong in the tool layer or another explicit policy layer.

Tier model:

* **Tier 0** -- Observe. Read-only. Always allowed.
* **Tier 1** -- Reversible, low blast radius. Allowed autonomously.
* **Tier 2** -- Reversible, higher blast radius. Requires HITL approval.
* **Tier 3** -- Irreversible but bounded. Requires HITL approval.
* **Tier 4** -- Prohibited. Hard-blocked regardless of approval.

Rules are evaluated from top to bottom. The first matching rule wins. If no
rule matches, the tool's declared ``risk_tier`` is used as the fallback.
"""

from __future__ import annotations

import enum
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

_HARD_BLOCKED_TOOLS = frozenset({"delete_namespace", "flush_all", "drop_table"})


class RiskTier(enum.IntEnum):
    """Integer risk tiers ordered from 0 (safest) to 4 (prohibited)."""

    OBSERVE = 0
    REVERSIBLE_LOW = 1
    REVERSIBLE_HIGH = 2
    IRREVERSIBLE_BOUNDED = 3
    PROHIBITED = 4


@dataclass(frozen=True)
class PolicyDecision:
    """Outcome of a policy classification.

    ``allowed`` is false only for hard-blocked actions. Actions that are
    allowed but exceed ``max_autonomous_tier`` have ``requires_approval`` set
    to true and must be paused for HITL before dispatch.
    """

    allowed: bool
    risk_tier: RiskTier
    requires_approval: bool
    reason: str


class PolicyRejectionError(Exception):
    """Raised when an action is hard-blocked by policy."""

    def __init__(self, decision: PolicyDecision) -> None:
        super().__init__(decision.reason)
        self.decision = decision


_Rule = dict[str, Any]


def _reject(reason: str) -> PolicyRejectionError:
    """Build a Tier-4 rejection for malformed or prohibited input."""
    return PolicyRejectionError(
        PolicyDecision(
            allowed=False,
            risk_tier=RiskTier.PROHIBITED,
            requires_approval=False,
            reason=reason,
        )
    )


def _contains_wildcard(value: Any) -> bool:
    """Return true when a JSON-like value contains a glob character.

    Policy checks must not be bypassed by nesting a wildcard inside a list or
    mapping. Only JSON-like containers are traversed; arbitrary application
    objects are intentionally treated as opaque values.
    """
    if isinstance(value, str):
        return any(character in value for character in "*?[]")

    if isinstance(value, Mapping):
        return any(
            _contains_wildcard(key) or _contains_wildcard(item) for key, item in value.items()
        )

    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return any(_contains_wildcard(item) for item in value)

    return False


def _has_wildcard_arguments(args: Mapping[str, Any]) -> bool:
    """Return true if any action argument contains a wildcard/glob."""
    return any(_contains_wildcard(item) for item in args.values())


def _parse_replicas(value: Any) -> int | None:
    """Parse an integer replica count without accepting booleans or floats."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return int(text, 10)
        except ValueError:
            return None
    return None


def _is_invalid_scale(args: dict[str, Any]) -> bool:
    """True for missing, malformed, or negative replica counts."""
    replicas = _parse_replicas(args.get("replicas"))
    return replicas is None or replicas < 0


def _is_scale_to_zero(args: dict[str, Any]) -> bool:
    """True when a deployment is being scaled to zero replicas."""
    return _parse_replicas(args.get("replicas")) == 0


def _is_scale_positive(args: dict[str, Any]) -> bool:
    """True when a deployment is being scaled to a positive replica count."""
    replicas = _parse_replicas(args.get("replicas"))
    return replicas is not None and replicas > 0


def _is_system_namespace(args: dict[str, Any]) -> bool:
    """True when the action targets a protected system namespace."""
    namespace = args.get("namespace")
    return isinstance(namespace, str) and namespace in {
        "kube-system",
        "kube-public",
        "kube-node-lease",
        "cert-manager",
    }


_DEFAULT_RULES: list[_Rule] = [
    # Tier 4: prohibited operations.
    {
        "tool": "delete_namespace",
        "tier": RiskTier.PROHIBITED,
        "reason": (
            "Namespace deletion is prohibited: it destroys every resource "
            "inside the namespace and is not reversible."
        ),
    },
    {
        "tool": "flush_all",
        "tier": RiskTier.PROHIBITED,
        "reason": (
            "FLUSHALL is prohibited: it destroys every key in the cache "
            "and invalidates every active session."
        ),
    },
    {
        "tool": "drop_table",
        "tier": RiskTier.PROHIBITED,
        "reason": "Table drop is prohibited: it destroys all rows permanently.",
    },
    {
        "tool": "*",
        "match": _is_system_namespace,
        "tier": RiskTier.PROHIBITED,
        "reason": (
            "Actions targeting system namespaces (kube-system, kube-public, "
            "kube-node-lease, cert-manager) are prohibited."
        ),
    },
    # Tier 3: irreversible but bounded.
    {
        "tool": "delete_database_row",
        "tier": RiskTier.IRREVERSIBLE_BOUNDED,
        "reason": (
            "Row deletion is irreversible; requires human approval even "
            "though the blast radius is bounded to one row."
        ),
    },
    # Tier 2: reversible, higher blast radius.
    {
        "tool": "scale_deployment",
        "match": _is_scale_to_zero,
        "tier": RiskTier.REVERSIBLE_HIGH,
        "reason": (
            "Scaling a deployment to zero replicas takes the service offline; "
            "requires human approval."
        ),
    },
    {
        "tool": "set_feature_flag",
        "tier": RiskTier.REVERSIBLE_HIGH,
        "reason": ("Feature flag changes can affect many requests; requires human approval."),
    },
    {
        "tool": "scale_deployment",
        "match": _is_scale_positive,
        "tier": RiskTier.REVERSIBLE_LOW,
        "reason": (
            "Scaling to a positive replica count is reversible with a bounded blast radius."
        ),
    },
    # Tier 1: reversible, low blast radius.
    {
        "tool": "restart_deployment",
        "tier": RiskTier.REVERSIBLE_LOW,
        "reason": "Rollout restart is reversible with low blast radius.",
    },
    {
        "tool": "terminate_backend",
        "tier": RiskTier.REVERSIBLE_LOW,
        "reason": (
            "Terminating a single Postgres backend is bounded and reversible "
            "because the client can reconnect."
        ),
    },
    {
        "tool": "delete_valkey_key",
        "tier": RiskTier.REVERSIBLE_LOW,
        "reason": "Deleting one exact cache key is bounded and reversible.",
    },
]


class PolicyEngine:
    """Classify proposed actions into risk tiers.

    Args:
        rules: Ordered policy rules. If omitted, the built-in rules are used.
        max_autonomous_tier: Highest tier that may execute without HITL.
        allowed_namespaces: Namespace allowlist. A supplied namespace outside
            this set is hard-blocked before rule evaluation.
    """

    def __init__(
        self,
        rules: list[dict[str, Any]] | None = None,
        max_autonomous_tier: RiskTier = RiskTier.REVERSIBLE_LOW,
        allowed_namespaces: frozenset[str] | None = None,
    ) -> None:
        try:
            self._max_autonomous = RiskTier(max_autonomous_tier)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid max_autonomous_tier: {max_autonomous_tier!r}") from exc

        namespaces = (
            allowed_namespaces if allowed_namespaces is not None else frozenset({"rivulet", "sre"})
        )
        if any(not isinstance(namespace, str) or not namespace for namespace in namespaces):
            raise ValueError("allowed_namespaces must contain non-empty strings")

        self._allowed_namespaces = frozenset(namespaces)
        self._rules = self._validate_rules(rules if rules is not None else _DEFAULT_RULES)

    @staticmethod
    def _validate_rules(rules: list[dict[str, Any]]) -> list[_Rule]:
        """Validate and copy rule dictionaries.

        Copying prevents a caller from mutating the policy engine by changing
        the original rule dictionaries after construction.
        """
        validated: list[_Rule] = []

        for index, raw_rule in enumerate(rules):
            if not isinstance(raw_rule, dict):
                raise TypeError(f"policy rule {index} must be a dict")

            rule = dict(raw_rule)
            tool = rule.get("tool")
            if not isinstance(tool, str) or not tool:
                raise ValueError(f"policy rule {index} has an invalid tool")

            try:
                rule["tier"] = RiskTier(rule["tier"])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"policy rule {index} has an invalid tier") from exc

            matcher = rule.get("match")
            if matcher is not None and not callable(matcher):
                raise TypeError(f"policy rule {index} match must be callable")

            reason = rule.get("reason")
            if reason is not None and not isinstance(reason, str):
                raise TypeError(f"policy rule {index} reason must be a string")

            validated.append(rule)

        return validated

    def classify(
        self,
        tool_name: str,
        args: dict[str, Any],
        base_tier: RiskTier = RiskTier.OBSERVE,
    ) -> PolicyDecision:
        """Classify an action and raise :class:`PolicyRejectionError` if prohibited."""
        if not isinstance(tool_name, str) or not tool_name:
            raise _reject("tool name must be a non-empty string")

        if not isinstance(args, dict):
            raise _reject("tool arguments must be a dictionary")

        try:
            resolved_base_tier = RiskTier(base_tier)
        except (TypeError, ValueError) as exc:
            raise _reject(f"invalid declared tool risk tier: {base_tier!r}") from exc

        namespace = args.get("namespace")
        if namespace is not None and not isinstance(namespace, str):
            raise _reject("namespace must be a string when provided")

        if namespace == "":
            raise _reject("namespace must be non-empty when provided")

        if namespace is not None and namespace not in self._allowed_namespaces:
            allowed = sorted(self._allowed_namespaces)
            raise _reject(f"namespace '{namespace}' is not in allowed set {allowed}")

        if _has_wildcard_arguments(args):
            raise _reject(
                "wildcard or glob characters (*, ?, []) are not permitted in action arguments"
            )

        # These operations remain hard-blocked even when custom rules are
        # supplied. A policy customization must not accidentally re-enable a
        # destructive primitive.
        if tool_name in _HARD_BLOCKED_TOOLS:
            reasons = {
                "delete_namespace": (
                    "Namespace deletion is prohibited: it destroys every "
                    "resource inside the namespace and is not reversible."
                ),
                "flush_all": (
                    "FLUSHALL is prohibited: it destroys every key in the "
                    "cache and invalidates every active session."
                ),
                "drop_table": ("Table drop is prohibited: it destroys all rows permanently."),
            }
            raise _reject(reasons[tool_name])

        # Scale semantics are security-sensitive enough to reject malformed
        # requests before custom rule evaluation. This prevents an invalid
        # replica value from falling through to a lower declared tier.
        if tool_name == "scale_deployment" and _is_invalid_scale(args):
            raise _reject("scale_deployment requires a non-negative integer 'replicas' argument")

        for rule in self._rules:
            rule_tool = rule["tool"]
            if rule_tool != "*" and rule_tool != tool_name:
                continue

            matcher = rule.get("match")
            if matcher is not None:
                if not callable(matcher):
                    raise _reject("policy rule matcher is not callable")

                if not matcher(args):
                    continue

            tier = RiskTier(rule["tier"])
            reason = str(rule.get("reason") or "classified by policy rule")
            decision = self._build_decision(tier, reason)

            if not decision.allowed:
                raise PolicyRejectionError(decision)

            return decision

        decision = self._build_decision(
            resolved_base_tier,
            f"no rule matched; using tool's declared tier {resolved_base_tier}",
        )

        if not decision.allowed:
            raise PolicyRejectionError(decision)

        return decision

    def _build_decision(
        self,
        tier: RiskTier,
        reason: str,
    ) -> PolicyDecision:
        if tier == RiskTier.PROHIBITED:
            return PolicyDecision(
                allowed=False,
                risk_tier=tier,
                requires_approval=False,
                reason=reason,
            )

        return PolicyDecision(
            allowed=True,
            risk_tier=tier,
            requires_approval=tier > self._max_autonomous,
            reason=reason,
        )
