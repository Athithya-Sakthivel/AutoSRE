"""LangGraph state graph builder – production‑ready."""

from __future__ import annotations

from typing import Any

from langgraph.checkpoint.base import BaseCheckpointSaver
from langgraph.graph import END, START, StateGraph

from agent.nodes import (
    abort_and_notify_node,
    escalate_node,
    execute_node,
    generate_fix_node,
    human_in_the_loop_node,
    identify_root_cause_node,
    investigate_node,
    rate_limit_check_node,
    triage_node,
    verify_node,
    wait_for_deploy_node,
)
from agent.state import SREState


def _route_after_rate_limit(state: dict[str, Any]) -> str:
    return END if state.get("rate_limited") else "triage"


def _route_after_generate_fix(state: dict[str, Any]) -> str:
    try:
        confidence = float(state.get("fix_confidence", 0.0))
    except TypeError, ValueError:
        confidence = 0.0
    return "human_in_the_loop" if confidence >= 0.8 else "escalate"


def _route_after_human(state: dict[str, Any]) -> str:
    decision = str(state.get("human_decision", "")).lower()
    if decision == "approved":
        return "execute"
    if decision == "rejected":
        return "abort_and_notify"
    return "escalate"


def _route_after_verify(state: dict[str, Any]) -> str:
    if state.get("error_resolved"):
        return END
    retry_count = int(state.get("retry_count", 0))
    max_retries = int(state.get("max_retries", 3))
    return "investigate" if retry_count < max_retries else "escalate"


def build_graph(checkpointer: BaseCheckpointSaver, *, debug: bool = False) -> Any:
    """Compile and return the agent‑brain workflow graph."""
    builder = StateGraph(SREState)

    builder.add_node("rate_limit_check", rate_limit_check_node)
    builder.add_node("triage", triage_node)
    builder.add_node("investigate", investigate_node)
    builder.add_node("identify_root_cause", identify_root_cause_node)
    builder.add_node("generate_fix", generate_fix_node)
    builder.add_node("human_in_the_loop", human_in_the_loop_node)
    builder.add_node("execute", execute_node)
    builder.add_node("wait_for_deploy", wait_for_deploy_node)
    builder.add_node("verify", verify_node)
    builder.add_node("escalate", escalate_node)
    builder.add_node("abort_and_notify", abort_and_notify_node)

    builder.add_edge(START, "rate_limit_check")
    builder.add_conditional_edges(
        "rate_limit_check", _route_after_rate_limit, {"triage": "triage", END: END}
    )
    builder.add_edge("triage", "investigate")
    builder.add_edge("investigate", "identify_root_cause")
    builder.add_edge("identify_root_cause", "generate_fix")
    builder.add_conditional_edges(
        "generate_fix",
        _route_after_generate_fix,
        {"human_in_the_loop": "human_in_the_loop", "escalate": "escalate"},
    )
    builder.add_conditional_edges(
        "human_in_the_loop",
        _route_after_human,
        {"execute": "execute", "abort_and_notify": "abort_and_notify", "escalate": "escalate"},
    )
    builder.add_edge("execute", "wait_for_deploy")
    builder.add_edge("wait_for_deploy", "verify")
    builder.add_conditional_edges(
        "verify",
        _route_after_verify,
        {"investigate": "investigate", "escalate": "escalate", END: END},
    )
    builder.add_edge("escalate", END)
    builder.add_edge("abort_and_notify", END)

    return builder.compile(checkpointer=checkpointer, debug=debug, name="agent_brain_workflow")


__all__ = ["build_graph"]
