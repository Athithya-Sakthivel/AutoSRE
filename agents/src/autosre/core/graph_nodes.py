"""LangGraph node implementations for the AutoSRE investigation graph.

Each node is a pure function that receives ``AgentState`` and returns a
partial state dict to merge. All infrastructure dependencies (LLM router,
tool registry, safe executor, policy engine) are injected via
``config['configurable']['graph_context']``.

## Behaviour thresholds

All confidence thresholds and iteration limits are read from
``GraphContext`` fields at runtime. These are populated from
``settings.safety.*`` by the lifespan function in ``api/main.py`` and
are configurable via ``AUTOSRE_SAFETY__*`` environment variables.

Graph nodes must never reference module-level constants for thresholds.
If a threshold needs to change, it changes in ``config.py``.

## Stale constants removed

The following module-level constants were removed from ``state.py`` and
replaced with ``SafetyConfig`` fields:

    INITIAL_ITERATION_BUDGET   -> graph_context.initial_iteration_budget
    STAGNATION_LIMIT           -> graph_context.stagnation_limit
    MAX_ACTION_ATTEMPTS        -> graph_context.max_action_attempts
    MIN_CONFIDENCE_FOR_ACTION  -> graph_context.confidence_propose
    HIGH_CONFIDENCE_THRESHOLD  -> graph_context.confidence_fast_path
    MIN_CONFIDENCE_IMPROVEMENT -> graph_context.min_confidence_improvement
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Mapping
from typing import Any

from langchain_core.runnables import RunnableConfig

from autosre.config import LLMConfig
from autosre.core.graph_helpers import (
    MUTATING_TOOLS,
    PHASE_APPROVE,
    PHASE_COMPLETE,
    PHASE_EXECUTE,
    PHASE_HYPOTHESIZE,
    PHASE_INVESTIGATE,
    PHASE_PROPOSE,
    PHASE_TRIAGE,
    PHASE_VERIFY,
    PHASES,
    count_action_attempts,
    get_graph_context,
    is_action_already_executed,
    maybe_await,
    parse_json_response,
    safe_json,
    top_hypothesis,
)
from autosre.core.router import LLMBudgetExhaustedError
from autosre.core.state import (
    AgentState,
    ProposedAction,
    RunMetrics,
    SREContext,
)
from autosre.safety.policy import RiskTier

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# JSON response format hint
# ---------------------------------------------------------------------------

_JSON_FORMAT = {"type": "json_object"}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _llm_config(graph_context: Any) -> LLMConfig | None:
    """Extract LLMConfig from graph context, tolerating test doubles."""
    config = getattr(graph_context, "llm_config", None)
    if isinstance(config, LLMConfig):
        return config
    return None


def _get_run_metrics(config: RunnableConfig) -> RunMetrics | None:
    """Extract RunMetrics from RunnableConfig, returning None if absent."""
    if not isinstance(config, Mapping):
        return None
    configurable = config.get("configurable")
    if not isinstance(configurable, Mapping):
        return None
    metrics = configurable.get("run_metrics")
    if isinstance(metrics, RunMetrics):
        return metrics
    return None


def _get_sre_context(config: RunnableConfig) -> SREContext | None:
    """Extract SREContext from RunnableConfig, returning None if absent."""
    if not isinstance(config, Mapping):
        return None
    configurable = config.get("configurable")
    if not isinstance(configurable, Mapping):
        return None
    ctx = configurable.get("sre_context")
    if isinstance(ctx, SREContext):
        return ctx
    return None


def _incident_metadata(state: AgentState) -> dict[str, Any]:
    """Extract incident metadata from state, returning empty dict if absent."""
    metadata = state.get("incident_metadata")
    if isinstance(metadata, dict):
        return metadata
    return {}


def _coerce_dict_list(value: Any) -> list[dict[str, Any]]:
    """Coerce a value to a list of dicts. Returns empty list on failure."""
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _coerce_tool_name(value: Any) -> str | None:
    """Coerce a tool name to a non-empty string, or None."""
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped if stripped else None


def _clamp_namespace(
    tool_args: dict[str, Any],
    incident_ns: str | None,
) -> dict[str, Any]:
    """Ensure tool_args contains the incident namespace if applicable."""
    if incident_ns is None:
        return tool_args

    # If the tool doesn't take a namespace, don't inject one.
    if "namespace" not in tool_args:
        return tool_args

    # If namespace is empty or None, clamp to incident namespace.
    current_ns = tool_args.get("namespace")
    if not current_ns:
        return {**tool_args, "namespace": incident_ns}

    return tool_args


def _build_proposed_action(
    *,
    tool_name: str,
    tool_args: dict[str, Any],
    risk_tier: int,
    rationale: str,
    requires_approval: bool,
) -> dict[str, Any]:
    """Build a proposed action dict matching the ProposedAction schema."""
    return {
        "tool_name": tool_name,
        "tool_args": tool_args,
        "risk_tier": risk_tier,
        "rationale": rationale,
        "requires_approval": requires_approval,
    }


def _accumulate_usage(
    state: AgentState,
    response: Any,
    llm_config: LLMConfig | None,
) -> dict[str, Any]:
    """Accumulate token usage and cost from an LLM response.

    Handles both OpenAI-style response objects and mapping responses.
    Falls back to direct attribute extraction if calculate_cost fails.
    """
    from autosre.core.cost import calculate_cost

    # Extract usage from response object or mapping
    usage = getattr(response, "usage", None)
    if usage is None and isinstance(response, Mapping):
        usage = response.get("usage")

    if usage is None:
        return {}

    # Extract model name
    model_name = getattr(response, "model", None)
    if model_name is None and isinstance(response, Mapping):
        model_name = response.get("model", "")

    # Try calculate_cost first, fall back to direct extraction
    try:
        prompt_tokens, completion_tokens, _cached_tokens, cost = calculate_cost(
            usage, model_name or "", llm_config
        )
    except Exception as exc:
        logger.warning("calculate_cost failed, using direct extraction: %s", exc)
        # Direct extraction fallback
        prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0
        completion_tokens = getattr(usage, "completion_tokens", 0) or 0

        # Handle dict-style usage
        if isinstance(usage, Mapping):
            prompt_tokens = usage.get("prompt_tokens", 0) or 0
            completion_tokens = usage.get("completion_tokens", 0) or 0

        cost = 0.0

    # Get current accumulated values
    current_tokens = int(state.get("tokens_used", 0) or 0)
    current_cost = float(state.get("cost_usd", 0.0) or 0.0)

    # Return partial state update
    return {
        "tokens_used": current_tokens + int(prompt_tokens) + int(completion_tokens),
        "cost_usd": current_cost + float(cost),
    }


def _normalize_hypotheses_safe(
    raw: Any,
    fallback: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Normalize hypotheses from LLM output, falling back on any error."""
    from autosre.core.graph_helpers import normalize_hypotheses

    if not isinstance(raw, list):
        return fallback

    try:
        validated = normalize_hypotheses(raw, default_status="proposed")
    except ValueError, TypeError:
        return fallback

    return [
        {
            "id": h.id,
            "description": h.description,
            "confidence": h.confidence,
            "evidence": h.evidence,
            "status": h.status,
        }
        for h in validated
    ]


