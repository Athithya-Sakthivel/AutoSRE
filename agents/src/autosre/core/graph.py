"""LangGraph orchestration for autonomous SRE investigations.

This module only constructs and compiles the StateGraph. All node logic
lives in ``graph_nodes`` and all helpers live in ``graph_helpers``.
"""

from __future__ import annotations

from typing import Any

from langgraph.graph import END, START, StateGraph

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


def build_investigation_graph() -> StateGraph[AgentState]:
    """Build the LangGraph StateGraph."""
    graph: StateGraph[AgentState] = StateGraph(AgentState)

    graph.add_node(PHASE_TRIAGE, triage_node)
    graph.add_node(PHASE_INVESTIGATE, investigate_node)
    graph.add_node(PHASE_HYPOTHESIZE, hypothesize_node)
    graph.add_node(PHASE_PROPOSE, propose_node)
    graph.add_node(PHASE_APPROVE, approve_node)
    graph.add_node(PHASE_EXECUTE, execute_node)
    graph.add_node(PHASE_VERIFY, verify_node)
    graph.add_node(PHASE_COMPLETE, complete_node)

    graph.add_conditional_edges(
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

    graph.add_edge(PHASE_TRIAGE, PHASE_INVESTIGATE)
    graph.add_edge(PHASE_INVESTIGATE, PHASE_HYPOTHESIZE)

    graph.add_conditional_edges(
        PHASE_HYPOTHESIZE,
        route_after_hypothesize,
        {
            "investigate": PHASE_INVESTIGATE,
            "propose": PHASE_PROPOSE,
            "complete": PHASE_COMPLETE,
        },
    )

    graph.add_conditional_edges(
        PHASE_PROPOSE,
        route_after_propose,
        {
            "approve": PHASE_APPROVE,
            "execute": PHASE_EXECUTE,
            "complete": PHASE_COMPLETE,
        },
    )

    graph.add_conditional_edges(
        PHASE_APPROVE,
        route_after_approval,
        {
            "execute": PHASE_EXECUTE,
            "complete": PHASE_COMPLETE,
        },
    )

    graph.add_edge(PHASE_EXECUTE, PHASE_VERIFY)

    graph.add_conditional_edges(
        PHASE_VERIFY,
        route_after_verify,
        {
            "complete": PHASE_COMPLETE,
            "investigate": PHASE_INVESTIGATE,
        },
    )

    graph.add_edge(PHASE_COMPLETE, END)

    return graph


def compile_graph(checkpointer: Any = None) -> Any:
    """Compile the investigation graph.

    For HITL/interrupt behavior a checkpointer is mandatory. Production
    async deployments should use ``AsyncPostgresSaver``; tests can use
    ``InMemorySaver``.
    """
    return build_investigation_graph().compile(checkpointer=checkpointer)
