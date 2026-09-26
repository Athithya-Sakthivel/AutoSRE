"""LangGraph node implementations for the AutoSRE investigation workflow.

## Graph topology

    START -> triage -> investigate <-> hypothesize
                                 |
                                 v
                             propose ---> approve (Tier 2+, HITL)
                                 |               |
                                 |               v
                                 +-----------> execute -> verify
                                                       |
                                                       v
                                             propose (retry) | complete
                                                             |
                                                             v
                                                          END

## Node contract

    async def node(state: AgentState, config: RunnableConfig) -> dict[str, Any]

Returned dict is merged into state via LangGraph's input mapping. Keys not
declared on AgentState are silently dropped. Every node that reads
``config['configurable']['run_metrics']`` tolerates a missing key (tests)
and a present RunMetrics (production).

## Budget and progress contract

Three independent limits bound the investigation:

    iteration_budget     Rounds of investigate+hypothesize remaining.
                         Decremented by investigate_node on every entry.
                         At 0, hypothesize_node exits with no_action if
                         confidence is below MIN_CONFIDENCE_FOR_ACTION.

    stagnation_count     Consecutive hypothesize rounds without progress.
                         At STAGNATION_LIMIT, hypothesize_node exits with
                         status=no_action.

    action_attempts      Total remediation executions across retries.
                         Capped at MAX_ACTION_ATTEMPTS in execute_node and
                         checked in propose_node.

## Status semantics

    running       Investigation in progress.
    resolved      At least one executed action was verified successful.
    failed        Terminated on an error path.
    no_action     Declined to act. Low confidence, budget exhausted,
                  stagnation, duplicate action, or unknown tool.
    blocked       Policy rejected the only viable action.

## HITL contract (approve_node)

    LangGraph's interrupt() pauses execution and saves a checkpoint. On
    resume the graph replays this node from the top; interrupt() returns
    the resume payload instead of pausing. Nothing before interrupt() may
    have side effects.

    Resume is driven by ``LangGraphRunner.approve_incident`` via
    ``graph.ainvoke(Command(resume={"approved": ..., "comment": ...}))``.

## Response format

Groq's strict JSON validator rejects ``response_format={"type":"json_object"}``
when the prompt embeds heavily-escaped evidence strings. investigate_node
and hypothesize_node therefore omit response_format and rely on
parse_json_response's extraction cascade. triage_node and propose_node
keep it because their prompts are short and structured.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from langchain_core.runnables import RunnableConfig

from autosre.core.cost import calculate_cost
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
    count_action_attempts,
    find_tool,
    get_graph_context,
    is_action_already_executed,
    parse_json_response,
    top_hypothesis,
)
from autosre.core.router import LLMBudgetExhaustedError
from autosre.core.state import (
    HIGH_CONFIDENCE_THRESHOLD,
    MAX_ACTION_ATTEMPTS,
    MIN_CONFIDENCE_FOR_ACTION,
    MIN_CONFIDENCE_IMPROVEMENT,
    STAGNATION_LIMIT,
    AgentState,
    IncidentMetadata,
    ProposedAction,
    RunMetrics,
    SREContext,
)
from autosre.safety.executor import ExecutionResult
from autosre.safety.policy import RiskTier

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Private constants
# ---------------------------------------------------------------------------

# Groq-compatible response format. Only sent on nodes whose prompts do not
# embed heavily-escaped tool output.
_JSON_FORMAT = {"type": "json_object"}

# Namespace allowlist mirrors PolicyEngine's default. Kept local because
# this module does not import the policy engine.
_ALLOWED_NAMESPACES = frozenset({"rivulet", "sre"})


# ---------------------------------------------------------------------------
# Config extraction helpers
# ---------------------------------------------------------------------------


def _get_run_metrics(config: RunnableConfig) -> RunMetrics | None:
    """Return the per-incident RunMetrics, or None if not present (tests)."""
    configurable = config.get("configurable")
    if not isinstance(configurable, dict):
        return None
    metrics = configurable.get("run_metrics")
    return metrics if isinstance(metrics, RunMetrics) else None


def _require_sre_context(config: RunnableConfig) -> SREContext | None:
    """Return the SREContext, or None if absent or malformed."""
    configurable = config.get("configurable")
    if not isinstance(configurable, dict):
        return None
    ctx = configurable.get("sre_context")
    return ctx if isinstance(ctx, SREContext) else None


def _incident_metadata(state: AgentState) -> IncidentMetadata:
    """Return the incident metadata, defaulting to an empty dict.

    Never returns None. Callers use ``metadata.get(key, default)``.
    """
    md = state.get("incident_metadata")
    if isinstance(md, dict):
        return md
    return IncidentMetadata()


def _llm_config(graph_context: Any) -> Any:
    """Return the LLMConfig used for cost calculation, or None."""
    router = getattr(graph_context, "llm_router", None)
    return getattr(router, "config", None)


# ---------------------------------------------------------------------------
# Value normalization helpers
# ---------------------------------------------------------------------------


def _coerce_tool_name(raw: Any) -> str | None:
    """Return a stripped, non-empty tool name, or None."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    return text or None