# ---------------------------------------------------------------------------
# Node: triage
# ---------------------------------------------------------------------------


async def triage_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Generate 2-3 initial hypotheses from alert metadata."""
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    # Read iteration budget from graph_context (configurable via env var)
    initial_iteration_budget = graph_context.initial_iteration_budget

    metadata = _incident_metadata(state)
    alert_name = str(metadata.get("alert_name", ""))
    service = str(metadata.get("service", ""))
    namespace = str(metadata.get("namespace", ""))
    severity = str(metadata.get("severity", ""))
    description = str(metadata.get("description", ""))
    labels = metadata.get("labels", {}) or {}
    annotations = metadata.get("annotations", {}) or {}

    prompt = f"""You are an SRE agent investigating a Kubernetes alert.
Generate 2-3 plausible root-cause hypotheses based ONLY on the alert metadata.

Return a JSON object with a single top-level key "hypotheses". Each element
must match this schema exactly:
{{
  "id": "H1",
  "description": "...",
  "confidence": 0.3,
  "evidence": [],
  "status": "proposed"
}}

Rules:
- Output valid JSON only. No prose, no markdown fences.
- Do NOT invent evidence. Evidence must come from tool outputs only.
- Do NOT reference specific PIDs, pod names, or metrics you have not observed.
- If alert metadata is insufficient, return 2-3 hypotheses with confidence 0.2.

