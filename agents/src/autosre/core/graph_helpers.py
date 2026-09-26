"""Graph-wide helpers: context, JSON extraction, hypothesis and tool utilities.

Contents:
    * Phase constants and phase table
    * GraphContext — run-scoped dependencies injected via RunnableConfig
    * Action idempotency helpers (mutation-aware)
    * LLM response content extraction
    * JSON extraction from unstructured LLM output (fence, prose, nesting)
    * Hypothesis validation and normalization
    * Tool metadata extraction (deterministic, cache-friendly ordering)
    * Small utilities: top_hypothesis, is_high_confidence, approval parsing

## Contract with state.py

All graph-wide constants (iteration budget, thresholds, limits) live in
``state.py``. This module re-exports the legacy alias ``MAX_ITERATIONS``
for backward compatibility but does not define any new constants that
describe the same limit. If a number needs to change, it changes in
``state.py``.

## Contract with graph_nodes.py

Nodes call into this module for:

    * get_graph_context(config)          — extract GraphContext, raises on
                                           shape error rather than returning
                                           None, so node code paths are
                                           unambiguous.
    * is_action_already_executed(...)    — mutation-aware idempotency guard.
    * count_action_attempts(...)         — per-tool retry counter.
    * parse_json_response(...)           — never returns a non-dict unless
                                           ``allow_array=True``.
    * top_hypothesis / is_high_confidence — read-only ranking helpers.

## Idempotency semantics

``is_action_already_executed`` treats MUTATING_TOOLS by name only. Two
proposals to restart the same deployment with different ``reason`` strings
are considered the same action. Non-mutating tools compare tool_name AND
tool_args exactly. This is the single mechanism that prevents a runaway
LLM from restarting a deployment 5 times in one investigation.
"""

from __future__ import annotations

import inspect
import json
import logging
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Literal, cast

from langchain_core.runnables import RunnableConfig

from autosre.core.context import ContextEviction
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import (
    HIGH_CONFIDENCE_THRESHOLD,
    INITIAL_ITERATION_BUDGET,
    Hypothesis,
)
from autosre.safety.executor import SafeExecutor
from autosre.safety.policy import PolicyEngine
from autosre.tools.registry import ToolRegistry

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Phase table
#
# Kept in sync with state.GraphPhase Literal. Tests assert
# set(PHASES) == set(GraphPhase.__args__).
# ---------------------------------------------------------------------------

PHASE_TRIAGE = "triage"
PHASE_INVESTIGATE = "investigate"
PHASE_HYPOTHESIZE = "hypothesize"
PHASE_PROPOSE = "propose"
PHASE_APPROVE = "approve"
PHASE_EXECUTE = "execute"
PHASE_VERIFY = "verify"
PHASE_COMPLETE = "complete"

PHASES: tuple[str, ...] = (
    PHASE_TRIAGE,
    PHASE_INVESTIGATE,
    PHASE_HYPOTHESIZE,
    PHASE_PROPOSE,
    PHASE_APPROVE,
    PHASE_EXECUTE,
    PHASE_VERIFY,
    PHASE_COMPLETE,
)

# ---------------------------------------------------------------------------
# Re-exports and tool classification
#
# The legacy name MAX_ITERATIONS is retained so external code and older
# tests continue to work. New code should import INITIAL_ITERATION_BUDGET
# from state.py directly.
# ---------------------------------------------------------------------------

MAX_ITERATIONS: int = INITIAL_ITERATION_BUDGET

READ_ONLY_TOOL_NAMES: frozenset[str] = frozenset(
    {
        "get_pod_events",
        "get_pod_logs",
        "get_deployment_status",
        "query_openobserve",
        "get_postgres_stats",
        "get_valkey_stats",
        "list_pods",
        "get_active_queries",
        "get_lock_waits",
        "get_connection_stats",
        "get_pod_metrics",
        "get_valkey_stream_info",
    }
)

# Tools whose execution mutates cluster or database state. Used by
# is_action_already_executed to enforce at-most-one-in-flight semantics
# regardless of the LLM's argument drift.
MUTATING_TOOLS: frozenset[str] = frozenset(
    {
        "restart_deployment",
        "scale_deployment",
        "delete_pod",
        "terminate_backend",
        "delete_valkey_key",
        "set_feature_flag",
    }
)

