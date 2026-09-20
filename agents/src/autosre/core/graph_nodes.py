"""Graph node functions and routing functions.

Each node takes ``(state, config)`` per the LangGraph 1.2.11 contract.
Dependencies are extracted from ``config["configurable"]`` via the
``GraphContext`` dataclass defined in ``graph_helpers``.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any, Literal, cast
from uuid import uuid4

from langchain_core.runnables import RunnableConfig

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


def _utc_now() -> str:
    """Return the current UTC time as an ISO 8601 string."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _get_sre_context(config: RunnableConfig) -> SREContext:
    """Extract SREContext from config, raising if missing."""
    sre_context = config.get("configurable", {}).get("sre_context")
    if sre_context is None:
        raise ValueError("SREContext must be provided in config['configurable']['sre_context']")
    if not isinstance(sre_context, SREContext):
        raise TypeError(f"Expected SREContext, got {type(sre_context).__name__}")
    return sre_context


# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------


async def triage_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Analyze the alert and initialize root-cause hypotheses."""
    ctx = get_graph_context(config)
    metadata = state["incident_metadata"]

    logger.info("Triage node: analyzing alert %s", metadata["alert_name"])

    prompt = f"""You are an SRE investigation coordinator.

Alert:
- Name: {metadata["alert_name"]}
- Service: {metadata["service"]}
- Namespace: {metadata["namespace"]}
- Severity: {metadata["severity"]}
- Started: {metadata["started_at"]}

Available investigation tools are supplied by the tool registry at runtime.

Return JSON only with this exact structure:
{{
  "hypotheses": [
    {{
      "id": "H1",
      "description": "...",
      "confidence": 0.0,
      "evidence": []
    }}
  ]
}}

Provide 2-3 plausible root-cause hypotheses.
Confidence must be between 0 and 1.
"""

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.3,
            )
        )
        payload = parse_json_response(response, stage="triage")
        hypotheses = normalize_hypotheses(payload.get("hypotheses"), default_status="proposed")
    except (AttributeError, TypeError, ValueError) as exc:
        logger.warning("Triage response could not be parsed: %s", exc)
        hypotheses = [
            Hypothesis(
                id="H1",
                description=(
                    f"Investigate the root cause of alert "
                    f"{metadata['alert_name']} for service "
                    f"{metadata['service']}"
                ),
                confidence=0.2,
                evidence=[f"Alert: {metadata['alert_name']}"],
                status="proposed",
            )
        ]

    return {
        "hypotheses": hypotheses,
        "current_phase": PHASE_INVESTIGATE,
        "iteration_count": state.get("iteration_count", 0),
    }


async def investigate_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Choose and execute one read-only investigation tool."""
    ctx = get_graph_context(config)
    iteration = state.get("iteration_count", 0) + 1

    logger.info("Investigate node: iteration %d", iteration)

    if iteration > MAX_ITERATIONS:
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
        }

    hypotheses = state.get("hypotheses", [])
    if not hypotheses:
        logger.warning("No hypotheses are available for investigation")
        return {
            "current_phase": PHASE_COMPLETE,
            "iteration_count": iteration,
        }

    try:
        specs = await list_tool_specs(ctx.registry)
    except Exception:
        logger.exception("Unable to enumerate investigation tools")
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
        }

    investigation_specs = [
        spec
        for spec in specs
        if (
            spec.get("risk_tier") == 0
            or (spec.get("risk_tier") is None and spec.get("name") in READ_ONLY_TOOL_NAMES)
        )
    ]

    if not investigation_specs:
        logger.warning("No read-only investigation tools are available")
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
        }

    hypothesis_text = "\n".join(
        f"- {h['id']}: {h['description']} (confidence={h['confidence']})" for h in hypotheses
    )

    tool_text = "\n".join(
        f"- {spec['name']}: {spec['description']}" for spec in investigation_specs
    )

    prompt = f"""You are investigating an active SRE incident.

Hypotheses:
{hypothesis_text}

Available read-only investigation tools:
{tool_text}

Select exactly one read-only tool call that gathers evidence.
Do not propose remediation.

Return JSON only:
{{
  "tool_name": "...",
  "tool_args": {{}},
  "rationale": "..."
}}
"""

    selected_name: str | None = None
    tool_args: dict[str, Any] = {}
    rationale = "No rationale supplied"

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.2,
            )
        )
        payload = parse_json_response(response, stage="investigation")

        raw_name = payload.get("tool_name")
        raw_args = payload.get("tool_args", {})

        if raw_name is not None:
            selected_name = str(raw_name).strip() or None

        if not isinstance(raw_args, Mapping):
            raise ValueError("tool_args must be an object")

        tool_args = dict(raw_args)
        rationale = str(payload.get("rationale", rationale)).strip() or rationale

    except (AttributeError, TypeError, ValueError) as exc:
        logger.warning("Investigation tool selection failed: %s", exc)

    selected_spec = find_tool(investigation_specs, selected_name) if selected_name else None

    if selected_spec is None:
        logger.warning("No valid read-only investigation tool was selected")
        return {
            "current_phase": PHASE_HYPOTHESIZE,
            "iteration_count": iteration,
        }

    # Narrow selected_name from str | None to str (guarded by find_tool above)
    assert selected_name is not None, (
        "selected_name must be non-None when selected_spec is not None"
    )

    investigation_action: ProposedAction = ProposedAction(
        tool_name=selected_name,
        tool_args=tool_args,
        risk_tier=0,
        rationale=rationale,
        requires_approval=False,
    )

    sre_context = _get_sre_context(config)

    evidence_line = ""
    try:
        exec_result: ExecutionResult = await ctx.executor.execute(investigation_action, sre_context)
        success = exec_result.executed and exec_result.error is None
        verified = exec_result.verified
        result_payload: dict[str, Any] = exec_result.output or {}

        evidence_line = (
            f"Tool {selected_name} returned "
            f"success={success}, verified={verified}: "
            f"{safe_json(result_payload)}"
        )
    except Exception as exc:
        logger.exception("Investigation tool execution failed")
        evidence_line = f"Tool {selected_name} execution failed: {type(exc).__name__}: {exc}"

    updated_hypotheses: list[Hypothesis] = []
    for h in hypotheses:
        updated_h = dict(h)
        evidence_list_raw = updated_h.get("evidence", [])
        evidence_list: list[str] = (
            list(cast(list[str], evidence_list_raw)) if isinstance(evidence_list_raw, list) else []
        )
        evidence_list.append(evidence_line)
        updated_h["evidence"] = evidence_list[-20:]
        updated_hypotheses.append(cast(Hypothesis, updated_h))

    return {
        "hypotheses": updated_hypotheses,
        "current_phase": PHASE_HYPOTHESIZE,
        "iteration_count": iteration,
    }


