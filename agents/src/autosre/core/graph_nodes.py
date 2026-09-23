"""Graph node functions and routing functions for the SRE investigation loop.

Each node function receives (AgentState, RunnableConfig) and returns a partial
state update dict. Routing functions inspect state and return the next phase name.

Node execution order:
  triage → investigate → hypothesize → propose → approve → execute → verify → complete

Phase B sync: Ready for scale_deployment, get_pod_metrics, get_valkey_stream_info
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any, Literal, cast
from uuid import uuid4

from langchain_core.runnables import RunnableConfig

from autosre.core.cost import calculate_cost
from autosre.core.graph_helpers import (
    MAX_ITERATIONS,
    PHASE_APPROVE,
    PHASE_COMPLETE,
    PHASE_EXECUTE,
    PHASE_HYPOTHESIZE,
    PHASE_INVESTIGATE,
    PHASE_PROPOSE,
    PHASE_TRIAGE,
    PHASE_VERIFY,
    PHASES,
    READ_ONLY_TOOL_NAMES,
    REMEDIATION_RISK_TIERS,
    approval_value_to_bool,
    find_tool,
    get_graph_context,
    is_high_confidence,
    list_tool_specs,
    maybe_await,
    normalize_hypotheses,
    parse_json_response,
    safe_json,
    top_hypothesis,
)
from autosre.core.state import (
    AgentState,
    ExecutedAction,
    Hypothesis,
    ProposedAction,
    SREContext,
)
from autosre.safety.executor import ExecutionResult

logger = logging.getLogger(__name__)

MAX_CONSECUTIVE_TOOL_FAILURES = 3
MAX_REMEDIATION_ATTEMPTS = 3


def _utc_now() -> str:
    """Return current UTC time in ISO 8601 format with Z suffix."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _get_sre_context(config: RunnableConfig) -> SREContext:
    """Extract and validate SREContext from RunnableConfig."""
    sre_context = config.get("configurable", {}).get("sre_context")
    if sre_context is None:
        raise ValueError("SREContext must be provided in config['configurable']['sre_context']")
    if not isinstance(sre_context, SREContext):
        raise TypeError(f"Expected SREContext, got {type(sre_context).__name__}")
    return sre_context


async def triage_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Generate initial hypotheses from the alert metadata.

    Returns 2-3 low-confidence hypotheses to guide investigation.
    Falls back to a generic hypothesis if LLM call fails.
    """
    ctx = get_graph_context(config)
    sre_context = _get_sre_context(config)
    metadata = state["incident_metadata"]
    logger.info("Triage node: analyzing alert %s", metadata["alert_name"])

    prompt = f"""You are an SRE investigation coordinator.

Alert:
- Name: {metadata["alert_name"]}
- Service: {metadata["service"]}
- Namespace: {metadata["namespace"]}
- Severity: {metadata["severity"]}
- Started: {metadata["started_at"]}

Return JSON only:
{{
  "hypotheses": [
    {{"id": "H1", "description": "...", "confidence": 0.0, "evidence": []}}
  ]
}}