# Advisory map used only for prompt construction and UI hints. The
# authoritative tier lives on each Tool's risk_tier attribute.
REMEDIATION_RISK_TIERS: dict[str, int] = {
    "restart_deployment": 1,
    "terminate_backend": 1,
    "delete_valkey_key": 1,
    "scale_deployment": 2,
    "delete_pod": 1,
    "set_feature_flag": 2,
}

# ---------------------------------------------------------------------------
# GraphContext
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GraphContext:
    """Run-scoped dependencies injected into every graph node via config.

    Frozen so nodes cannot accidentally rebind a field. The referenced
    objects are still mutable (registries, executors), which is
    intentional.
    """

    llm_router: TokenVelocityRouter
    registry: ToolRegistry
    executor: SafeExecutor
    policy_engine: PolicyEngine
    context_eviction: ContextEviction


def get_graph_context(config: RunnableConfig) -> GraphContext:
    """Extract and validate GraphContext from RunnableConfig.

    Raises:
        ValueError: If the config is malformed or does not contain a
            GraphContext under ``config['configurable']['graph_context']``.
    """
    if not isinstance(config, Mapping):
        raise ValueError(f"RunnableConfig must be a mapping, got {type(config).__name__}")

    configurable = config.get("configurable") or {}

    if not isinstance(configurable, Mapping):
        raise ValueError(
            f"config['configurable'] must be a mapping, got {type(configurable).__name__}"
        )

    ctx = configurable.get("graph_context")

    if not isinstance(ctx, GraphContext):
        raise ValueError("GraphContext must be provided in config['configurable']['graph_context']")

    return ctx


# ---------------------------------------------------------------------------
# Async helpers
# ---------------------------------------------------------------------------


async def maybe_await(value: Any) -> Any:
    """Await an async result while tolerating synchronous test doubles."""
    if inspect.isawaitable(value):
        return await value
    return value


# ---------------------------------------------------------------------------
# Action idempotency
# ---------------------------------------------------------------------------


def is_action_already_executed(
    tool_name: str,
    tool_args: Mapping[str, Any],
    executed_actions: Sequence[Mapping[str, Any]],
) -> bool:
    """Return whether this action has already been executed.

    For MUTATING_TOOLS, matching is by tool_name only. Two restart
    proposals with different ``reason`` strings are treated as the same
    action, because from the deployment's perspective they are.

    For non-mutating tools, both tool_name and tool_args must match
    exactly. This preserves the ability to call get_pod_logs with
    different pod names in one investigation.
    """
    if not tool_name:
        return False

    match_by_name_only = tool_name in MUTATING_TOOLS

    for action in executed_actions:
        if action.get("tool_name") != tool_name:
            continue

        if match_by_name_only:
            return True

        if action.get("tool_args", {}) == dict(tool_args):
            return True

    return False


def count_action_attempts(
    tool_name: str,
    executed_actions: Sequence[Mapping[str, Any]],
) -> int:
    """Return how many times a specific tool has been executed."""
    if not tool_name:
        return 0
    return sum(1 for action in executed_actions if action.get("tool_name") == tool_name)


# ---------------------------------------------------------------------------
# Response content extraction
# ---------------------------------------------------------------------------


def _mapping_value(
    value: Any,
    key: str,
    default: Any = None,
) -> Any:
    """Read one field from mapping-like or object-style values."""
    if isinstance(value, Mapping):
        return value.get(key, default)
    return getattr(value, key, default)


