"""End‑to‑end workflow simulation – database deadlock incident with retry loop."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from agent.graph import build_graph
from agent.state import SREState


@pytest.mark.asyncio
async def test_deadlock_workflow_retries_then_resolves():
    # First two verify calls report unresolved, third says resolved
    call_count = 0

    async def verify_side_effect(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return {"error_resolved": True} if call_count >= 3 else {"error_resolved": False}

    with (
        patch(
            "agent.nodes.async_check_rate_limit",
            return_value=AsyncMock(allowed=True, count=1, threshold=10),
        ),
        patch(
            "agent.nodes.triage",
            return_value={
                "service_name": "db-svc",
                "resource_id": "r2",
                "severity": "error",
                "summary": "deadlock",
            },
        ),
        patch("agent.nodes.async_query_traces", return_value=[{"message": "deadlock detected"}]),
        patch("agent.nodes.extract_location", return_value=("src/db.py", 33)),
        patch("agent.nodes.async_git_blame", return_value={"commit_sha": "def456"}),
        patch("agent.nodes.async_get_code_snippet", return_value={"content": "query"}),
        patch(
            "agent.nodes.generate_fix",
            return_value={
                "proposed_action": {
                    "tool_name": "create_pr",
                    "args": {
                        "repo": "test/repo",
                        "title": "fix deadlock",
                        "description": "...",
                        "diff": "...",
                    },
                },
                "fix_confidence": 0.85,
                "rationale": "code fix",
            },
        ),
        patch("agent.nodes.async_create_pr", return_value={"number": 1}),
        patch("agent.nodes.verify", side_effect=verify_side_effect),
        patch("agent.nodes.asyncio.sleep", return_value=None),
    ):
        from langgraph.checkpoint.memory import MemorySaver

        graph = build_graph(MemorySaver())

        initial_state: SREState = {
            "alert": {"name": "Deadlock", "severity": "error"},
            "thread_id": "deadlock-test",
            "service_name": "db-svc",
            "resource_id": "r2",
            "severity": "error",
            "status": "new",
            "max_retries": 3,
        }
        final = await graph.ainvoke(
            initial_state, config={"configurable": {"thread_id": "deadlock-test"}}
        )
        assert final["status"] == "resolved"
        assert final["retry_count"] >= 2  # at least two retries
