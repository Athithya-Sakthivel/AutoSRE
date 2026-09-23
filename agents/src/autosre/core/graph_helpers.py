"""Graph constants, context dataclass, and helper utilities.

This module contains graph-wide constants, the run-scoped GraphContext, LLM
response parsing, hypothesis normalization, and deterministic tool metadata
normalization.

Phase B tool names are represented in the read-only/risk classifications here;
registration remains delegated to the corresponding tool modules.
"""

from __future__ import annotations

import inspect
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Literal, cast

from langchain_core.runnables import RunnableConfig

from autosre.core.context import ContextEviction
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import Hypothesis
from autosre.safety.executor import SafeExecutor
from autosre.safety.policy import PolicyEngine
from autosre.tools.registry import ToolRegistry

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
        "get_pod_metrics",
        "get_valkey_stream_info",
    }
)


REMEDIATION_RISK_TIERS: dict[str, int] = {
    "restart_deployment": 1,
    "terminate_backend": 1,
    "delete_valkey_key": 1,
    "scale_deployment": 2,
    "delete_pod": 1,
    "set_feature_flag": 2,
}


@dataclass(frozen=True, slots=True)
class GraphContext:
    """Run-scoped dependencies injected into every graph node via config."""

    llm_router: TokenVelocityRouter
    registry: ToolRegistry
    executor: SafeExecutor
    policy_engine: PolicyEngine
    context_eviction: ContextEviction


def get_graph_context(
    config: RunnableConfig,
) -> GraphContext:
    """Extract and validate GraphContext from RunnableConfig."""
    configurable = config.get("configurable") or {}

    ctx = configurable.get("graph_context")

    if not isinstance(ctx, GraphContext):
        raise ValueError("GraphContext must be provided in config['configurable']['graph_context']")

    return ctx


async def maybe_await(value: Any) -> Any:
    """Await an async result while tolerating synchronous test doubles."""
    if inspect.isawaitable(value):
        return await value
    return value


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
    """Extract message content from OpenAI-compatible or mapping responses."""
    if isinstance(response, Mapping):
        if "choices" in response:
            choices = response["choices"]

            if not isinstance(choices, Sequence) or isinstance(
                choices,
                (str, bytes, bytearray),
            ):
                raise ValueError("LLM response choices must be an array")

            if not choices:
                raise ValueError("LLM response contained no choices")

            return response_content(choices[0])

        if "message" in response:
            return response_content(response["message"])

        if "content" in response:
            return response["content"]

        return response

    choices = getattr(
        response,
        "choices",
        None,
    )

    if choices is not None:
        if not isinstance(choices, Sequence) or isinstance(
            choices,
            (str, bytes, bytearray),
        ):
            raise ValueError("LLM response choices must be an array")

        if not choices:
            raise ValueError("LLM response contained no choices")

        return response_content(choices[0])

    message = getattr(
        response,
        "message",
        None,
    )

    if message is not None:
        return response_content(message)

    if hasattr(response, "content"):
        content = response.content

        if content is not None:
            return content

    raise ValueError(f"Unsupported LLM response type: {type(response)!r}")


def content_to_text(content: Any) -> str:
    """Normalize common message-content representations to text."""
    if isinstance(content, str):
        return content

    if isinstance(content, bytes):
        return content.decode(
            "utf-8",
            errors="replace",
        )

    if isinstance(content, Mapping):
        text = content.get("text")

        if text is not None:
            return str(text)

        nested = content.get("content")

        if nested is not None:
            return content_to_text(nested)

        return json.dumps(
            content,
            ensure_ascii=False,
            default=str,
        )

    if isinstance(content, Sequence) and not isinstance(
        content,
        (str, bytes, bytearray),
    ):
        return "".join(content_to_text(item) for item in content)

    return str(content)


def _strip_code_fence(text: str) -> str:
    """Remove one Markdown fenced block around a JSON response."""
    stripped = text.strip()

    if not stripped.startswith("```"):
        return stripped

    lines = stripped.splitlines()

    if len(lines) < 3:
        return stripped

    body = lines[1:-1] if lines[-1].strip() == "```" else lines[1:]

    return "\n".join(body).strip()


def parse_json_response(
    response: Any,
    *,
    stage: str,
) -> dict[str, Any]:
    """Parse a JSON object returned by the coordinator."""
    content = response_content(response)

    if isinstance(content, Mapping):
        return dict(content)

    text = _strip_code_fence(content_to_text(content))

    if not text:
        raise ValueError(f"{stage} response was empty")

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


def as_confidence(value: Any) -> float:
    """Validate a hypothesis confidence score in [0, 1]."""
    if isinstance(value, bool):
        raise ValueError("confidence must be numeric")

    try:
        confidence = float(value)

    except (TypeError, ValueError, OverflowError) as exc:
        raise ValueError("confidence must be numeric") from exc

    if not 0.0 <= confidence <= 1.0:
        raise ValueError("confidence must be between 0 and 1")

    return confidence


HypothesisStatus = Literal[
    "proposed",
    "confirmed",
    "rejected",
]