def response_content(response: Any) -> Any:
    """Extract message content from OpenAI-compatible or mapping responses.

    Accepts a LiteLLM/OpenAI response object or an equivalent nested
    mapping. Returns the innermost ``content`` value. Raises ValueError
    on structurally invalid inputs rather than returning None, so callers
    never silently process an empty response.
    """
    if isinstance(response, Mapping):
        if "choices" in response:
            choices = response["choices"]
            if not isinstance(choices, Sequence) or isinstance(choices, (str, bytes, bytearray)):
                raise ValueError("LLM response choices must be an array")
            if not choices:
                raise ValueError("LLM response contained no choices")
            return response_content(choices[0])

        if "message" in response:
            return response_content(response["message"])

        if "content" in response:
            return response["content"]

        return response

    choices = getattr(response, "choices", None)
    if choices is not None:
        if not isinstance(choices, Sequence) or isinstance(choices, (str, bytes, bytearray)):
            raise ValueError("LLM response choices must be an array")
        if not choices:
            raise ValueError("LLM response contained no choices")
        return response_content(choices[0])

    message = getattr(response, "message", None)
    if message is not None:
        return response_content(message)

    if hasattr(response, "content"):
        content = response.content
        if content is not None:
            return content

    raise ValueError(f"Unsupported LLM response type: {type(response)!r}")


def content_to_text(content: Any) -> str:
    """Normalize common message-content representations to text.

    Handles str, bytes, Mapping with ``text``/``content`` keys, and
    sequences of content parts. Never raises; always returns a string.
    """
    if isinstance(content, str):
        return content

    if isinstance(content, bytes):
        return content.decode("utf-8", errors="replace")

    if isinstance(content, Mapping):
        text = content.get("text")
        if text is not None:
            return str(text)

        nested = content.get("content")
        if nested is not None:
            return content_to_text(nested)

        return json.dumps(content, ensure_ascii=False, default=str)

    if isinstance(content, Sequence) and not isinstance(content, (str, bytes, bytearray)):
        return "".join(content_to_text(item) for item in content)

    return str(content)


# ---------------------------------------------------------------------------
# JSON extraction from unstructured LLM output
#
# LLM responses frequently contain prose, markdown fences, or trailing
# commentary around the JSON payload. The extraction cascade is:
#
#   1. Direct json.loads(text)
#   2. Strip markdown fence, retry
#   3. Find the first balanced {..} or [..] and parse it
#   4. Greedy regex fallback for pathological inputs
#
# The balanced scan is string-aware: braces inside string literals are
# ignored, and backslash escapes are honored. This makes the extractor
# robust to evidence strings that embed JSON snippets.
# ---------------------------------------------------------------------------


_JSON_OBJECT_RE = re.compile(r"\{.*\}", re.DOTALL)
_JSON_ARRAY_RE = re.compile(r"\[.*\]", re.DOTALL)


def _strip_code_fence(text: str) -> str:
    """Return the substring inside the first ````...```` fence, if present.

    Tolerates a language tag on the opening line (````json``, ````python``)
    and arbitrary prose outside the fence. Returns the input unchanged
    (stripped) if no fence exists.
    """
    stripped = text.strip()

    if "```" not in stripped:
        return stripped

    first = stripped.find("```")
    last = stripped.rfind("```")

    if first == -1 or last <= first:
        return stripped

    inner = stripped[first + 3 : last]

    # Drop an optional language tag on the first line.
    if "\n" in inner:
        _, _, inner = inner.partition("\n")

    return inner.strip()


def _balanced_scan(
    text: str,
    start: int,
    opener: str,
    closer: str,
) -> str | None:
    """Return the first balanced ``opener...closer`` substring from ``start``.

    String-aware: characters inside a quoted string are ignored, including
    escaped quotes (``\\"``) and escaped backslashes (``\\\\``). Handles
    arbitrary nesting depth.
    """
    if start < 0 or start >= len(text) or text[start] != opener:
        return None

    depth = 0
    in_string = False
    escape = False

    for index in range(start, len(text)):
        char = text[index]

        if escape:
            escape = False
            continue

        if char == "\\" and in_string:
            escape = True
            continue

        if char == '"':
            in_string = not in_string
            continue

        if in_string:
            continue

        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return text[start : index + 1]

    return None


def _first_json_value(text: str) -> str | None:
    """Return the first balanced JSON object or array in ``text``.

    Scans left to right. The first opener encountered (``{`` or ``[``)
    determines which closer to balance against. This preserves top-level
    structure: ``[{"a":1}, {"b":2}]`` returns the whole array, not the
    first embedded object.
    """
    for index, char in enumerate(text):
        if char == "{":
            candidate = _balanced_scan(text, index, "{", "}")
            if candidate is not None:
                return candidate
        elif char == "[":
            candidate = _balanced_scan(text, index, "[", "]")
            if candidate is not None:
                return candidate
    return None