Provide 2-3 plausible root-cause hypotheses. Confidence between 0.0 and 1.0.
Start with low confidence (0.2-0.4) since no evidence has been gathered yet.
"""
    call_cost = 0.0
    total_tokens = 0
    hypotheses: list[Hypothesis] = []

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.3,
            )
        )
        actual_model = getattr(response, "model", "unknown")
        prompt_tokens, completion_tokens, _cached, call_cost = calculate_cost(
            getattr(response, "usage", None),
            actual_model,
            sre_context.llm_config,
        )
        total_tokens = prompt_tokens + completion_tokens
        payload = parse_json_response(response, stage="triage")
        hypotheses = normalize_hypotheses(payload.get("hypotheses"), default_status="proposed")
    except Exception as exc:
        logger.warning("Triage LLM call failed, using fallback: %s", exc)
        hypotheses = [
            Hypothesis(
                id="H1",
                description=f"Investigate {metadata['alert_name']} on {metadata['service']}",
                confidence=0.2,
                evidence=[f"Alert: {metadata['alert_name']}"],
                status="proposed",
            )
        ]

    return {
        "hypotheses": hypotheses,
        "current_phase": PHASE_INVESTIGATE,
        "iteration_count": state.get("iteration_count", 0),
        "tokens_used": state.get("tokens_used", 0) + total_tokens,
        "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
        "consecutive_tool_failures": state.get("consecutive_tool_failures", 0),
    }


async def investigate_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Select and execute one read-only diagnostic tool.

    Updates hypothesis evidence with tool results. Transitions to hypothesize
    when MAX_ITERATIONS or MAX_CONSECUTIVE_TOOL_FAILURES is reached.
    """
    ctx = get_graph_context(config)
    sre_context = _get_sre_context(config)
    iteration = state.get("iteration_count", 0) + 1
    consecutive_failures = state.get("consecutive_tool_failures", 0)
    metadata = state["incident_metadata"]

    logger.info("Investigate node: iteration %d, failures %d", iteration, consecutive_failures)

    if iteration > MAX_ITERATIONS:
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
            "consecutive_tool_failures": 0,
            "hypotheses": state.get("hypotheses", []),
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    if consecutive_failures >= MAX_CONSECUTIVE_TOOL_FAILURES:
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
            "consecutive_tool_failures": 0,
            "hypotheses": state.get("hypotheses", []),
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    hypotheses = state.get("hypotheses", [])
    if not hypotheses:
        return {
            "current_phase": PHASE_COMPLETE,
            "iteration_count": iteration,
            "consecutive_tool_failures": 0,
            "hypotheses": [],
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    try:
        specs = await list_tool_specs(ctx.registry)
    except Exception:
        logger.exception("Unable to enumerate investigation tools")
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
            "consecutive_tool_failures": consecutive_failures + 1,
            "hypotheses": hypotheses,
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    # Filter to read-only tools (Tier 0 or in READ_ONLY_TOOL_NAMES)
    investigation_specs = [
        spec
        for spec in specs
        if spec.get("risk_tier") == 0
        or (spec.get("risk_tier") is None and spec.get("name") in READ_ONLY_TOOL_NAMES)
    ]

    if not investigation_specs:
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
            "consecutive_tool_failures": 0,
            "hypotheses": hypotheses,
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    hypothesis_text = "\n".join(
        f"- {h['id']}: {h['description']} (confidence={h['confidence']})" for h in hypotheses
    )
    tools_text = "\n\n".join(
        f"Tool: {s['name']}\nDescription: {s.get('description', '')}\n"
        f"Schema: {json.dumps(s.get('input_schema', {}), indent=2)}"
        for s in investigation_specs
    )

    prompt = f"""You are investigating an SRE incident.
Service: {metadata["service"]}, Namespace: {metadata["namespace"]}, Alert: {metadata["alert_name"]}

Hypotheses:
{hypothesis_text}

Available read-only tools:

{tools_text}

Select ONE tool. Use the EXACT field names from the schema above.

Return JSON only:
{{
  "tool_name": "<exact tool name>",
  "tool_args": {{<exact fields from schema, all REQUIRED fields>}},
  "rationale": "Why this tool helps"
}}
"""
    selected_name: str | None = None
    tool_args: dict[str, Any] = {}
    rationale = "No rationale supplied"
    call_cost = 0.0
    total_tokens = 0

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.2,
            )
        )
        actual_model = getattr(response, "model", "unknown")
        prompt_tokens, completion_tokens, _cached, call_cost = calculate_cost(
            getattr(response, "usage", None),
            actual_model,
            sre_context.llm_config,
        )
        total_tokens = prompt_tokens + completion_tokens
        payload = parse_json_response(response, stage="investigation")
        raw_name = payload.get("tool_name")
        raw_args = payload.get("tool_args", {})
        if raw_name is not None:
            selected_name = str(raw_name).strip() or None
        if not isinstance(raw_args, Mapping):
            raise ValueError("tool_args must be an object")
        tool_args = dict(raw_args)
        rationale = str(payload.get("rationale", rationale)).strip() or rationale
    except Exception as exc:
        logger.warning("Investigation tool selection failed: %s", exc)

    selected_spec = find_tool(investigation_specs, selected_name) if selected_name else None

    if selected_spec is None:
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
            "consecutive_tool_failures": consecutive_failures + 1,
            "hypotheses": hypotheses,
            "tokens_used": state.get("tokens_used", 0) + total_tokens,
            "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
        }

    assert selected_name is not None

    investigation_action: ProposedAction = ProposedAction(
        tool_name=selected_name,
        tool_args=tool_args,
        risk_tier=0,
        rationale=rationale,
        requires_approval=False,
    )

    evidence_line = ""
    tool_succeeded = False
    try:
        exec_result: ExecutionResult = await ctx.executor.execute(investigation_action, sre_context)
        success = exec_result.executed and exec_result.error is None
        verified = exec_result.verified
        result_payload: dict[str, Any] = exec_result.output or {}
        tool_succeeded = success
        evidence_line = (
            f"Tool {selected_name}({json.dumps(tool_args)}) returned "
            f"success={success}, verified={verified}: {safe_json(result_payload)}"
        )
    except Exception as exc:
        logger.exception("Investigation tool execution failed")
        evidence_line = f"Tool {selected_name} failed: {type(exc).__name__}: {exc}"

    new_consecutive_failures = 0 if tool_succeeded else consecutive_failures + 1

    updated_hypotheses: list[Hypothesis] = []
    for h in hypotheses:
        updated_h = dict(h)
        evidence_list = list(h.get("evidence", []))
        evidence_list.append(evidence_line)
        updated_h["evidence"] = evidence_list[-20:]  # Keep last 20 evidence items
        updated_hypotheses.append(cast(Hypothesis, updated_h))

    return {
        "hypotheses": updated_hypotheses,
        "current_phase": PHASE_HYPOTHESIZE,
        "iteration_count": iteration,
        "tokens_used": state.get("tokens_used", 0) + total_tokens,
        "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
        "consecutive_tool_failures": new_consecutive_failures,
    }