def _clamp_namespace(
    tool_args: dict[str, Any],
    incident_ns: str | None,
) -> dict[str, Any]:
    """Force tool_args['namespace'] to the incident's namespace.

    Overrides hallucinated namespaces (service name, ``default``,
    ``production``) that would otherwise waste an investigation round on
    a policy rejection. The policy layer still rejects anything outside
    the allowlist.
    """
    if incident_ns is None:
        return tool_args

    args = dict(tool_args)
    if "namespace" in args and args["namespace"] != incident_ns:
        logger.warning(
            "Overriding LLM namespace %r with incident namespace %r",
            args["namespace"],
            incident_ns,
        )
        args["namespace"] = incident_ns
    return args


def _build_proposed_action(
    *,
    tool_name: str,
    tool_args: dict[str, Any],
    risk_tier: int,
    rationale: str,
    requires_approval: bool,
) -> ProposedAction:
    """Construct a well-typed ProposedAction from raw parts."""
    return ProposedAction(
        tool_name=tool_name,
        tool_args=tool_args,
        risk_tier=int(risk_tier),
        rationale=rationale,
        requires_approval=bool(requires_approval),
    )


def _coerce_dict_list(value: Any) -> list[dict[str, Any]]:
    """Return a list of dicts from any value; non-dicts are dropped.

    Used for state reads where the field's runtime shape is
    ``list[dict]`` but the static type is ``object`` (or ``Any``).
    """
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


# ---------------------------------------------------------------------------
# Usage and cost accumulation
# ---------------------------------------------------------------------------


def _accumulate_usage(
    state: AgentState,
    response: Any,
    llm_config: Any,
) -> dict[str, Any]:
    """Return partial state updates for tokens and cost from an LLM response.

    Reads ``response.usage`` (LiteLLM-normalized). Silently no-ops when
    usage is unavailable. Never raises: cost accounting must not fail a
    running investigation.
    """
    if llm_config is None:
        return {}

    usage = getattr(response, "usage", None)
    if usage is None and isinstance(response, dict):
        usage = response.get("usage")

    if usage is None:
        return {}

    model_name = getattr(response, "model", None) or getattr(llm_config, "model_coordinator", "")

    try:
        prompt_tokens, completion_tokens, _cached, cost = calculate_cost(
            usage, str(model_name), llm_config
        )
    except Exception as exc:
        logger.warning("Cost calculation failed: %s", exc)
        return {}

    total_tokens = prompt_tokens + completion_tokens
    if total_tokens == 0 and cost == 0.0:
        return {}

    prev_tokens = state.get("tokens_used", 0)
    prev_cost = state.get("cost_usd", 0.0)

    return {
        "tokens_used": int(prev_tokens or 0) + total_tokens,
        "cost_usd": float(prev_cost or 0.0) + cost,
    }


# ---------------------------------------------------------------------------
# Node 1 — triage
# ---------------------------------------------------------------------------