def _try_parse_json(text: str) -> Any:
    """Return the parsed JSON value or raise ValueError.

    Does not enforce object-vs-array typing; the caller decides.
    """
    # 1. Direct.
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # 2. Fence strip.
    unfenced = _strip_code_fence(text)
    if unfenced != text:
        try:
            return json.loads(unfenced)
        except json.JSONDecodeError:
            text = unfenced

    # 3. First balanced value.
    candidate = _first_json_value(text)
    if candidate is not None:
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass

    # 4. Greedy regex fallback for pathological inputs.
    for pattern in (_JSON_OBJECT_RE, _JSON_ARRAY_RE):
        match = pattern.search(text)
        if match is None:
            continue
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            continue

    raise ValueError("no valid JSON payload found")


def parse_json_response(
    response: Any,
    *,
    stage: str,
    allow_array: bool = False,
) -> dict[str, Any]:
    """Parse a JSON object from an LLM response.

    Args:
        response: LiteLLM/OpenAI response or equivalent nested mapping.
        stage: Label used in error messages (e.g. "triage").
        allow_array: When True, a top-level JSON array is wrapped as
            ``{"items": [...]}`` so hypothesis-producing stages can accept
            either ``{"hypotheses": [...]}`` or a bare ``[{...}, ...]``.

    Raises:
        ValueError: On empty content, unparseable content, or a non-object
            payload when ``allow_array=False``.
    """
    content = response_content(response)

    if isinstance(content, Mapping):
        return dict(content)

    text = content_to_text(content).strip()
    if not text:
        raise ValueError(f"{stage} response was empty")

    try:
        payload = _try_parse_json(text)
    except ValueError as exc:
        snippet = text[:200].replace("\n", " ")
        raise ValueError(f"{stage} response was not valid JSON: {exc}; got: {snippet!r}") from exc

    if isinstance(payload, dict):
        return payload

    if isinstance(payload, list):
        if allow_array:
            return {"items": payload}
        raise ValueError(f"{stage} response must be a JSON object, got a list")

    raise ValueError(f"{stage} response must be a JSON object, got {type(payload).__name__}")


# ---------------------------------------------------------------------------
# Hypothesis validation
# ---------------------------------------------------------------------------

HypothesisStatus = Literal["proposed", "confirmed", "rejected"]

_VALID_STATUSES: frozenset[str] = frozenset({"proposed", "confirmed", "rejected"})