async def hypothesize_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Refine hypothesis confidence based on collected evidence.

    Transitions to propose when any hypothesis reaches confidence >= 0.8
    or MAX_ITERATIONS is reached. Otherwise loops back to investigate.
    """
    ctx = get_graph_context(config)
    sre_context = _get_sre_context(config)
    hypotheses = state.get("hypotheses", [])
    iteration = state.get("iteration_count", 0) + 1

    logger.info("Hypothesize node: %d hypotheses, iteration %d", len(hypotheses), iteration)

    if not hypotheses:
        return {
            "current_phase": PHASE_COMPLETE,
            "iteration_count": iteration,
            "consecutive_tool_failures": 0,
        }

    if is_high_confidence(hypotheses) or iteration >= MAX_ITERATIONS:
        return {
            "current_phase": PHASE_PROPOSE,
            "iteration_count": iteration,
            "hypotheses": hypotheses,
            "consecutive_tool_failures": state.get("consecutive_tool_failures", 0),
            "tokens_used": state.get("tokens_used", 0),
            "cost_usd": state.get("cost_usd", 0.0),
        }

    prompt = f"""Refine these SRE hypotheses using only collected evidence. Do not invent evidence.

{json.dumps(hypotheses, default=str)}

Return JSON only:
{{
  "hypotheses": [
    {{"id": "H1", "description": "...", "confidence": 0.0, "evidence": [], "status": "proposed"}}
  ]
}}

