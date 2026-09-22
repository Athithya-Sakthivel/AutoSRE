"""Graph constants, context dataclass, and helper utilities.

This module contains everything the graph nodes and routing functions need
that is not a node or edge itself: constants, the GraphContext dataclass,
JSON parsing helpers, and tool-spec normalization.
"""

from __future__ import annotations

import inspect
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, TypeVar

from langchain_core.runnables import RunnableConfig

from autosre.core.context import ContextEviction
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import Hypothesis
from autosre.safety.executor import SafeExecutor
from autosre.safety.policy import PolicyEngine
from autosre.tools.registry import ToolRegistry

# ---------------------------------------------------------------------------
# Phase constants
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

MAX_ITERATIONS = 10

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
    }
)

REMEDIATION_RISK_TIERS: dict[str, int] = {
    "restart_deployment": 1,
    "terminate_backend": 1,
    "delete_valkey_key": 1,
    "scale_deployment": 2,
}


# ---------------------------------------------------------------------------
# Graph context
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GraphContext:
    """Run-scoped dependencies injected into every graph node via config."""

    llm_router: TokenVelocityRouter
    registry: ToolRegistry
    executor: SafeExecutor
    policy_engine: PolicyEngine
    context_eviction: ContextEviction


def get_graph_context(config: RunnableConfig) -> GraphContext:
    """Extract GraphContext from RunnableConfig's configurable dict."""
    configurable = config.get("configurable", {})
    ctx = configurable.get("graph_context")
    if ctx is None or not isinstance(ctx, GraphContext):
        raise ValueError("GraphContext must be provided in config['configurable']['graph_context']")
    # ctx is already validated as GraphContext by isinstance above,
    # so no cast is needed — mypy narrows the type through the guard.
    return ctx


# ---------------------------------------------------------------------------
# Await helper
# ---------------------------------------------------------------------------

ContextT = TypeVar("ContextT")


async def maybe_await(value: Any) -> Any:
    """Await an async result while tolerating synchronous test doubles."""
    if inspect.isawaitable(value):
        return await value
    return value


# ---------------------------------------------------------------------------
# LLM response parsing
# ---------------------------------------------------------------------------


def response_content(response: Any) -> Any:
    """Extract message content from OpenAI-compatible or mapping responses."""
    if isinstance(response, Mapping):
        if "choices" in response:
            choices = response["choices"]
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
        if not choices:
            raise ValueError("LLM response contained no choices")
        return response_content(choices[0])

    message = getattr(response, "message", None)
    if message is not None:
        return response_content(message)

    content = getattr(response, "content", None)
    if content is not None:
        return content

    raise ValueError(f"Unsupported LLM response type: {type(response)!r}")


def content_to_text(content: Any) -> str:
    """Normalize common message-content representations to text."""
    if isinstance(content, str):
        return content

    if isinstance(content, Mapping):
        return json.dumps(content, default=str)

    if isinstance(content, Sequence) and not isinstance(content, (str, bytes, bytearray)):
        parts: list[str] = []
        for item in content:
            if isinstance(item, Mapping):
                text = item.get("text")
                if text is not None:
                    parts.append(str(text))
                    continue
                nested_content = item.get("content")
                if nested_content is not None:
                    parts.append(str(nested_content))
                    continue
            else:
                parts.append(str(item))
        return "".join(parts)

    return str(content)


def parse_json_response(response: Any, *, stage: str) -> dict[str, Any]:
    """Parse a JSON object returned by the coordinator."""
    content = response_content(response)

    if isinstance(content, Mapping):
        return dict(content)

    text = content_to_text(content).strip()

    if text.startswith("```"):
        first_newline = text.find("\n")
        last_fence = text.rfind("```")
        if first_newline != -1 and last_fence > first_newline:
            text = text[first_newline + 1 : last_fence].strip()

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end <= start:
            raise ValueError(f"{stage} response was not valid JSON") from None
        try:
            payload = json.loads(text[start : end + 1])
        except json.JSONDecodeError as exc:
            raise ValueError(f"{stage} response was not valid JSON") from exc

    if not isinstance(payload, dict):
        raise ValueError(f"{stage} response must be a JSON object")

    return payload


# ---------------------------------------------------------------------------
# Hypothesis normalization
# ---------------------------------------------------------------------------


def as_confidence(value: Any) -> float:
    """Validate a hypothesis confidence score."""
    if isinstance(value, bool):
        raise ValueError("confidence must be numeric")
    confidence = float(value)
    if not 0.0 <= confidence <= 1.0:
        raise ValueError("confidence must be between 0 and 1")
    return confidence