def as_confidence(value: Any) -> float:
    """Validate a hypothesis confidence score in [0, 1].

    Rejects bool (a subclass of int but semantically distinct), NaN, and
    Inf. Raises ValueError with a message that names the constraint.
    """
    if isinstance(value, bool):
        raise ValueError("confidence must be numeric, not bool")

    try:
        confidence = float(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise ValueError("confidence must be numeric") from exc

    # Reject NaN and Inf explicitly.
    if not (0.0 <= confidence <= 1.0):
        raise ValueError("confidence must be between 0 and 1")

    return confidence


def normalize_hypotheses(
    raw: Any,
    *,
    default_status: str,
) -> list[Hypothesis]:
    """Validate model hypotheses and convert them to the project state shape.

    Args:
        raw: Sequence of hypothesis-like mappings.
        default_status: Fallback status for entries missing or carrying an
            invalid ``status`` field. Must be one of the three valid
            statuses; otherwise "proposed" is used.

    Raises:
        ValueError: On non-sequence input, empty list, malformed entries,
            missing id/description, or invalid confidence.
    """
    if not isinstance(raw, Sequence) or isinstance(raw, (str, bytes, bytearray)):
        raise ValueError("hypotheses must be a JSON array")

    fallback_status: HypothesisStatus = (
        cast(HypothesisStatus, default_status) if default_status in _VALID_STATUSES else "proposed"
    )

    hypotheses: list[Hypothesis] = []

    for index, item in enumerate(raw, start=1):
        if not isinstance(item, Mapping):
            raise ValueError(f"hypothesis {index} must be an object, got {type(item).__name__}")

        raw_id = item.get("id")
        hypothesis_id = f"H{index}" if raw_id is None else str(raw_id).strip()

        raw_description = item.get("description")
        description = "" if raw_description is None else str(raw_description).strip()

        if not hypothesis_id or not description:
            raise ValueError(f"hypothesis {index} is missing id or description")

        evidence_raw = item.get("evidence", [])
        if not isinstance(evidence_raw, Sequence) or isinstance(
            evidence_raw, (str, bytes, bytearray)
        ):
            raise ValueError(f"hypothesis {index} evidence must be an array")

        evidence = [str(value) for value in evidence_raw]

        raw_status = str(item.get("status", fallback_status)).strip()
        status: HypothesisStatus = (
            cast(HypothesisStatus, raw_status) if raw_status in _VALID_STATUSES else fallback_status
        )

        hypotheses.append(
            Hypothesis(
                id=hypothesis_id,
                description=description,
                confidence=as_confidence(item.get("confidence", 0.0)),
                evidence=evidence,
                status=status,
            )
        )

    if not hypotheses:
        raise ValueError("LLM returned no hypotheses")

    return hypotheses


# ---------------------------------------------------------------------------
# Tool metadata extraction
# ---------------------------------------------------------------------------


def tool_name(tool: Any) -> str | None:
    """Extract a registry tool name. Returns None for malformed entries."""
    value = _mapping_value(tool, "name")
    if value is None:
        return None
    name = str(value).strip()
    return name or None


def tool_description(tool: Any) -> str:
    """Extract a registry tool description. Returns empty string if absent."""
    value = _mapping_value(tool, "description", "")
    return str(value or "").strip()


def tool_declared_risk_tier(tool: Any) -> int | None:
    """Extract an optional registry-provided integer risk tier.

    Rejects bool, negative integers, and non-integral floats. Returns None
    when the tool does not declare a tier.
    """
    raw = _mapping_value(tool, "risk_tier")

    if raw is None or isinstance(raw, bool):
        return None

    if isinstance(raw, int):
        return raw if raw >= 0 else None

    if isinstance(raw, float) and raw.is_integer() and raw >= 0:
        return int(raw)

    return None


async def list_tool_specs(registry: ToolRegistry) -> list[dict[str, Any]]:
    """Return deterministic JSON-safe tool metadata including input schemas.

    Sorted alphabetically by name. Deterministic ordering is required for
    Groq prompt-cache prefix matching: identical schemas in identical order
    enable cache hits across calls.

    Tries ``to_openai_schema()`` first; falls back to
    ``input_model.model_json_schema()``. Any error during schema extraction
    yields an empty schema for that tool rather than failing the whole
    listing.
    """
    raw_tools = await maybe_await(registry.list_tools())

    if raw_tools is None:
        return []

    ordered_tools = sorted(
        (tool for tool in raw_tools if tool_name(tool)),
        key=lambda tool: tool_name(tool) or "",
    )

    specs: list[dict[str, Any]] = []

    for tool in ordered_tools:
        name = tool_name(tool)
        if not name:
            continue

        input_schema: dict[str, Any] = {}

        to_openai_schema = getattr(tool, "to_openai_schema", None)
        try:
            if callable(to_openai_schema):
                openai_schema = to_openai_schema()
                if isinstance(openai_schema, Mapping):
                    function = openai_schema.get("function", {})
                    if isinstance(function, Mapping):
                        parameters = function.get("parameters", {})
                        if isinstance(parameters, Mapping):
                            input_schema = dict(parameters)
        except Exception:  # noqa: BLE001 — schema export must not break listing
            logger.debug("to_openai_schema failed for %s", name, exc_info=True)
            input_schema = {}

        if not input_schema:
            try:
                input_model = getattr(tool, "input_model", None)
                model_json_schema = getattr(input_model, "model_json_schema", None)
                if callable(model_json_schema):
                    generated = model_json_schema()
                    if isinstance(generated, Mapping):
                        input_schema = dict(generated)
            except Exception:  # noqa: BLE001 — schema export must not break listing
                logger.debug("model_json_schema failed for %s", name, exc_info=True)
                input_schema = {}

        specs.append(
            {
                "name": name,
                "description": tool_description(tool),
                "risk_tier": tool_declared_risk_tier(tool),
                "input_schema": input_schema,
            }
        )

    return specs


def find_tool(
    specs: Sequence[Mapping[str, Any]],
    name: str,
) -> Mapping[str, Any] | None:
    """Find a tool spec by exact name. Returns None if not found."""
    for spec in specs:
        if spec.get("name") == name:
            return spec
    return None


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def safe_json(value: Any, *, max_chars: int = 4000) -> str:
    """Serialize a value into bounded evidence text.

    Sort keys for deterministic output, fall back to repr on non-serializable
    inputs, and truncate to ``max_chars``. Never raises for valid inputs.
    """
    if max_chars < 0:
        raise ValueError("max_chars must be non-negative")

    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            default=str,
            sort_keys=True,
        )
    except TypeError, ValueError:
        text = repr(value)

    return text[:max_chars]