Alert metadata:
- Alert: {alert_name}
- Service: {service} in namespace {namespace}
- Severity: {severity}
- Description: {description}
- Labels: {json.dumps(labels)}
- Annotations: {json.dumps(annotations)}"""

    messages = [
        {"role": "system", "content": prompt},
        {"role": "user", "content": "Generate hypotheses."},
    ]

    fallback: list[dict[str, Any]] = [
        {
            "id": "H1",
            "description": f"Investigate {alert_name} on {service}",
            "confidence": 0.2,
            "evidence": [],
            "status": "proposed",
        }
    ]

    try:
        response = await llm_router.acompletion(
            messages=messages,
            response_format=_JSON_FORMAT,
            run_metrics=run_metrics,
        )
        parsed = parse_json_response(response, stage="triage", allow_array=True)

        raw_hypotheses = parsed.get("hypotheses") or parsed.get("items") or fallback

        hypotheses = _normalize_hypotheses_safe(raw_hypotheses, fallback)

        return {
            "hypotheses": hypotheses,
            "current_phase": PHASE_INVESTIGATE,
            "iteration_budget": initial_iteration_budget,
            "iteration_count": 0,
            "last_top_confidence": 0.0,
            "stagnation_count": 0,
            "action_attempts": 0,
            **_accumulate_usage(state, response, llm_config),
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during triage")
        return {
            "hypotheses": fallback,
            "current_phase": PHASE_COMPLETE,
            "status": "no_action",
        }

    except Exception as exc:
        logger.error("Triage node failed: %s", exc, exc_info=True)
        return {
            "hypotheses": fallback,
            "current_phase": PHASE_INVESTIGATE,
        }


# ---------------------------------------------------------------------------
# Node: investigate
# ---------------------------------------------------------------------------


async def investigate_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Select and execute investigation tools to gather evidence."""
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    registry = graph_context.registry
    sre_context = _get_sre_context(config)
    run_metrics = _get_run_metrics(config)

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    iteration_budget = int(state.get("iteration_budget", 0) or 0)
    iteration_count = int(state.get("iteration_count", 0) or 0)
    metadata = _incident_metadata(state)

    # Decrement budget
    new_budget = max(0, iteration_budget - 1)

    # Get available read-only tools
    all_tools = await maybe_await(registry.list_tools())
    read_only_tools = [
        tool for tool in (all_tools or []) if int(getattr(tool, "risk_tier", 0)) == 0
    ]

    if not read_only_tools:
        logger.warning("No read-only tools available for investigation")
        return {
            "iteration_budget": new_budget,
            "iteration_count": iteration_count + 1,
            "current_phase": PHASE_HYPOTHESIZE,
        }

    tool_schemas = [
        {
            "name": getattr(tool, "name", ""),
            "description": getattr(tool, "description", ""),
            "parameters": tool.input_model.model_json_schema()
            if hasattr(tool, "input_model")
            else {},
        }
        for tool in read_only_tools
    ]

    prompt = f"""You are an SRE agent investigating an incident. Select the
most relevant investigation tools to gather evidence.

Available tools (all read-only, Tier 0):
{json.dumps(tool_schemas, indent=2)}

Current hypotheses:
{json.dumps(hypotheses, indent=2)}

Rules:
- Select 1-3 tools that will best help confirm or reject the top hypothesis.
- Return a JSON object with a "tools" array containing tool calls.
- Each tool call must have "name" and "args" fields.
- Do NOT call tools that were already called with the same arguments.

Return:
{{
  "tools": [
    {{"name": "tool_name", "args": {{...}}}}
  ]
}}"""

    messages = [
        {"role": "system", "content": prompt},
        {"role": "user", "content": "Select investigation tools."},
    ]

    try:
        response = await llm_router.acompletion(
            messages=messages,
            response_format=_JSON_FORMAT,
            run_metrics=run_metrics,
        )
        parsed = parse_json_response(response, stage="investigate")

        tool_calls = parsed.get("tools", [])
        if not isinstance(tool_calls, list):
            tool_calls = []

        usage_update = _accumulate_usage(state, response, llm_config)

        # Execute selected tools
        executed_tool_results: list[str] = []

        for call in tool_calls[:3]:  # Cap at 3 tool calls per iteration
            if not isinstance(call, dict):
                continue

            tool_name_str = call.get("name", "")
            tool_args = call.get("args", {})
            if not isinstance(tool_args, dict):
                tool_args = {}

            # Clamp namespace
            incident_ns = str(metadata.get("namespace", "")) if metadata.get("namespace") else None
            tool_args = _clamp_namespace(tool_args, incident_ns)

            # SREContext is required for tool execution
            if sre_context is None:
                executed_tool_results.append(
                    f"Tool {tool_name_str}({json.dumps(tool_args)}) "
                    f"status=failed error=no SREContext"
                )
                continue

            try:
                result = await maybe_await(
                    registry.execute(tool_name_str, tool_args, context=sre_context)
                )
                result_text = safe_json(result, max_chars=2000)
                executed_tool_results.append(
                    f"Tool {tool_name_str}({json.dumps(tool_args)}) "
                    f"status=succeeded output={result_text}"
                )
            except Exception as exc:
                logger.warning("Tool %s failed: %s", tool_name_str, exc)
                executed_tool_results.append(
                    f"Tool {tool_name_str}({json.dumps(tool_args)}) status=failed error={exc}"
                )

        # Append evidence to hypotheses
        updated_hypotheses = []
        for h in hypotheses:
            h_copy = dict(h)
            evidence = list(h_copy.get("evidence", []))
            evidence.extend(executed_tool_results)
            h_copy["evidence"] = evidence
            updated_hypotheses.append(h_copy)

        return {
            "hypotheses": updated_hypotheses,
            "iteration_budget": new_budget,
            "iteration_count": iteration_count + 1,
            "current_phase": PHASE_HYPOTHESIZE,
            **usage_update,
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during investigation")
        return {
            "iteration_budget": new_budget,
            "iteration_count": iteration_count + 1,
            "current_phase": PHASE_HYPOTHESIZE,
        }

    except Exception as exc:
        logger.error("Investigate node failed: %s", exc, exc_info=True)
        return {
            "iteration_budget": new_budget,
            "iteration_count": iteration_count + 1,
            "current_phase": PHASE_HYPOTHESIZE,
        }


# ---------------------------------------------------------------------------
# Node: hypothesize
# ---------------------------------------------------------------------------


async def hypothesize_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Refine hypothesis confidence and decide the next phase.

    Decision tree, evaluated in order:

        1. No hypotheses       -> complete / failed
        2. Confidence high     -> propose (fast path)
        3. Budget exhausted    -> propose if confidence >= propose threshold,
                                  else complete / no_action
        4. Stagnation limit    -> propose if confidence >= propose threshold,
                                  else complete / no_action
        5. Otherwise           -> investigate

    All thresholds are read from graph_context (configurable via env vars).
    """
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    # Read configurable thresholds from graph_context
    stagnation_limit = graph_context.stagnation_limit
    confidence_fast_path = graph_context.confidence_fast_path
    confidence_propose = graph_context.confidence_propose
    min_confidence_improvement = graph_context.min_confidence_improvement

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    iteration_budget = int(state.get("iteration_budget", 0) or 0)
    last_confidence = float(state.get("last_top_confidence", 0.0) or 0.0)
    stagnation_count = int(state.get("stagnation_count", 0) or 0)

    if not hypotheses:
        logger.warning("No hypotheses to refine")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    best_before = top_hypothesis(hypotheses)
    current_confidence = float(best_before.get("confidence", 0.0) or 0.0) if best_before else 0.0

    # Step 2 — high confidence short-circuit (fast path).
    if current_confidence >= confidence_fast_path:
        logger.info(
            "Confidence %.2f >= fast-path threshold %.2f; proceeding to propose",
            current_confidence,
            confidence_fast_path,
        )
        return {
            "current_phase": PHASE_PROPOSE,
            "last_top_confidence": current_confidence,
        }

    # Step 3 — budget exhausted. Propose if actionable, else no_action.
    if iteration_budget <= 0:
        if current_confidence >= confidence_propose:
            logger.info(
                "Budget exhausted at confidence %.2f >= %.2f; proceeding to propose",
                current_confidence,
                confidence_propose,
            )
            return {
                "current_phase": PHASE_PROPOSE,
                "last_top_confidence": current_confidence,
            }

        logger.info(
            "Budget exhausted at confidence %.2f < %.2f; completing with no_action",
            current_confidence,
            confidence_propose,
        )
        return {
            "current_phase": PHASE_COMPLETE,
            "last_top_confidence": current_confidence,
            "status": "no_action",
        }

    prompt = f"""You are an SRE agent refining hypothesis confidence based on evidence.

Rules:
- Return valid JSON only. No prose, no markdown fences.
- Return a JSON object with a single top-level key "hypotheses".
- Use the SAME hypothesis IDs that were provided. Do not add, remove, or rename.
- Only adjust the `confidence` and `status` fields. Do not modify `description` or `evidence`.
- Increase confidence ONLY when evidence directly supports the hypothesis.
- Decrease confidence ONLY when evidence directly contradicts.
- If evidence is ambiguous, leave confidence unchanged.
- Use these calibration anchors:
    0.2-0.4 = weak/no evidence
    0.5-0.6 = some supporting evidence
    0.7-0.8 = strong supporting evidence
    0.9+    = confirmed with direct evidence

Current hypotheses:
{json.dumps(hypotheses, indent=2)}"""

    messages = [
        {"role": "system", "content": prompt},
        {"role": "user", "content": "Refine hypotheses."},
    ]

    try:
        response = await llm_router.acompletion(
            messages=messages,
            run_metrics=run_metrics,
        )
        parsed = parse_json_response(response, stage="hypothesize", allow_array=True)

        refined_raw = parsed.get("hypotheses") or parsed.get("items") or hypotheses

        refined_dicts = _coerce_dict_list(refined_raw)

        original_ids = {h.get("id") for h in hypotheses if isinstance(h.get("id"), str)}
        refined = [h for h in refined_dicts if h.get("id") in original_ids]
        if not refined:
            refined = list(hypotheses)

        best_after = top_hypothesis(refined)
        new_confidence = float(best_after.get("confidence", 0.0) or 0.0) if best_after else 0.0

        # Compute stagnation using configurable improvement threshold (ternary for SIM108)
        improvement = new_confidence - last_confidence
        new_stagnation = 0 if improvement >= min_confidence_improvement else stagnation_count + 1

        usage_update = _accumulate_usage(state, response, llm_config)

        logger.info(
            "Hypothesis refinement: confidence %.2f -> %.2f (delta=%.2f, stagnation=%d/%d)",
            last_confidence,
            new_confidence,
            improvement,
            new_stagnation,
            stagnation_limit,
        )

        # Post-refinement fast path
        if new_confidence >= confidence_fast_path:
            return {
                "hypotheses": refined,
                "current_phase": PHASE_PROPOSE,
                "last_top_confidence": new_confidence,
                "stagnation_count": new_stagnation,
                **usage_update,
            }

        # Post-refinement stagnation check
        if new_stagnation >= stagnation_limit:
            if new_confidence >= confidence_propose:
                logger.info(
                    "Stagnation limit reached but confidence %.2f >= %.2f; proceeding to propose",
                    new_confidence,
                    confidence_propose,
                )
                return {
                    "hypotheses": refined,
                    "current_phase": PHASE_PROPOSE,
                    "last_top_confidence": new_confidence,
                    "stagnation_count": new_stagnation,
                    **usage_update,
                }

            logger.info(
                "Stagnation limit reached at confidence %.2f < %.2f; completing with no_action",
                new_confidence,
                confidence_propose,
            )
            return {
                "hypotheses": refined,
                "current_phase": PHASE_COMPLETE,
                "last_top_confidence": new_confidence,
                "stagnation_count": new_stagnation,
                "status": "no_action",
                **usage_update,
            }

        return {
            "hypotheses": refined,
            "current_phase": PHASE_INVESTIGATE,
            "last_top_confidence": new_confidence,
            "stagnation_count": new_stagnation,
            **usage_update,
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during hypothesis refinement")
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    except Exception as exc:
        logger.error("Hypothesize node failed: %s", exc, exc_info=True)
        return {
            "hypotheses": hypotheses,
            "current_phase": PHASE_PROPOSE,
            "last_top_confidence": current_confidence,
        }


# ---------------------------------------------------------------------------
# Node: propose
# ---------------------------------------------------------------------------


async def propose_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Select a remediation action based on the top hypothesis."""
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    # Read configurable thresholds from graph_context
    max_action_attempts = graph_context.max_action_attempts
    confidence_propose = graph_context.confidence_propose

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)
    incident_ns_raw = _incident_metadata(state).get("namespace")
    incident_ns = str(incident_ns_raw) if isinstance(incident_ns_raw, str) else None

    if action_attempts >= max_action_attempts:
        logger.info(
            "Action attempt cap reached (%d/%d); completing with failed",
            action_attempts,
            max_action_attempts,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    if not hypotheses:
        logger.info("No hypotheses; completing with no_action")
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    best = top_hypothesis(hypotheses)
    confidence = float(best.get("confidence", 0.0) or 0.0) if best else 0.0
    if confidence < confidence_propose:
        logger.info(
            "Top hypothesis confidence %.2f < %.2f; completing with no_action",
            confidence,
            confidence_propose,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    registry = graph_context.registry

    eligible_tools = [
        tool
        for tool in (await maybe_await(registry.list_tools()) or [])
        if int(getattr(tool, "risk_tier", 0))
        in (int(RiskTier.REVERSIBLE_LOW), int(RiskTier.REVERSIBLE_HIGH))
    ]

    tool_schemas: list[dict[str, Any]] = [
        {
            "name": getattr(tool, "name", ""),
            "description": getattr(tool, "description", ""),
            "parameters": tool.input_model.model_json_schema()
            if hasattr(tool, "input_model")
            else {},
            "risk_tier": int(getattr(tool, "risk_tier", 0)),
        }
        for tool in eligible_tools
    ]

    error_feedback = ""
    if executed_actions:
        last_action = executed_actions[-1]
        if not last_action.get("success"):
            result_dict = last_action.get("result")
            error_msg = (
                result_dict.get("error") if isinstance(result_dict, dict) else None
            ) or "Unknown error"
            error_feedback = f"""
Previous action did not succeed:
  Tool: {last_action.get("tool_name")}
  Args: {json.dumps(last_action.get("tool_args", {}), default=str)}
  Error: {error_msg}

If you propose the same tool again, FIX the tool_args to match the schema.
If the same tool cannot succeed, choose a DIFFERENT tool or return "none".
"""

    executed_context = json.dumps(executed_actions, indent=2, default=str)

    namespace_hint = (
        f"The incident is in namespace '{incident_ns}'. Always pass "
        f"namespace='{incident_ns}' in tool_args."
        if incident_ns
        else ""
    )

    prompt = f"""You are an SRE agent proposing a remediation action.

{namespace_hint}

Available remediation tools (Tier 1 = reversible, Tier 2 = requires approval):
{json.dumps(tool_schemas, indent=2)}

Risk tiers:
- Tier 1: Reversible (restart, terminate_backend, delete_key, delete_pod)
- Tier 2: Requires approval (scale_deployment)

Top hypothesis:
{json.dumps(best, indent=2)}

Rules:
- Output valid JSON only. No prose, no markdown fences.
- Do NOT propose a tool that was already executed this incident.
- Do NOT propose Tier 0 (read-only) tools as remediation.
- Prefer the most targeted action.
- If no remediation tool applies, return tool_name="none".

{error_feedback}

Return a JSON object:
{{
  "tool_name": "...",
  "tool_args": {{...}},
  "risk_tier": 1,
  "rationale": "..."
}}

Executed actions (DO NOT REPEAT THESE):
{executed_context}"""

    messages = [
        {"role": "system", "content": prompt},
        {"role": "user", "content": "Propose remediation action."},
    ]

    try:
        response = await llm_router.coordinator_call(
            messages=messages,
            response_format=_JSON_FORMAT,
            run_metrics=run_metrics,
        )
        parsed = parse_json_response(response, stage="propose")

        tool_name_str = _coerce_tool_name(parsed.get("tool_name"))
        tool_args_raw = parsed.get("tool_args")
        tool_args: dict[str, Any] = dict(tool_args_raw) if isinstance(tool_args_raw, dict) else {}
        rationale = str(parsed.get("rationale", ""))

        risk_tier_raw = parsed.get("risk_tier", 1)
        try:
            risk_tier = int(risk_tier_raw)
        except TypeError, ValueError:
            risk_tier = 1

        usage_update = _accumulate_usage(state, response, llm_config)

        if tool_name_str is None or tool_name_str == "none":
            logger.info("Agent proposed no action; completing with no_action")
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "no_action",
                **usage_update,
            }

        if is_action_already_executed(tool_name_str, tool_args, executed_actions):
            logger.warning(
                "Duplicate action rejected: %s (already executed)",
                tool_name_str,
            )
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "no_action",
                **usage_update,
            }

        attempts = count_action_attempts(tool_name_str, executed_actions)
        if attempts >= 2 and tool_name_str in MUTATING_TOOLS:
            logger.warning(
                "Tool %s already attempted %d times; completing with failed",
                tool_name_str,
                attempts,
            )
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "failed",
                **usage_update,
            }

        tool_args = _clamp_namespace(tool_args, incident_ns)

        proposed = _build_proposed_action(
            tool_name=tool_name_str,
            tool_args=tool_args,
            risk_tier=risk_tier,
            rationale=rationale,
            requires_approval=risk_tier >= 2,
        )

        return {
            "proposed_actions": [proposed],
            "requires_human_approval": risk_tier >= 2,
            "current_phase": PHASE_APPROVE if risk_tier >= 2 else PHASE_EXECUTE,
            **usage_update,
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during propose")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    except Exception as exc:
        logger.error("Propose node failed: %s", exc, exc_info=True)
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}