async def hypothesize_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Refine hypotheses using evidence gathered during investigation."""
    ctx = get_graph_context(config)
    hypotheses = state.get("hypotheses", [])

    logger.info("Hypothesize node: %d hypothesis(es)", len(hypotheses))

    if not hypotheses:
        return {"current_phase": PHASE_COMPLETE}

    if is_high_confidence(hypotheses) or state.get("iteration_count", 0) >= MAX_ITERATIONS:
        return {"current_phase": PHASE_PROPOSE}

    prompt = f"""You are refining an SRE root-cause analysis.

Current hypotheses:
{json.dumps(hypotheses, default=str)}

Update confidence using only the evidence already collected.
Do not invent evidence.

Return JSON only:
{{
  "hypotheses": [
    {{
      "id": "H1",
      "description": "...",
      "confidence": 0.0,
      "evidence": [],
      "status": "proposed"
    }}
  ]
}}

A confidence of 0.8 or higher is sufficient to propose remediation.
"""

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
            )
        )
        payload = parse_json_response(response, stage="hypothesis refinement")
        refined = normalize_hypotheses(payload.get("hypotheses"), default_status="proposed")
    except (AttributeError, TypeError, ValueError) as exc:
        logger.warning("Hypothesis refinement failed; retaining current state: %s", exc)
        refined = [cast(Hypothesis, dict(h)) for h in hypotheses]

    return {
        "hypotheses": refined,
        "current_phase": (PHASE_PROPOSE if is_high_confidence(refined) else PHASE_INVESTIGATE),
    }


async def propose_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Create a registry-validated remediation proposal."""
    ctx = get_graph_context(config)
    existing_actions = state.get("proposed_actions", [])

    top = top_hypothesis(state.get("hypotheses", []))
    if top is None:
        logger.error("Cannot propose remediation without a hypothesis")
        return {"current_phase": PHASE_COMPLETE}

    try:
        specs = await list_tool_specs(ctx.registry)
    except Exception:
        logger.exception("Unable to enumerate remediation tools")
        return {"current_phase": PHASE_COMPLETE}

    available_actions = [spec for spec in specs if spec.get("name") in REMEDIATION_RISK_TIERS]

    if not available_actions:
        logger.error("No supported remediation tools are present in the registry")
        return {"current_phase": PHASE_COMPLETE}

    action_text = "\n".join(
        f"- {spec['name']}: registry_risk_tier={spec['risk_tier']}" for spec in available_actions
    )

    prompt = f"""You are proposing SRE remediation.

Root-cause hypothesis:
{top["description"]}

Confidence: {top["confidence"]}

Evidence:
{json.dumps(top.get("evidence", []), default=str)}

Supported remediation tools:
{action_text}

Return JSON only:
{{
  "tool_name": "...",
  "tool_args": {{}},
  "risk_tier": 1,
  "rationale": "..."
}}

Never claim a lower risk tier than the registry or policy baseline.
"""

    try:
        response = await maybe_await(
            ctx.llm_router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": prompt}],
                temperature=0.2,
            )
        )
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

    except (AttributeError, TypeError, ValueError) as exc:
        logger.error("Invalid remediation proposal: %s", exc)
        return {"current_phase": PHASE_COMPLETE}

    proposed_action: ProposedAction = ProposedAction(
        tool_name=tool_name_raw,
        tool_args=dict(raw_args),
        risk_tier=effective_tier,
        rationale=rationale,
        requires_approval=effective_tier >= 2,
    )

    return {
        "proposed_actions": list(existing_actions) + [proposed_action],
        "current_phase": (PHASE_APPROVE if effective_tier >= 2 else PHASE_EXECUTE),
        "requires_human_approval": effective_tier >= 2,
        "approval_granted": None,
    }