def _confidence_value(hypothesis: Mapping[str, Any]) -> float:
    """Return the hypothesis confidence or 0.0 on any parse error."""
    try:
        return as_confidence(hypothesis.get("confidence", 0.0))
    except ValueError:
        return 0.0


def top_hypothesis(
    hypotheses: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any] | None:
    """Return the highest-confidence hypothesis, or None for empty input."""
    if not hypotheses:
        return None
    return max(hypotheses, key=_confidence_value)


def is_high_confidence(
    hypotheses: Sequence[Mapping[str, Any]],
) -> bool:
    """Return whether any hypothesis reached the proposal threshold."""
    return any(
        _confidence_value(hypothesis) >= HIGH_CONFIDENCE_THRESHOLD for hypothesis in hypotheses
    )


# ---------------------------------------------------------------------------
# Approval parsing
# ---------------------------------------------------------------------------


_APPROVAL_TRUE_STRINGS: frozenset[str] = frozenset({"yes", "approve", "approved", "true"})


def approval_value_to_bool(value: Any) -> bool:
    """Normalize simple and structured approval responses to a bool.

    Accepts:
        * bool — returned as-is
        * {"approved": True | "yes" | ...} — canonical Slack/UI payload
        * {"decisions": [{"type": "approve"}]} — alternate shape
        * "yes" / "approve" / "approved" / "true" — string form

    Never raises. Unknown shapes evaluate to False.
    """
    if isinstance(value, bool):
        return value

    if isinstance(value, Mapping):
        if "approved" in value:
            approved_value = value["approved"]
            if isinstance(approved_value, bool):
                return approved_value
            return str(approved_value).strip().lower() in _APPROVAL_TRUE_STRINGS

        decisions = value.get("decisions")
        if (
            isinstance(decisions, Sequence)
            and not isinstance(decisions, (str, bytes, bytearray))
            and decisions
        ):
            first = decisions[0]
            if isinstance(first, Mapping):
                decision_type = str(first.get("type", "")).strip().lower()
                return decision_type == "approve"

        return False

    return str(value).strip().lower() in _APPROVAL_TRUE_STRINGS


__all__ = [
    # Phases
    "PHASE_TRIAGE",
    "PHASE_INVESTIGATE",
    "PHASE_HYPOTHESIZE",
    "PHASE_PROPOSE",
    "PHASE_APPROVE",
    "PHASE_EXECUTE",
    "PHASE_VERIFY",
    "PHASE_COMPLETE",
    "PHASES",
    # Constants
    "MAX_ITERATIONS",
    "READ_ONLY_TOOL_NAMES",
    "MUTATING_TOOLS",
    "REMEDIATION_RISK_TIERS",
    # Context
    "GraphContext",
    "get_graph_context",
    # Async
    "maybe_await",
    # Idempotency
    "is_action_already_executed",
    "count_action_attempts",
    # Response parsing
    "response_content",
    "content_to_text",
    "parse_json_response",
    # Hypothesis
    "HypothesisStatus",
    "as_confidence",
    "normalize_hypotheses",
    # Tools
    "tool_name",
    "tool_description",
    "tool_declared_risk_tier",
    "list_tool_specs",
    "find_tool",
    # Utilities
    "safe_json",
    "top_hypothesis",
    "is_high_confidence",
    # Approval
    "approval_value_to_bool",
]