def normalize_hypotheses(
    raw: Any,
    *,
    default_status: str,
) -> list[Hypothesis]:
    """Validate model hypotheses and convert them to the project state shape."""
    if not isinstance(raw, Sequence) or isinstance(raw, (str, bytes, bytearray)):
        raise ValueError("hypotheses must be a JSON array")

    hypotheses: list[Hypothesis] = []
    for index, item in enumerate(raw, start=1):
        if not isinstance(item, Mapping):
            raise ValueError(f"hypothesis {index} must be an object")

        hypothesis_id = str(item.get("id", f"H{index}")).strip()
        description = str(item.get("description", "")).strip()
        if not hypothesis_id or not description:
            raise ValueError(f"hypothesis {index} is missing id or description")

        evidence_raw = item.get("evidence", [])
        if not isinstance(evidence_raw, Sequence) or isinstance(
            evidence_raw, (str, bytes, bytearray)
        ):
            raise ValueError(f"hypothesis {index} evidence must be an array")
        evidence = [str(v) for v in evidence_raw]

        # Enforce the Literal type declared on Hypothesis["status"]
        raw_status = str(item.get("status", default_status)).strip() or default_status
        valid_statuses = {"proposed", "confirmed", "rejected"}
        if raw_status not in valid_statuses:
            raw_status = default_status if default_status in valid_statuses else "proposed"

        hypotheses.append(
            Hypothesis(
                id=hypothesis_id,
                description=description,
                confidence=as_confidence(item.get("confidence", 0.0)),
                evidence=evidence,
                status=raw_status,  # type: ignore[typeddict-item]
            )
        )

    if not hypotheses:
        raise ValueError("LLM returned no hypotheses")
    return hypotheses


# ---------------------------------------------------------------------------
# Tool-spec normalization
# ---------------------------------------------------------------------------


def tool_name(tool: Any) -> str | None:
    """Extract a registry tool name."""
    value = tool.get("name") if isinstance(tool, Mapping) else getattr(tool, "name", None)
    if value is None:
        return None
    name = str(value).strip()
    return name or None


def tool_description(tool: Any) -> str:
    """Extract a registry tool description."""
    value = (
        tool.get("description", "")
        if isinstance(tool, Mapping)
        else getattr(tool, "description", "")
    )
    return str(value or "").strip()


def tool_declared_risk_tier(tool: Any) -> int | None:
    """Extract an optional registry-provided risk tier."""
    raw = tool.get("risk_tier") if isinstance(tool, Mapping) else getattr(tool, "risk_tier", None)
    if raw is None or isinstance(raw, bool):
        return None
    try:
        tier = int(raw)
    except TypeError, ValueError:
        return None
    return tier if tier >= 0 else None


async def list_tool_specs(
    registry: ToolRegistry,
) -> list[dict[str, Any]]:
    """Return normalized JSON-safe tool metadata including input schema."""
    raw_tools = await maybe_await(registry.list_tools())
    if raw_tools is None:
        return []

    specs: list[dict[str, Any]] = []
    for t in raw_tools:
        name = tool_name(t)
        if not name:
            continue

        # Get the full input schema from the Pydantic model
        input_schema: dict[str, Any] = {}
        try:
            if hasattr(t, "to_openai_schema"):
                openai_schema = t.to_openai_schema()
                input_schema = openai_schema.get("function", {}).get("parameters", {})
            elif hasattr(t, "input_model") and hasattr(t.input_model, "model_json_schema"):
                input_schema = t.input_model.model_json_schema()
        except Exception:
            pass

        specs.append(
            {
                "name": name,
                "description": tool_description(t),
                "risk_tier": tool_declared_risk_tier(t),
                "input_schema": input_schema,
            }
        )
    return specs


def find_tool(specs: Sequence[Mapping[str, Any]], name: str) -> Mapping[str, Any] | None:
    """Find a tool spec by exact name."""
    for spec in specs:
        if spec.get("name") == name:
            return spec
    return None


def safe_json(value: Any, *, max_chars: int = 4000) -> str:
    """Serialize tool output into bounded evidence."""
    try:
        text = json.dumps(value, default=str, sort_keys=True)
    except TypeError, ValueError:
        text = repr(value)
    return text[:max_chars]


def top_hypothesis(
    hypotheses: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any] | None:
    """Return the highest-confidence hypothesis."""
    if not hypotheses:
        return None
    return max(
        hypotheses,
        key=lambda h: float(h.get("confidence", 0.0)),
    )


def is_high_confidence(
    hypotheses: Sequence[Mapping[str, Any]],
) -> bool:
    """Return whether any hypothesis reached the proposal threshold."""
    return any(float(h.get("confidence", 0.0)) >= 0.8 for h in hypotheses)


def approval_value_to_bool(value: Any) -> bool:
    """Normalize simple and structured approval responses."""
    if isinstance(value, bool):
        return value

    if isinstance(value, Mapping):
        if "approved" in value:
            approved_value = value["approved"]
            if isinstance(approved_value, bool):
                return approved_value
            return str(approved_value).strip().lower() in {"yes", "approve", "approved", "true"}

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

    return str(value).strip().lower() in {
        "yes",
        "approve",
        "approved",
        "true",
    }