Confidence >= 0.8 is sufficient to propose remediation.
"""
    call_cost = 0.0
    total_tokens = 0
    refined = hypotheses

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
            )
        )
        actual_model = getattr(response, "model", "unknown")
        prompt_tokens, completion_tokens, _cached, call_cost = calculate_cost(
            getattr(response, "usage", None),
            actual_model,
            sre_context.llm_config,
        )
        total_tokens = prompt_tokens + completion_tokens
        payload = parse_json_response(response, stage="hypothesis refinement")
        refined = normalize_hypotheses(payload.get("hypotheses"), default_status="proposed")
    except Exception as exc:
        logger.warning("Hypothesis refinement failed: %s", exc)
        refined = [cast(Hypothesis, dict(h)) for h in hypotheses]

    return {
        "hypotheses": refined,
        "current_phase": PHASE_PROPOSE if is_high_confidence(refined) else PHASE_INVESTIGATE,
        "iteration_count": iteration,
        "tokens_used": state.get("tokens_used", 0) + total_tokens,
        "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
        "consecutive_tool_failures": state.get("consecutive_tool_failures", 0),
    }


async def propose_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Create a remediation proposal with full tool schemas and error feedback.

    Includes validation error feedback from previous failed attempts to prevent
    the LLM from repeating the same mistakes. Sets requires_human_approval=True
    for Tier-2+ actions.
    """
    ctx = get_graph_context(config)
    sre_context = _get_sre_context(config)
    existing_actions = state.get("proposed_actions", [])
    metadata = state["incident_metadata"]

    top = top_hypothesis(state.get("hypotheses", []))
    if top is None:
        return {"current_phase": PHASE_COMPLETE}

    try:
        specs = await list_tool_specs(ctx.registry)
    except Exception:
        logger.exception("Unable to enumerate remediation tools")
        return {"current_phase": PHASE_COMPLETE}

    available_actions = [s for s in specs if s.get("name") in REMEDIATION_RISK_TIERS]
    if not available_actions:
        return {"current_phase": PHASE_COMPLETE}

    tools_text = "\n\n".join(
        f"Tool: {s['name']}\nDescription: {s.get('description', '')}\n"
        f"Schema: {json.dumps(s.get('input_schema', {}), indent=2)}"
        for s in available_actions
    )

    previous_tools = [a.get("tool_name") for a in existing_actions]
    previous_note = ""
    if previous_tools:
        previous_note = f"\nPreviously attempted tools (DO NOT repeat identical calls): {', '.join(previous_tools)}"

    # Feed back validation errors from failed executions to prevent repetition
    error_feedback = ""
    executed = state.get("executed_actions", [])
    failed_actions = [a for a in executed if not a.get("success")]
    if failed_actions:
        last_failed = failed_actions[-1]
        result = last_failed.get("result", {})
        error_msg = result.get("error", "") if isinstance(result, dict) else str(result)
        if error_msg:
            error_msg_truncated = error_msg[:1000]
            error_feedback = (
                f"\n\n### PREVIOUS EXECUTION FAILED ###\n"
                f"Tool: {last_failed.get('tool_name')}\n"
                f"Args: {json.dumps(last_failed.get('tool_args', {}))}\n"
                f"Error:\n{error_msg_truncated}\n"
                f"### FIX THE tool_args TO MATCH THE SCHEMA EXACTLY. "
                f"Do NOT repeat the same invalid field names. ###\n"
            )

    prompt = f"""You are proposing SRE remediation.

Incident context:
- Service: {metadata["service"]}
- Namespace: {metadata["namespace"]}

Root cause: {top["description"]}
Confidence: {top["confidence"]}
Evidence: {json.dumps(top.get("evidence", []), default=str)}
{previous_note}
{error_feedback}

Available remediation tools:

{tools_text}

Return JSON only:
{{
  "tool_name": "<exact tool name>",
  "tool_args": {{<exact fields from tool schema, ALL REQUIRED fields included>}},
  "risk_tier": <integer from schema>,
  "rationale": "Why this fixes the root cause"
}}

CRITICAL: Use EXACT field names from the schema. The namespace is "{metadata["namespace"]}" and service is "{metadata["service"]}".
"""
    call_cost = 0.0
    total_tokens = 0

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.2,
            )
        )
        actual_model = getattr(response, "model", "unknown")
        prompt_tokens, completion_tokens, _cached, call_cost = calculate_cost(
            getattr(response, "usage", None),
            actual_model,
            sre_context.llm_config,
        )
        total_tokens = prompt_tokens + completion_tokens
        payload = parse_json_response(response, stage="proposal")
        tool_name_raw = str(payload.get("tool_name", "")).strip()
        raw_args = payload.get("tool_args", {})
        if not tool_name_raw or not isinstance(raw_args, Mapping):
            raise ValueError("proposal must contain tool_name and object tool_args")
        spec = find_tool(available_actions, tool_name_raw)
        if spec is None:
            raise ValueError(f"unsupported remediation tool: {tool_name_raw}")
        model_tier_raw = payload.get("risk_tier", 1)
        if isinstance(model_tier_raw, bool):
            raise ValueError("risk_tier must be an integer")
        model_tier = int(model_tier_raw)
        if model_tier < 0:
            raise ValueError("risk_tier cannot be negative")
        baseline_tier = REMEDIATION_RISK_TIERS[tool_name_raw]
        registry_tier = spec.get("risk_tier")
        effective_tier = max(
            baseline_tier,
            model_tier,
            int(registry_tier) if registry_tier is not None else 0,
        )
        rationale = str(payload.get("rationale", "")).strip()
        if not rationale:
            raise ValueError("proposal rationale is required")
    except Exception as exc:
        logger.error("Proposal generation failed: %s", exc)
        if state.get("iteration_count", 0) >= MAX_ITERATIONS:
            return {
                "current_phase": PHASE_COMPLETE,
                "tokens_used": state.get("tokens_used", 0) + total_tokens,
                "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
            }
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": state.get("iteration_count", 0) + 1,
            "tokens_used": state.get("tokens_used", 0) + total_tokens,
            "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
            "consecutive_tool_failures": state.get("consecutive_tool_failures", 0),
        }

    proposed_action: ProposedAction = ProposedAction(
        tool_name=tool_name_raw,
        tool_args=dict(raw_args),
        risk_tier=effective_tier,
        rationale=rationale,
        requires_approval=effective_tier >= 2,
    )
    return {
        "proposed_actions": list(existing_actions) + [proposed_action],
        "current_phase": PHASE_APPROVE if effective_tier >= 2 else PHASE_EXECUTE,
        "requires_human_approval": effective_tier >= 2,
        "approval_granted": None,
        "tokens_used": state.get("tokens_used", 0) + total_tokens,
        "cost_usd": round(state.get("cost_usd", 0.0) + call_cost, 6),
    }