# ---------------------------------------------------------------------------
# Node: approve
# ---------------------------------------------------------------------------


async def approve_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Wait for human approval on Tier-2+ actions.

    This node is an interrupt point. LangGraph pauses execution here and
    waits for an external approval signal. When resumed, the approval
    decision is read from state and the graph continues.
    """
    requires_approval = bool(state.get("requires_human_approval", False))
    approval_granted = state.get("approval_granted")

    if not requires_approval:
        return {"current_phase": PHASE_EXECUTE}

    if approval_granted is None:
        # Still waiting for approval — graph will pause here
        logger.info("Awaiting human approval for Tier-2+ action")
        return {}

    if approval_granted:
        logger.info("Approval granted; proceeding to execute")
        return {"current_phase": PHASE_EXECUTE}
    else:
        logger.info("Approval denied; completing with no_action")
        return {
            "current_phase": PHASE_COMPLETE,
            "status": "no_action",
        }


# ---------------------------------------------------------------------------
# Node: execute
# ---------------------------------------------------------------------------


async def execute_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Execute the proposed action through the SafeExecutor."""
    graph_context = get_graph_context(config)
    executor = graph_context.executor
    sre_context = _get_sre_context(config)

    # Read configurable threshold from graph_context
    max_action_attempts = graph_context.max_action_attempts

    proposed_actions = _coerce_dict_list(state.get("proposed_actions"))
    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)

    if not proposed_actions:
        logger.warning("No proposed actions to execute")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    if action_attempts >= max_action_attempts:
        logger.warning(
            "Action attempt cap already reached (%d/%d) before dispatch",
            action_attempts,
            max_action_attempts,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    # SREContext is required for execution
    if sre_context is None:
        logger.error("Cannot execute action: no SREContext available")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    proposed = proposed_actions[0]
    tool_name_str = proposed.get("tool_name", "")
    tool_args = proposed.get("tool_args", {})
    if not isinstance(tool_args, dict):
        tool_args = {}

    proposed_action = ProposedAction(
        tool_name=tool_name_str,
        tool_args=tool_args,
        risk_tier=int(proposed.get("risk_tier", 1)),
        rationale=str(proposed.get("rationale", "")),
        requires_approval=bool(proposed.get("requires_approval", False)),
    )

    try:
        result = await executor.execute(proposed_action, sre_context)

        executed_action: dict[str, Any] = {
            "tool_name": tool_name_str,
            "tool_args": tool_args,
            "tool_call_id": f"call_{int(time.time() * 1000)}",
            "result": result.output if isinstance(result.output, dict) else {},
            "success": result.executed and result.error is None,
            "executed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            # ExecutionResult.verified is bool | None; map to verification_passed
            "verification_passed": result.verified,
        }

        new_executed = executed_actions + [executed_action]
        new_attempts = action_attempts + 1

        if result.executed and result.error is None:
            return {
                "executed_actions": new_executed,
                "action_attempts": new_attempts,
                "proposed_actions": [],
                "current_phase": PHASE_VERIFY,
            }
        else:
            logger.warning(
                "Action execution failed: %s",
                result.error or "unknown error",
            )
            return {
                "executed_actions": new_executed,
                "action_attempts": new_attempts,
                "proposed_actions": [],
                "current_phase": PHASE_PROPOSE,
            }

    except Exception as exc:
        logger.error("Execute node failed: %s", exc, exc_info=True)
        return {
            "action_attempts": action_attempts + 1,
            "current_phase": PHASE_PROPOSE,
        }


# ---------------------------------------------------------------------------
# Node: verify
# ---------------------------------------------------------------------------


async def verify_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Verify the executed action succeeded and decide next phase."""
    graph_context = get_graph_context(config)

    # Read configurable threshold from graph_context
    max_action_attempts = graph_context.max_action_attempts

    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)

    if not executed_actions:
        logger.warning("No executed actions to verify")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    last_action = executed_actions[-1]
    verification_passed = last_action.get("verification_passed")

    # If verification explicitly passed, resolve
    if verification_passed is True:
        logger.info("Action verified successfully; completing with resolved")
        return {"current_phase": PHASE_COMPLETE, "status": "resolved"}

    # If verification explicitly failed, check attempt budget
    if verification_passed is False:
        if action_attempts >= max_action_attempts:
            logger.warning(
                "Max action attempts (%d) reached; completing with failed",
                max_action_attempts,
            )
            return {"current_phase": PHASE_COMPLETE, "status": "failed"}

        logger.warning(
            "Action not verified (attempt %d/%d); re-proposing",
            action_attempts,
            max_action_attempts,
        )
        return {"current_phase": PHASE_PROPOSE}

    # If verification is None (not performed), check if action succeeded
    success = last_action.get("success", False)
    if success:
        logger.info("Action succeeded (no explicit verification); resolving")
        return {"current_phase": PHASE_COMPLETE, "status": "resolved"}

    # Action failed and no verification
    if action_attempts >= max_action_attempts:
        logger.warning(
            "Max action attempts (%d) reached; completing with failed",
            max_action_attempts,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    logger.warning(
        "Action not verified (attempt %d/%d); re-proposing",
        action_attempts,
        max_action_attempts,
    )
    return {"current_phase": PHASE_PROPOSE}


# ---------------------------------------------------------------------------
# Node: complete
# ---------------------------------------------------------------------------


def complete_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Compute final metrics and set terminal status."""
    started_at = float(state.get("started_at", 0.0) or 0.0)
    wall_clock = time.time() - started_at if started_at > 0 else 0.0

    run_metrics = _get_run_metrics(config)
    backoff = run_metrics.backoff_seconds if run_metrics is not None else 0.0
    active = max(0.0, wall_clock - backoff)

    current_status = str(state.get("status", "running"))

    # If status is already terminal, preserve it
    if current_status in ("resolved", "failed", "no_action", "blocked"):
        final_status = current_status
    else:
        # Default to no_action if not explicitly set
        final_status = "no_action"

    return {
        "current_phase": PHASE_COMPLETE,
        "status": final_status,
        "wall_clock_seconds": round(wall_clock, 3),
        "backoff_seconds": round(backoff, 3),
        "active_seconds": round(active, 3),
    }


# ---------------------------------------------------------------------------
# Routing functions
# ---------------------------------------------------------------------------


def route_initial_phase(state: AgentState) -> str:
    """Route from __start__ to the initial phase."""
    phase = state.get("current_phase", PHASE_TRIAGE)
    if phase in PHASES:
        return str(phase)
    return PHASE_TRIAGE


def route_after_hypothesize(state: AgentState) -> str:
    """Route after hypothesize to investigate, propose, or complete."""
    phase = state.get("current_phase", PHASE_INVESTIGATE)
    if phase == PHASE_PROPOSE:
        return PHASE_PROPOSE
    if phase == PHASE_COMPLETE:
        return PHASE_COMPLETE
    return PHASE_INVESTIGATE


def route_after_execute(state: AgentState) -> str:
    """Route after execute to verify or propose."""
    phase = state.get("current_phase", PHASE_VERIFY)
    if phase == PHASE_VERIFY:
        return PHASE_VERIFY
    return PHASE_PROPOSE


def route_after_approval(state: AgentState) -> str:
    """Route after approve to execute or complete."""
    phase = state.get("current_phase", PHASE_EXECUTE)
    if phase == PHASE_EXECUTE:
        return PHASE_EXECUTE
    return PHASE_COMPLETE


def route_after_propose(state: AgentState) -> str:
    """Route after propose to approve, execute, or complete."""
    phase = state.get("current_phase", PHASE_APPROVE)
    if phase == PHASE_APPROVE:
        return PHASE_APPROVE
    if phase == PHASE_EXECUTE:
        return PHASE_EXECUTE
    return PHASE_COMPLETE


def route_after_verify(state: AgentState) -> str:
    """Route after verify to complete or propose."""
    phase = state.get("current_phase", PHASE_COMPLETE)
    if phase == PHASE_COMPLETE:
        return PHASE_COMPLETE
    if phase == PHASE_PROPOSE:
        return PHASE_PROPOSE
    return PHASE_COMPLETE


__all__ = [
    "triage_node",
    "investigate_node",
    "hypothesize_node",
    "propose_node",
    "approve_node",
    "execute_node",
    "verify_node",
    "complete_node",
    "route_initial_phase",
    "route_after_hypothesize",
    "route_after_execute",
    "route_after_approval",
    "route_after_propose",
    "route_after_verify",
]
