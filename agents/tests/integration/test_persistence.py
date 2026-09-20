"""Integration tests for durable LangGraph Postgres persistence.

This test proves that a graph can be interrupted (simulating HITL pause or
process crash), and a completely new graph instance can resume from the
exact same node using the persisted Postgres checkpoint.

Uses the LangGraph 1.2+ API where ``ainvoke`` returns normally on interrupt
and the interrupt state is inspected via ``get_state``.
"""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from typing import TypedDict

import pytest
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, interrupt
from testcontainers.community.postgres import PostgresContainer


class GraphState(TypedDict, total=False):
    """State used by the persistence recovery test."""

    step: str
    value: int
    approved: bool


@pytest.fixture(scope="session")
def postgres_container() -> Iterator[PostgresContainer]:
    """Start one isolated PostgreSQL container for the test session."""
    with PostgresContainer(
        image="postgres:16-alpine",
        dbname="autosre_test",
        username="autosre_test",
        password="autosre_test",
    ) as postgres:
        yield postgres


def postgres_dsn(postgres_container: PostgresContainer) -> str:
    """Return a psycopg-compatible DSN for the mapped Testcontainers port."""
    host = postgres_container.get_container_host_ip()
    port = postgres_container.get_exposed_port(5432)

    return f"postgresql://autosre_test:autosre_test@{host}:{port}/autosre_test"


def build_graph(
    checkpointer: AsyncPostgresSaver,
    execution_log: list[str],
) -> StateGraph:
    """Build the same logical graph against the supplied checkpointer."""

    def node_a(state: GraphState) -> GraphState:
        execution_log.append("node_a")
        return {
            "step": "a",
            "value": state.get("value", 0) + 1,
        }

    def node_b(state: GraphState) -> GraphState:
        execution_log.append("node_b")
        # Simulate HITL pause. The checkpoint is saved BEFORE the
        # interrupt blocks, so recovery can resume from here.
        approved = interrupt("waiting_for_approval")
        return {
            "step": "b",
            "value": state.get("value", 0) + 1,
            "approved": bool(approved),
        }

    def node_c(state: GraphState) -> GraphState:
        execution_log.append("node_c")
        return {
            "step": "c",
            "value": state.get("value", 0) + 1,
        }

    builder = StateGraph(GraphState)
    builder.add_node("a", node_a)
    builder.add_node("b", node_b)
    builder.add_node("c", node_c)
    builder.add_edge(START, "a")
    builder.add_edge("a", "b")
    builder.add_edge("b", "c")
    builder.add_edge("c", END)

    return builder.compile(checkpointer=checkpointer)


@pytest.mark.asyncio
async def test_graph_resumes_from_persisted_checkpoint(
    postgres_container: PostgresContainer,
) -> None:
    """Verify crash-recovery across two process lifetimes."""
    dsn = postgres_dsn(postgres_container)

    config = {
        "configurable": {
            "thread_id": "test-thread-crash-recovery",
        }
    }

    execution_log: list[str] = []

    # ==================================================================
    # First process lifetime: run the graph until it hits the interrupt.
    # ==================================================================
    async with AsyncPostgresSaver.from_conn_string(dsn) as first_checkpointer:
        await first_checkpointer.setup()

        graph = build_graph(first_checkpointer, execution_log)

        # In LangGraph 1.2+, ainvoke() returns normally when hitting an
        # interrupt — the interrupt is captured in the checkpoint state.
        result = await graph.ainvoke(
            {"value": 0},
            config,
        )

        # node_a ran, node_b started and called interrupt()
        assert execution_log == ["node_a", "node_b"]

        # Verify the graph is paused at node_b by inspecting state.
        state = await graph.aget_state(config)
        assert state.next == ("b",)  # node_b is the next node to resume

        # Verify the interrupt payload is captured
        task = state.tasks[0]
        assert task.interrupts
        assert task.interrupts[0].value == "waiting_for_approval"

    # Everything above, including the saver, is now closed. This simulates
    # a process crash. Re-open the database-backed checkpointer to prove
    # recovery does not depend on the original saver object.
    execution_log.clear()

    # Allow a brief pause to ensure the first connection is fully released.
    await asyncio.sleep(0.1)

    # ==================================================================
    # Second process lifetime: resume from the persisted checkpoint.
    # ==================================================================
    async with AsyncPostgresSaver.from_conn_string(dsn) as second_checkpointer:
        await second_checkpointer.setup()

        resumed_graph = build_graph(second_checkpointer, execution_log)

        # Resume the graph by sending a Command with the resume value.
        # This re-executes node_b from its start, with interrupt() returning
        # the resume value, then continues to node_c.
        result = await resumed_graph.ainvoke(
            Command(resume=True),
            config,
        )

    # Verify execution log: node_b re-ran (from the interrupt point),
    # then node_c executed.
    assert execution_log == ["node_b", "node_c"]

    # Verify final state
    assert result["step"] == "c"
    assert result["value"] == 3  # 0 + 1(a) + 1(b) + 1(c)
    assert result["approved"] is True

    # Verify the graph completed successfully (no next nodes)
    async with AsyncPostgresSaver.from_conn_string(dsn) as verify_checkpointer:
        verify_graph = build_graph(verify_checkpointer, [])
        final_state = await verify_graph.aget_state(config)
        assert final_state.next == ()  # Graph completed, no pending nodes