async def triage_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Generate 2-3 initial hypotheses from alert metadata.

    Uses response_format=json_object because the prompt is short.
    Falls back to a single generic hypothesis on any error so the
    investigation proceeds.
    """
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

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
            **_accumulate_usage(state, response, llm_config),
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during triage")
        return {
            "hypotheses": fallback,
            "current_phase": PHASE_COMPLETE,
            "status": "failed",
        }

    except Exception as exc:
        logger.error("Triage node failed: %s", exc, exc_info=True)
        return {
            "hypotheses": fallback,
            "current_phase": PHASE_INVESTIGATE,
        }


def _normalize_hypotheses_safe(
    raw: Any,
    fallback: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Normalize hypotheses without raising.

    Returns a list of well-formed Hypothesis dicts. On any validation
    failure, returns the fallback list (deep-copied).
    """
    from autosre.core.graph_helpers import normalize_hypotheses

    try:
        normalized = normalize_hypotheses(raw, default_status="proposed")
    except ValueError as exc:
        logger.warning("Hypothesis normalization failed (%s); using fallback", exc)
        return [dict(h) for h in fallback]

    result: list[dict[str, Any]] = []
    for h in normalized:
        result.append(dict(h))
    return result


# ---------------------------------------------------------------------------
# Node 2 — investigate
# ---------------------------------------------------------------------------


async def investigate_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Select and execute one read-only diagnostic tool.

    Decrements iteration_budget on entry (even on early exits) so a
    misbehaving LLM cannot consume infinite rounds.

    Skips response_format because the prompt embeds prior tool outputs
    whose escaping breaks Groq's strict JSON validator.
    """
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    executor = graph_context.executor
    sre_context = _require_sre_context(config)
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    iteration_count = int(state.get("iteration_count", 0) or 0)
    iteration_budget = int(state.get("iteration_budget", 0) or 0)
    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    incident_ns = _incident_metadata(state).get("namespace")
    incident_ns = str(incident_ns) if isinstance(incident_ns, str) else None

    # Guard 1: budget exhausted.
    if iteration_budget <= 0:
        logger.info("Investigation budget exhausted")
        return {"current_phase": PHASE_HYPOTHESIZE}

    # Guard 2: no hypotheses.
    if not hypotheses:
        logger.warning("No hypotheses to investigate")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    # Guard 3: sre_context is mandatory.
    if sre_context is None:
        logger.error("investigate_node: sre_context missing from config")
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration_count + 1,
            "iteration_budget": iteration_budget - 1,
        }

    registry = graph_context.registry

    # Only Tier-0 (read-only) tools are eligible.
    read_only_tools = [
        tool for tool in registry.list_tools() if int(tool.risk_tier) == int(RiskTier.OBSERVE)
    ]

    tool_schemas: list[dict[str, Any]] = [
        {
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.input_model.model_json_schema(),
        }
        for tool in read_only_tools
    ]

    # Build the last three prior tool outputs as evidence context.
    previous_outputs: list[str] = []
    for action in executed_actions[-3:]:
        prior_result = action.get("result", {})
        prior_tool = str(action.get("tool_name", ""))
        previous_outputs.append(
            f"Tool {prior_tool} returned: {json.dumps(prior_result, default=str)[:500]}"
        )

    previous_context = "\n".join(previous_outputs) if previous_outputs else "None yet"

    namespace_hint = (
        f"The incident is in namespace '{incident_ns}'. Always pass "
        f"namespace='{incident_ns}' in tool_args. Do not use any other value."
        if incident_ns
        else "Do not pass a namespace argument unless the tool requires one."
    )

    prompt = f"""You are an SRE agent selecting ONE diagnostic tool to gather evidence.

{namespace_hint}

Available tools (Tier-0, read-only):
{json.dumps(tool_schemas, indent=2)}

Current hypotheses:
{json.dumps(hypotheses, indent=2)}

Previous tool results (last 3):
{previous_context}

Return a JSON object matching this schema:
{{
  "tool_name": "...",
  "tool_args": {{...}},
  "rationale": "..."
}}