def normalize_hypotheses(
    raw: Any,
    *,
    default_status: str,
) -> list[Hypothesis]:
    """Validate model hypotheses and convert them to the project state shape."""
    if not isinstance(raw, Sequence) or isinstance(
        raw,
        (str, bytes, bytearray),
    ):
        raise ValueError("hypotheses must be a JSON array")

    fallback_status: HypothesisStatus = (
        cast(
            HypothesisStatus,
            default_status,
        )
        if default_status
        in {
            "proposed",
            "confirmed",
            "rejected",
        }
        else "proposed"
    )

    hypotheses: list[Hypothesis] = []

    for index, item in enumerate(
        raw,
        start=1,
    ):
        if not isinstance(item, Mapping):
            raise ValueError(f"hypothesis {index} must be an object")

        raw_id = item.get("id")

        hypothesis_id = f"H{index}" if raw_id is None else str(raw_id).strip()

        raw_description = item.get("description")

        description = "" if raw_description is None else str(raw_description).strip()

        if not hypothesis_id or not description:
            raise ValueError(f"hypothesis {index} is missing id or description")

        evidence_raw = item.get(
            "evidence",
            [],
        )

        if not isinstance(
            evidence_raw,
            Sequence,
        ) or isinstance(
            evidence_raw,
            (str, bytes, bytearray),
        ):
            raise ValueError(f"hypothesis {index} evidence must be an array")

        evidence = [str(value) for value in evidence_raw]

        raw_status = str(
            item.get(
                "status",
                fallback_status,
            )
        ).strip()

        status: HypothesisStatus = (
            cast(
                HypothesisStatus,
                raw_status,
            )
            if raw_status
            in {
                "proposed",
                "confirmed",
                "rejected",
            }
            else fallback_status
        )

        hypotheses.append(
            Hypothesis(
                id=hypothesis_id,
                description=description,
                confidence=as_confidence(
                    item.get(
                        "confidence",
                        0.0,
                    )
                ),
                evidence=evidence,
                status=status,
            )
        )

    if not hypotheses:
        raise ValueError("LLM returned no hypotheses")

    return hypotheses


def tool_name(tool: Any) -> str | None:
    """Extract a registry tool name."""
    value = _mapping_value(
        tool,
        "name",
    )

    if value is None:
        return None

    name = str(value).strip()

    return name or None


def tool_description(tool: Any) -> str:
    """Extract a registry tool description."""
    value = _mapping_value(
        tool,
        "description",
        "",
    )

    return str(value or "").strip()


def tool_declared_risk_tier(
    tool: Any,
) -> int | None:
    """Extract an optional registry-provided integer risk tier."""
    raw = _mapping_value(
        tool,
        "risk_tier",
    )

    if raw is None or isinstance(
        raw,
        bool,
    ):
        return None

    if isinstance(raw, int):
        return raw if raw >= 0 else None

    if isinstance(raw, float) and raw.is_integer() and raw >= 0:
        return int(raw)

    return None


async def list_tool_specs(
    registry: ToolRegistry,
) -> list[dict[str, Any]]:
    """Return deterministic JSON-safe tool metadata including input schemas."""
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

        to_openai_schema = getattr(
            tool,
            "to_openai_schema",
            None,
        )

        try:
            if callable(to_openai_schema):
                openai_schema = to_openai_schema()

                if isinstance(
                    openai_schema,
                    Mapping,
                ):
                    function = openai_schema.get(
                        "function",
                        {},
                    )

                    if isinstance(
                        function,
                        Mapping,
                    ):
                        parameters = function.get(
                            "parameters",
                            {},
                        )

                        if isinstance(
                            parameters,
                            Mapping,
                        ):
                            input_schema = dict(parameters)

        except Exception:  # noqa: BLE001
            input_schema = {}

        if not input_schema:
            try:
                input_model = getattr(
                    tool,
                    "input_model",
                    None,
                )

                model_json_schema = getattr(
                    input_model,
                    "model_json_schema",
                    None,
                )

                if callable(model_json_schema):
                    generated = model_json_schema()

                    if isinstance(
                        generated,
                        Mapping,
                    ):
                        input_schema = dict(generated)

            except Exception:  # noqa: BLE001
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
    """Find a tool spec by exact name."""
    for spec in specs:
        if spec.get("name") == name:
            return spec

    return None


def safe_json(
    value: Any,
    *,
    max_chars: int = 4000,
) -> str:
    """Serialize tool output into bounded evidence text."""
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


def _confidence_value(
    hypothesis: Mapping[str, Any],
) -> float:
    try:
        return as_confidence(
            hypothesis.get(
                "confidence",
                0.0,
            )
        )
    except ValueError:
        return 0.0


def top_hypothesis(
    hypotheses: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any] | None:
    """Return the highest-confidence hypothesis."""
    if not hypotheses:
        return None

    return max(
        hypotheses,
        key=_confidence_value,
    )


def is_high_confidence(
    hypotheses: Sequence[Mapping[str, Any]],
) -> bool:
    """Return whether any hypothesis reached the proposal threshold."""
    return any(_confidence_value(hypothesis) >= 0.8 for hypothesis in hypotheses)


def approval_value_to_bool(
    value: Any,
) -> bool:
    """Normalize simple and structured approval responses."""
    if isinstance(value, bool):
        return value

    if isinstance(value, Mapping):
        if "approved" in value:
            approved_value = value["approved"]

            if isinstance(
                approved_value,
                bool,
            ):
                return approved_value

            return str(approved_value).strip().lower() in {
                "yes",
                "approve",
                "approved",
                "true",
            }

        decisions = value.get("decisions")

        if (
            isinstance(
                decisions,
                Sequence,
            )
            and not isinstance(
                decisions,
                (str, bytes, bytearray),
            )
            and decisions
        ):
            first = decisions[0]

            if isinstance(
                first,
                Mapping,
            ):
                decision_type = (
                    str(
                        first.get(
                            "type",
                            "",
                        )
                    )
                    .strip()
                    .lower()
                )

                return decision_type == "approve"

        return False

    return str(value).strip().lower() in {
        "yes",
        "approve",
        "approved",
        "true",
    }
