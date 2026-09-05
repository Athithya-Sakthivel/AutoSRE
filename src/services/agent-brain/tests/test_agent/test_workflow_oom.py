"""End‑to‑end workflow simulation – OOM incident."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from agent.graph import build_graph
from agent.state import SREState


@pytest.mark.asyncio
async def test_oom_workflow_reaches_resolved():
    # Fully mock external calls at the node level so the graph can run through
    with (
        patch(
            "agent.nodes.async_check_rate_limit",
            return_value=AsyncMock(allowed=True, count=1, threshold=10),
        ),
        patch(
            "agent.nodes.triage",
            return_value={
                "service_name": "target-svc",
                "resource_id": "r1",
                "severity": "critical",
                "summary": "OOM",
            },
        ),
        patch("agent.nodes.async_query_traces", return_value=[{"message": "OOM kill"}]),
        patch("agent.nodes.async_query_logs", return_value=[]),
        patch("agent.nodes.extract_location", return_value=("app/main.py", 10)),
        patch("agent.nodes.async_git_blame", return_value={"commit_sha": "abc"}),
        patch("agent.nodes.async_get_code_snippet", return_value={"content": "code"}),
        patch(
            "agent.nodes.generate_fix",
            return_value={
                "proposed_action": {
                    "tool_name": "restart_aca_revision",
                    "args": {"service_name": "target-svc"},
                },
                "fix_confidence": 0.9,
                "rationale": "restart",
            },
        ),
        patch("agent.nodes.async_restart_aca_revision", return_value={"message": "ok"}),
        patch("agent.nodes.verify", return_value={"error_resolved": True}),
        patch("agent.nodes.asyncio.sleep", return_value=None),  # speed up wait
    ):
        # Use a simple in‑memory checkpointer (dictionary)
        from langgraph.checkpoint.memory import MemorySaver

        checkpointer = MemorySaver()
        graph = build_graph(checkpointer)

        initial_state: SREState = {
            "alert": {"name": "OOM Test", "severity": "critical"},
            "thread_id": "oom-test",
            "service_name": "target-svc",
            "resource_id": "r1",
            "severity": "critical",
            "status": "new",
            "max_retries": 3,
        }
        final = await graph.ainvoke(
            initial_state, config={"configurable": {"thread_id": "oom-test"}}
        )
        assert final["status"] == "resolved"
        assert final["error_resolved"] is True