async def approve_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Human-in-the-loop approval gate for Tier-2+ actions.

    Uses LangGraph's interrupt() to pause execution and wait for human approval.
    Tier-1 actions skip this node and proceed directly to execute.
    """
    from langgraph.types import interrupt

    del config
    proposed_actions = state.get("proposed_actions", [])
    if not proposed_actions:
        return {
            "current_phase": PHASE_COMPLETE,
            "requires_human_approval": False,
            "approval_granted": False,
        }
    action = proposed_actions[-1]
    risk_tier = int(action.get("risk_tier", 1))
    if risk_tier < 2:
        return {
            "current_phase": PHASE_EXECUTE,
            "requires_human_approval": False,
            "approval_granted": True,
        }
    response = interrupt(
        {
            "type": "approval_request",
            "action": dict(action),
            "message": f"Human approval required for Tier-{risk_tier} action. Rationale: {action.get('rationale', '')}",
        }
    )
    approved = approval_value_to_bool(response)
    if not approved:
        return {
            "current_phase": PHASE_COMPLETE,
            "requires_human_approval": False,
            "approval_granted": False,
        }
    return {
        "current_phase": PHASE_EXECUTE,
        "requires_human_approval": False,
        "approval_granted": True,
    }


async def execute_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Execute the proposed remediation action via SafeExecutor.

    Records the execution result in executed_actions and transitions to verify.
    """
    ctx = get_graph_context(config)
    proposed_actions = state.get("proposed_actions", [])
    if not proposed_actions:
        return {"current_phase": PHASE_COMPLETE}
    action = proposed_actions[-1]
    logger.info(
        "Executing action %s(%s)", action.get("tool_name"), json.dumps(action.get("tool_args", {}))
    )
    sre_context = _get_sre_context(config)
    try:
        exec_result: ExecutionResult = await ctx.executor.execute(action, sre_context)
        success = exec_result.executed and exec_result.error is None
        verified = exec_result.verified
        result_payload: dict[str, Any] = exec_result.output or {}
    except Exception as exc:
        logger.exception("SafeExecutor failed")
        success = False
        verified = False
        result_payload = {
            "success": False,
            "verified": False,
            "error": f"{type(exc).__name__}: {exc}",
        }
    executed_action: ExecutedAction = ExecutedAction(
        tool_name=action.get("tool_name", ""),
        tool_args=dict(action.get("tool_args", {})),
        tool_call_id=f"call_{uuid4().hex}",
        result=result_payload,
        success=success,
        executed_at=_utc_now(),
        verification_passed=verified,
    )
    return {
        "executed_actions": list(state.get("executed_actions", [])) + [executed_action],
        "current_phase": PHASE_VERIFY,
    }