async def approve_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Pause for human approval of a Tier-2+ action.

    Uses langgraph.types.interrupt() to pause the graph. When resumed,
    this node re-executes and interrupt() returns the resume value.
    """
    from langgraph.types import interrupt

    del config  # not used in this node

    proposed_actions = state.get("proposed_actions", [])

    if not proposed_actions:
        logger.error("Approval requested with no proposed action")
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
            "message": (
                "Human approval is required before executing this "
                f"Tier-{risk_tier} action. "
                f"Rationale: {action.get('rationale', '')}"
            ),
        }
    )

    approved = approval_value_to_bool(response)

    if not approved:
        logger.info("Human rejected action %s", action.get("tool_name"))
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
    """Execute the latest proposal through SafeExecutor."""
    ctx = get_graph_context(config)
    proposed_actions = state.get("proposed_actions", [])

    if not proposed_actions:
        logger.error("Execute node entered without a proposed action")
        return {"current_phase": PHASE_COMPLETE}

    action = proposed_actions[-1]
    logger.info("Executing action %s", action.get("tool_name"))

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
    """Verify the SafeExecutor result and choose completion or investigation."""
    del config  # not used in this node

    executed_actions = state.get("executed_actions", [])

    if not executed_actions:
        return {"current_phase": PHASE_COMPLETE}

    last_action = executed_actions[-1]
    success = bool(last_action.get("success", False))
    verification_passed = bool(last_action.get("verification_passed", False))

    if success and verification_passed:
        logger.info("Action verified successfully")
        return {"current_phase": PHASE_COMPLETE}

    logger.warning("Action was not verified; returning to investigation")
    return {"current_phase": PHASE_INVESTIGATE}


async def complete_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
    """Finalize the investigation state."""
    del config  # not used in this node

    logger.info(
        "Investigation complete: %d proposed, %d executed action(s)",
        len(state.get("proposed_actions", [])),
        len(state.get("executed_actions", [])),
    )
    return {"current_phase": PHASE_COMPLETE}


# ---------------------------------------------------------------------------
# Routing functions
# ---------------------------------------------------------------------------

PhaseLiteral = Literal[
    "triage",
    "investigate",
    "hypothesize",
    "propose",
    "approve",
    "execute",
    "verify",
    "complete",
]


def route_initial_phase(state: AgentState) -> PhaseLiteral:
    """Route a supplied state to its current phase."""
    phase = state.get("current_phase", PHASE_TRIAGE)
    if phase in PHASES:
        return cast(PhaseLiteral, phase)
    return cast(PhaseLiteral, PHASE_TRIAGE)


def route_after_hypothesize(
    state: AgentState,
) -> Literal["investigate", "propose", "complete"]:
    """Route after hypothesis refinement."""
    hypotheses = state.get("hypotheses", [])
    if not hypotheses:
        return "complete"
    if is_high_confidence(hypotheses) or state.get("iteration_count", 0) >= MAX_ITERATIONS:
        return "propose"
    return "investigate"


def route_after_propose(
    state: AgentState,
) -> Literal["approve", "execute", "complete"]:
    """Route based on the effective action risk tier."""
    actions = state.get("proposed_actions", [])
    if not actions:
        return "complete"
    return "approve" if int(actions[-1].get("risk_tier", 1)) >= 2 else "execute"


def route_after_approval(
    state: AgentState,
) -> Literal["execute", "complete"]:
    """Route after the human approval decision."""
    return "execute" if state.get("approval_granted") is True else "complete"


def route_after_verify(
    state: AgentState,
) -> Literal["complete", "investigate"]:
    """Route after execution verification."""
    actions = state.get("executed_actions", [])
    if actions and actions[-1].get("success") and actions[-1].get("verification_passed"):
        return "complete"
    return "investigate"
