"""LangGraph state graph compilation for the SRE investigation loop.

The graph has 8 nodes:
  triage → investigate → hypothesize → propose → approve → execute → verify → complete

Conditional edges route based on state (hypothesis confidence, risk tier,
approval result, verification result, and retry limits).
"""

from __future__ import annotations

from typing import Any

from langgraph.checkpoint.base import BaseCheckpointSaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.state import CompiledStateGraph

from autosre.core.graph_helpers import (
    PHASE_APPROVE,
    PHASE_COMPLETE,
    PHASE_EXECUTE,
    PHASE_HYPOTHESIZE,
    PHASE_INVESTIGATE,
    PHASE_PROPOSE,
    PHASE_TRIAGE,
    PHASE_VERIFY,
)
from autosre.core.graph_nodes import (
    approve_node,
    complete_node,
    execute_node,
    hypothesize_node,
    investigate_node,
    propose_node,
    route_after_approval,
    route_after_hypothesize,
    route_after_propose,
    route_after_verify,
    route_initial_phase,
    triage_node,
    verify_node,
)
from autosre.core.state import AgentState

type CompiledGraph = CompiledStateGraph[Any, Any, Any, Any]


def compile_graph(
    checkpointer: BaseCheckpointSaver[Any] | None = None,
) -> CompiledGraph:
    """Compile the SRE investigation state graph.

    Args:
        checkpointer: Optional durable LangGraph checkpointer. A checkpointer
            is required for resumable human-in-the-loop interruptions and
            durable execution across invocations.

    Returns:
        A compiled LangGraph state graph.
    """
    builder = StateGraph(AgentState)

    builder.add_node(PHASE_TRIAGE, triage_node)
    builder.add_node(PHASE_INVESTIGATE, investigate_node)
    builder.add_node(PHASE_HYPOTHESIZE, hypothesize_node)
    builder.add_node(PHASE_PROPOSE, propose_node)
    builder.add_node(PHASE_APPROVE, approve_node)
    builder.add_node(PHASE_EXECUTE, execute_node)
    builder.add_node(PHASE_VERIFY, verify_node)
    builder.add_node(PHASE_COMPLETE, complete_node)

    builder.add_conditional_edges(
        START,
        route_initial_phase,
        {
            PHASE_TRIAGE: PHASE_TRIAGE,
            PHASE_INVESTIGATE: PHASE_INVESTIGATE,
            PHASE_HYPOTHESIZE: PHASE_HYPOTHESIZE,
            PHASE_PROPOSE: PHASE_PROPOSE,
            PHASE_APPROVE: PHASE_APPROVE,
            PHASE_EXECUTE: PHASE_EXECUTE,
            PHASE_VERIFY: PHASE_VERIFY,
            PHASE_COMPLETE: PHASE_COMPLETE,
        },
    )

    builder.add_edge(PHASE_TRIAGE, PHASE_INVESTIGATE)
    builder.add_edge(PHASE_INVESTIGATE, PHASE_HYPOTHESIZE)
    builder.add_edge(PHASE_EXECUTE, PHASE_VERIFY)
    builder.add_edge(PHASE_COMPLETE, END)

    builder.add_conditional_edges(
        PHASE_HYPOTHESIZE,
        route_after_hypothesize,
        {
            "investigate": PHASE_INVESTIGATE,
            "propose": PHASE_PROPOSE,
            "complete": PHASE_COMPLETE,
        },
    )

    builder.add_conditional_edges(
        PHASE_PROPOSE,
        route_after_propose,
        {
            "approve": PHASE_APPROVE,
            "execute": PHASE_EXECUTE,
            "complete": PHASE_COMPLETE,
        },
    )

    builder.add_conditional_edges(
        PHASE_APPROVE,
        route_after_approval,
        {
            "execute": PHASE_EXECUTE,
            "complete": PHASE_COMPLETE,
        },
    )

    builder.add_conditional_edges(
        PHASE_VERIFY,
        route_after_verify,
        {
            "propose": PHASE_PROPOSE,
            "complete": PHASE_COMPLETE,
        },
    )

    # Validate graph wiring at construction time instead of first execution.
    builder.validate()

    return builder.compile(checkpointer=checkpointer)