async def verify_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Verify remediation result and decide whether to retry or complete.

    Routes back to PROPOSE on failure for retry (up to MAX_REMEDIATION_ATTEMPTS).
    Transitions to COMPLETE on success or when retry limit is reached.
    """
    del config
    executed_actions = state.get("executed_actions", [])
    if not executed_actions:
        return {"current_phase": PHASE_COMPLETE}
    last = executed_actions[-1]
    success = bool(last.get("success", False))
    verified = bool(last.get("verification_passed", False))
    if success and verified:
        logger.info("Action verified successfully")
        return {"current_phase": PHASE_COMPLETE}
    if len(executed_actions) >= MAX_REMEDIATION_ATTEMPTS:
        logger.warning(
            "MAX_REMEDIATION_ATTEMPTS (%d) reached, completing without resolution",
            MAX_REMEDIATION_ATTEMPTS,
        )
        return {"current_phase": PHASE_COMPLETE}
    logger.warning(
        "Action not verified (attempt %d/%d); re-proposing",
        len(executed_actions),
        MAX_REMEDIATION_ATTEMPTS,
    )
    return {
        "current_phase": PHASE_PROPOSE,
        "iteration_count": state.get("iteration_count", 0) + 1,
        "consecutive_tool_failures": state.get("consecutive_tool_failures", 0),
    }


async def complete_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Terminal node: log final metrics and set wall_clock_seconds."""
    del config
    started_at = state.get("started_at")
    wall_clock = time.monotonic() - started_at if started_at is not None else 0.0
    logger.info(
        "Investigation complete: %d proposed, %d executed, %d tokens, $%.4f, %.2fs",
        len(state.get("proposed_actions", [])),
        len(state.get("executed_actions", [])),
        state.get("tokens_used", 0),
        state.get("cost_usd", 0.0),
        wall_clock,
    )
    return {"current_phase": PHASE_COMPLETE, "wall_clock_seconds": round(wall_clock, 2)}


# ---------------------------------------------------------------------------
# Routing functions
# ---------------------------------------------------------------------------

PhaseLiteral = Literal[
    "triage", "investigate", "hypothesize", "propose", "approve", "execute", "verify", "complete"
]


def route_initial_phase(state: AgentState) -> PhaseLiteral:
    """Route to the current phase or default to triage."""
    phase = state.get("current_phase", PHASE_TRIAGE)
    return cast(PhaseLiteral, phase) if phase in PHASES else cast(PhaseLiteral, PHASE_TRIAGE)


def route_after_hypothesize(state: AgentState) -> Literal["investigate", "propose", "complete"]:
    """Route based on hypothesis confidence and iteration count."""
    hypotheses = state.get("hypotheses", [])
    if not hypotheses:
        return "complete"
    if is_high_confidence(hypotheses) or state.get("iteration_count", 0) >= MAX_ITERATIONS:
        return "propose"
    return "investigate"


def route_after_propose(state: AgentState) -> Literal["approve", "execute", "complete"]:
    """Route based on risk tier: Tier-2+ goes to approve, Tier-1 goes to execute."""
    actions = state.get("proposed_actions", [])
    if not actions:
        return "complete"
    return "approve" if int(actions[-1].get("risk_tier", 1)) >= 2 else "execute"


def route_after_approval(state: AgentState) -> Literal["execute", "complete"]:
    """Route based on approval decision."""
    return "execute" if state.get("approval_granted") is True else "complete"


def route_after_verify(state: AgentState) -> Literal["complete", "propose"]:
    """Route based on verification result and retry limit.

    Respects MAX_REMEDIATION_ATTEMPTS to prevent infinite retry loops.
    """
    actions = state.get("executed_actions", [])
    if not actions:
        return "complete"
    last = actions[-1]
    if last.get("success") and last.get("verification_passed"):
        return "complete"
    # Hard cap: stop retrying after MAX_REMEDIATION_ATTEMPTS failures
    if len(actions) >= MAX_REMEDIATION_ATTEMPTS:
        return "complete"
    return "propose"