Rules:
- Output valid JSON only. No prose, no markdown fences.
- Select ONE tool only.
- Do NOT repeat a tool+args combination already listed in previous results.
- If no tool is appropriate, return {{"tool_name": "none", "tool_args": {{}}, "rationale": "no suitable tool"}}."""

    messages = [
        {"role": "system", "content": prompt},
        {
            "role": "user",
            "content": (
                f"Iteration {iteration_count + 1}. "
                f"Budget remaining: {iteration_budget - 1}. "
                "Select next tool."
            ),
        },
    ]

    try:
        response = await llm_router.acompletion(
            messages=messages,
            run_metrics=run_metrics,
        )
        parsed = parse_json_response(response, stage="investigate")

        tool_name = _coerce_tool_name(parsed.get("tool_name"))
        tool_args_raw = parsed.get("tool_args")
        tool_args: dict[str, Any] = dict(tool_args_raw) if isinstance(tool_args_raw, dict) else {}
        rationale = str(parsed.get("rationale", ""))

        usage_update = _accumulate_usage(state, response, llm_config)

        if tool_name is None or tool_name == "none":
            logger.info("No suitable tool found; proceeding to hypothesize")
            return {
                "current_phase": PHASE_HYPOTHESIZE,
                "iteration_count": iteration_count + 1,
                "iteration_budget": iteration_budget - 1,
                **usage_update,
            }

        if find_tool(tool_schemas, tool_name) is None:
            logger.warning("Tool %s not in the read-only registry", tool_name)
            return {
                "current_phase": PHASE_HYPOTHESIZE,
                "iteration_count": iteration_count + 1,
                "iteration_budget": iteration_budget - 1,
                **usage_update,
            }

        tool_args = _clamp_namespace(tool_args, incident_ns)

        proposed_action = _build_proposed_action(
            tool_name=tool_name,
            tool_args=tool_args,
            risk_tier=int(RiskTier.OBSERVE),
            rationale=rationale,
            requires_approval=False,
        )

        result: ExecutionResult = await executor.execute(proposed_action, sre_context)

        evidence_str = (
            f"Tool {tool_name}({json.dumps(tool_args, default=str)}) "
            f"status={result.status} "
            f"output={json.dumps(result.output or {}, default=str)[:300]}"
        )

        updated_hypotheses: list[dict[str, Any]] = []
        for hyp in hypotheses:
            hyp_copy = dict(hyp)
            raw_evidence = hyp_copy.get("evidence", [])
            evidence: list[str] = (
                [str(x) for x in raw_evidence] if isinstance(raw_evidence, list) else []
            )
            evidence.append(evidence_str)
            hyp_copy["evidence"] = evidence
            updated_hypotheses.append(hyp_copy)

        return {
            "hypotheses": updated_hypotheses,
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration_count + 1,
            "iteration_budget": iteration_budget - 1,
            **usage_update,
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during investigation")
        return {
            "current_phase": PHASE_COMPLETE,
            "status": "failed",
        }

    except Exception as exc:
        logger.error("Investigate node failed: %s", exc, exc_info=True)
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration_count + 1,
            "iteration_budget": iteration_budget - 1,
        }


# ---------------------------------------------------------------------------
# Node 3 — hypothesize
# ---------------------------------------------------------------------------


async def hypothesize_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Refine hypothesis confidence and decide the next phase.

    Decision tree, in order:
        1. No hypotheses       -> complete / failed
        2. Confidence high     -> propose
        3. Budget exhausted    -> propose if confidence >= floor, else
                                  complete / no_action
        4. Stagnation limit    -> complete / no_action
        5. Otherwise           -> investigate
    """
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    iteration_budget = int(state.get("iteration_budget", 0) or 0)
    last_confidence = float(state.get("last_top_confidence", 0.0) or 0.0)
    stagnation_count = int(state.get("stagnation_count", 0) or 0)

    if not hypotheses:
        logger.warning("No hypotheses to refine")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    best_before = top_hypothesis(hypotheses)
    current_confidence = float(best_before.get("confidence", 0.0) or 0.0) if best_before else 0.0

    if current_confidence >= HIGH_CONFIDENCE_THRESHOLD:
        logger.info(
            "Confidence %.2f >= threshold %.2f; proceeding to propose",
            current_confidence,
            HIGH_CONFIDENCE_THRESHOLD,
        )
        return {
            "current_phase": PHASE_PROPOSE,
            "last_top_confidence": current_confidence,
        }

    if iteration_budget <= 0:
        if current_confidence >= MIN_CONFIDENCE_FOR_ACTION:
            logger.info(
                "Budget exhausted at confidence %.2f; proceeding to propose",
                current_confidence,
            )
            return {
                "current_phase": PHASE_PROPOSE,
                "last_top_confidence": current_confidence,
            }
        logger.info(
            "Budget exhausted at confidence %.2f; completing with no_action",
            current_confidence,
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

        improvement = new_confidence - last_confidence
        improved = improvement >= MIN_CONFIDENCE_IMPROVEMENT
        new_stagnation = 0 if improved else stagnation_count + 1

        usage_update = _accumulate_usage(state, response, llm_config)

        logger.info(
            "Hypothesis refinement: confidence %.2f -> %.2f (delta=%.2f, stagnation=%d/%d)",
            last_confidence,
            new_confidence,
            improvement,
            new_stagnation,
            STAGNATION_LIMIT,
        )

        if new_confidence >= HIGH_CONFIDENCE_THRESHOLD:
            return {
                "hypotheses": refined,
                "current_phase": PHASE_PROPOSE,
                "last_top_confidence": new_confidence,
                "stagnation_count": new_stagnation,
                **usage_update,
            }

        if new_stagnation >= STAGNATION_LIMIT:
            logger.info(
                "Stagnation limit reached at confidence %.2f; completing with no_action",
                new_confidence,
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
        return {
            "current_phase": PHASE_COMPLETE,
            "status": "failed",
        }

    except Exception as exc:
        logger.error("Hypothesize node failed: %s", exc, exc_info=True)
        return {
            "hypotheses": hypotheses,
            "current_phase": PHASE_PROPOSE,
            "last_top_confidence": current_confidence,
        }


# ---------------------------------------------------------------------------
# Node 4 — propose
# ---------------------------------------------------------------------------


async def propose_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Select a remediation action based on the top hypothesis.

    Enforces three guards before proposing:
        1. action_attempts < MAX_ACTION_ATTEMPTS
        2. top confidence >= MIN_CONFIDENCE_FOR_ACTION
        3. proposed tool is not a duplicate mutation

    Returns status=no_action when the confidence guard fires, so the
    incident is not falsely marked resolved.
    """
    graph_context = get_graph_context(config)
    llm_router = graph_context.llm_router
    llm_config = _llm_config(graph_context)
    run_metrics = _get_run_metrics(config)

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)
    incident_ns = _incident_metadata(state).get("namespace")
    incident_ns = str(incident_ns) if isinstance(incident_ns, str) else None

    if action_attempts >= MAX_ACTION_ATTEMPTS:
        logger.info(
            "Action attempt cap reached (%d/%d); completing with failed",
            action_attempts,
            MAX_ACTION_ATTEMPTS,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    if not hypotheses:
        logger.info("No hypotheses; completing with no_action")
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    best = top_hypothesis(hypotheses)
    confidence = float(best.get("confidence", 0.0) or 0.0) if best else 0.0
    if confidence < MIN_CONFIDENCE_FOR_ACTION:
        logger.info(
            "Top hypothesis confidence %.2f < %.2f; completing with no_action",
            confidence,
            MIN_CONFIDENCE_FOR_ACTION,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    registry = graph_context.registry

    eligible_tools = [
        tool
        for tool in registry.list_tools()
        if int(tool.risk_tier) in (int(RiskTier.REVERSIBLE_LOW), int(RiskTier.REVERSIBLE_HIGH))
    ]

    tool_schemas: list[dict[str, Any]] = [
        {
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.input_model.model_json_schema(),
            "risk_tier": int(tool.risk_tier),
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

        tool_name = _coerce_tool_name(parsed.get("tool_name"))
        tool_args_raw = parsed.get("tool_args")
        tool_args: dict[str, Any] = dict(tool_args_raw) if isinstance(tool_args_raw, dict) else {}
        rationale = str(parsed.get("rationale", ""))

        risk_tier_raw = parsed.get("risk_tier", 1)
        try:
            risk_tier = int(risk_tier_raw)
        except TypeError, ValueError:
            risk_tier = 1

        usage_update = _accumulate_usage(state, response, llm_config)

        if tool_name is None or tool_name == "none":
            logger.info("Agent proposed no action; completing with no_action")
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "no_action",
                **usage_update,
            }

        if is_action_already_executed(tool_name, tool_args, executed_actions):
            logger.warning(
                "Duplicate action rejected: %s (already executed)",
                tool_name,
            )
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "no_action",
                **usage_update,
            }

        attempts = count_action_attempts(tool_name, executed_actions)
        if attempts >= 2 and tool_name in MUTATING_TOOLS:
            logger.warning(
                "Tool %s already attempted %d times; completing with failed",
                tool_name,
                attempts,
            )
            return {
                "current_phase": PHASE_COMPLETE,
                "status": "failed",
                **usage_update,
            }

        tool_args = _clamp_namespace(tool_args, incident_ns)

        proposed = _build_proposed_action(
            tool_name=tool_name,
            tool_args=tool_args,
            risk_tier=risk_tier,
            rationale=rationale,
            requires_approval=risk_tier >= 2,
        )

        return {
            "proposed_actions": [proposed],
            "requires_human_approval": risk_tier >= 2,
            "current_phase": (PHASE_APPROVE if risk_tier >= 2 else PHASE_EXECUTE),
            **usage_update,
        }

    except LLMBudgetExhaustedError:
        logger.error("LLM budget exhausted during propose")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    except Exception as exc:
        logger.error("Propose node failed: %s", exc, exc_info=True)
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}


# ---------------------------------------------------------------------------
# Node 5 — approve (HITL gate)
# ---------------------------------------------------------------------------


async def approve_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Pause for human approval of Tier-2+ actions.

    Uses LangGraph's interrupt() to suspend execution. Everything above
    the interrupt() call must be side-effect free, because it re-executes
    on resume. All code below interrupt() runs once, after the resume
    payload has been delivered.
    """
    from langgraph.types import interrupt

    proposed_actions = _coerce_dict_list(state.get("proposed_actions"))
    if not proposed_actions:
        logger.warning("approve_node called with no proposed actions")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    last_proposal = proposed_actions[-1]
    tool_name = str(last_proposal.get("tool_name", "unknown"))
    risk_tier = int(last_proposal.get("risk_tier", 2) or 2)
    rationale = str(last_proposal.get("rationale", ""))
    tool_args = last_proposal.get("tool_args", {})

    approval_request = {
        "type": "approval_request",
        "action": {
            "tool_name": tool_name,
            "tool_args": tool_args,
            "risk_tier": risk_tier,
        },
        "message": (
            f"Human approval required for Tier-{risk_tier} "
            f"action: {tool_name}. Rationale: {rationale}"
        ),
    }

    response = interrupt(approval_request)

    approved = False
    comment = ""

    if isinstance(response, dict):
        approved = bool(response.get("approved", False))
        comment = str(response.get("comment", ""))
    elif isinstance(response, bool):
        approved = response

    logger.info(
        "Approval %s for incident: %s",
        "granted" if approved else "denied",
        comment or "(no comment)",
    )

    if approved:
        return {
            "approval_granted": True,
            "approval_comment": comment,
            "current_phase": PHASE_EXECUTE,
        }

    return {
        "approval_granted": False,
        "approval_comment": comment,
        "current_phase": PHASE_COMPLETE,
        "status": "failed",
    }


# ---------------------------------------------------------------------------
# Node 6 — execute
# ---------------------------------------------------------------------------


async def execute_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Dispatch the last proposed action through the SafeExecutor.

    Enforces the MAX_ACTION_ATTEMPTS cap before dispatch so a replay or
    retry cannot exceed the configured mutation budget. Increments
    action_attempts on every successful dispatch.
    """
    graph_context = get_graph_context(config)
    executor = graph_context.executor
    sre_context = _require_sre_context(config)

    proposed_actions = _coerce_dict_list(state.get("proposed_actions"))
    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)
    incident_id = _incident_metadata(state).get("incident_id")
    incident_id = str(incident_id) if isinstance(incident_id, str) else None

    if not proposed_actions:
        logger.warning("execute_node called with no proposed actions")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    if sre_context is None:
        logger.error("execute_node: sre_context missing from config")
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    if action_attempts >= MAX_ACTION_ATTEMPTS:
        logger.warning(
            "Action attempt cap already reached (%d/%d) before dispatch",
            action_attempts,
            MAX_ACTION_ATTEMPTS,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    last_proposal = proposed_actions[-1]
    tool_name = str(last_proposal.get("tool_name", ""))
    tool_args_raw = last_proposal.get("tool_args", {})
    tool_args: dict[str, Any] = dict(tool_args_raw) if isinstance(tool_args_raw, dict) else {}

    if is_action_already_executed(tool_name, tool_args, executed_actions):
        logger.warning("Action already executed; skipping: %s", tool_name)
        return {"current_phase": PHASE_VERIFY}

    action = _build_proposed_action(
        tool_name=tool_name,
        tool_args=tool_args,
        risk_tier=int(last_proposal.get("risk_tier", 0) or 0),
        rationale=str(last_proposal.get("rationale", "")),
        requires_approval=bool(last_proposal.get("requires_approval", False)),
    )

    try:
        result: ExecutionResult = await executor.execute(
            action,
            sre_context,
            incident_id=incident_id,
        )

        executed_action = result.to_executed_action()

        logger.info(
            "Executed %s: status=%s executed=%s verified=%s rolled_back=%s",
            tool_name,
            result.status,
            result.executed,
            result.verified,
            result.rolled_back,
        )

        return {
            "executed_actions": list(executed_actions) + [executed_action],
            "action_attempts": action_attempts + 1,
            "current_phase": PHASE_VERIFY,
        }

    except Exception as exc:
        logger.error("Execute node failed: %s", exc, exc_info=True)
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}


# ---------------------------------------------------------------------------
# Node 7 — verify
# ---------------------------------------------------------------------------


async def verify_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Check whether the last executed action resolved the incident.

    Rules:
        success=True and verification_passed=True   -> resolved
        success=True and verification_passed=None   -> Tier-1 implied
                                                       verification
        success=True and verification_passed=False  -> retry or fail
        success=False                               -> retry or fail

    Retry is allowed only when action_attempts < MAX_ACTION_ATTEMPTS.
    """
    graph_context = get_graph_context(config)
    registry = graph_context.registry

    executed_actions = _coerce_dict_list(state.get("executed_actions"))
    action_attempts = int(state.get("action_attempts", 0) or 0)

    if not executed_actions:
        logger.info("No executed actions; completing with no_action")
        return {"current_phase": PHASE_COMPLETE, "status": "no_action"}

    last_action = executed_actions[-1]
    success = bool(last_action.get("success", False))
    verification_passed = last_action.get("verification_passed")
    tool_name = str(last_action.get("tool_name", ""))

    if success and verification_passed is None and tool_name:
        try:
            tool = registry.get(tool_name)
        except Exception:
            tool = None

        if tool is not None and int(tool.risk_tier) == int(RiskTier.REVERSIBLE_LOW):
            verification_passed = True
            logger.info("Tier-1 action %s: success implies verified", tool_name)

    if success and verification_passed:
        logger.info("Action verified successfully; completing with resolved")
        return {"current_phase": PHASE_COMPLETE, "status": "resolved"}

    if action_attempts >= MAX_ACTION_ATTEMPTS:
        logger.warning(
            "Max action attempts (%d) reached; completing with failed",
            MAX_ACTION_ATTEMPTS,
        )
        return {"current_phase": PHASE_COMPLETE, "status": "failed"}

    logger.info(
        "Action not verified (attempt %d/%d); re-proposing",
        action_attempts,
        MAX_ACTION_ATTEMPTS,
    )
    return {"current_phase": PHASE_PROPOSE}


# ---------------------------------------------------------------------------
# Node 8 — complete
# ---------------------------------------------------------------------------


async def complete_node(
    state: AgentState,
    config: RunnableConfig,
) -> dict[str, Any]:
    """Terminal node: compute final timing and derive the terminal status.

    Timing:
        wall_clock_seconds = time.time() - started_at
        backoff_seconds    = max(state.backoff_seconds, run_metrics.backoff)
        active_seconds     = max(0, wall_clock - backoff)

    Status rules:
        Preserve any status already set to a terminal value.
        If running and executed_actions is empty  -> no_action
        If running and any executed action
        has success=True                          -> resolved
        Otherwise                                 -> failed
    """
    started_at = float(state.get("started_at", 0.0) or 0.0)

    if started_at > 0:
        wall_clock_seconds = max(0.0, time.time() - started_at)
    else:
        logger.warning("started_at is 0 or missing; cannot compute wall time")
        wall_clock_seconds = 0.0

    state_backoff = float(state.get("backoff_seconds", 0.0) or 0.0)
    metrics = _get_run_metrics(config)
    metrics_backoff = metrics.backoff_seconds if metrics is not None else 0.0
    backoff_seconds = max(state_backoff, metrics_backoff)

    active_seconds = max(0.0, wall_clock_seconds - backoff_seconds)

    current_status = state.get("status", "running")
    executed_actions = _coerce_dict_list(state.get("executed_actions"))

    if current_status in ("resolved", "failed", "no_action", "blocked"):
        status = current_status
    elif not executed_actions:
        status = "no_action"
    else:
        any_success = any(bool(a.get("success", False)) for a in executed_actions)
        status = "resolved" if any_success else "failed"

    hypotheses = _coerce_dict_list(state.get("hypotheses"))
    proposed_actions = _coerce_dict_list(state.get("proposed_actions"))
    tokens_used = int(state.get("tokens_used", 0) or 0)
    cost_usd = float(state.get("cost_usd", 0.0) or 0.0)

    logger.info(
        "Investigation complete: status=%s hypotheses=%d "
        "proposed=%d executed=%d tokens=%d cost=$%.4f "
        "wall=%.1fs backoff=%.1fs active=%.1fs",
        status,
        len(hypotheses),
        len(proposed_actions),
        len(executed_actions),
        tokens_used,
        cost_usd,
        wall_clock_seconds,
        backoff_seconds,
        active_seconds,
    )

    return {
        "current_phase": PHASE_COMPLETE,
        "wall_clock_seconds": wall_clock_seconds,
        "backoff_seconds": backoff_seconds,
        "active_seconds": active_seconds,
        "status": status,
    }


# ---------------------------------------------------------------------------
# Routing functions
# ---------------------------------------------------------------------------

_ALL_PHASES: frozenset[str] = frozenset(
    {
        PHASE_TRIAGE,
        PHASE_INVESTIGATE,
        PHASE_HYPOTHESIZE,
        PHASE_PROPOSE,
        PHASE_APPROVE,
        PHASE_EXECUTE,
        PHASE_VERIFY,
        PHASE_COMPLETE,
    }
)

_TERMINAL_STATUSES: frozenset[str] = frozenset({"failed", "no_action", "blocked"})


def route_initial_phase(state: AgentState) -> str:
    """Return the phase to start (or resume) from."""
    phase = state.get("current_phase", PHASE_TRIAGE)
    return phase if phase in _ALL_PHASES else PHASE_TRIAGE


def route_after_hypothesize(state: AgentState) -> str:
    """Route after hypothesize_node."""
    if state.get("status") in _TERMINAL_STATUSES:
        return PHASE_COMPLETE

    phase = state.get("current_phase", PHASE_COMPLETE)
    if phase in (PHASE_INVESTIGATE, PHASE_PROPOSE, PHASE_COMPLETE):
        return phase
    return PHASE_COMPLETE


def route_after_propose(state: AgentState) -> str:
    """Route after propose_node."""
    if state.get("status") in _TERMINAL_STATUSES:
        return PHASE_COMPLETE

    phase = state.get("current_phase", PHASE_COMPLETE)
    if phase in (PHASE_APPROVE, PHASE_EXECUTE, PHASE_COMPLETE):
        return phase
    return PHASE_COMPLETE


def route_after_approval(state: AgentState) -> str:
    """Route after approve_node."""
    phase = state.get("current_phase", PHASE_COMPLETE)
    if phase in (PHASE_EXECUTE, PHASE_COMPLETE):
        return phase
    return PHASE_COMPLETE


def route_after_verify(state: AgentState) -> str:
    """Route after verify_node."""
    if state.get("status") in _TERMINAL_STATUSES:
        return PHASE_COMPLETE

    phase = state.get("current_phase", PHASE_COMPLETE)
    if phase in (PHASE_PROPOSE, PHASE_COMPLETE):
        return phase
    return PHASE_COMPLETE


__all__ = [
    "approve_node",
    "complete_node",
    "execute_node",
    "hypothesize_node",
    "investigate_node",
    "propose_node",
    "route_after_approval",
    "route_after_hypothesize",
    "route_after_propose",
    "route_after_verify",
    "route_initial_phase",
    "triage_node",
    "verify_node",
]
