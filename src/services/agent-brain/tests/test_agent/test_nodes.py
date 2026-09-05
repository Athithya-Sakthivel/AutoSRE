"""Unit tests for each workflow node – idempotency and state changes."""

from __future__ import annotations

import pytest
from agent.nodes import (
    execute_node,
    generate_fix_node,
    identify_root_cause_node,
    investigate_node,
    rate_limit_check_node,
    triage_node,
    verify_node,
    wait_for_deploy_node,
)


# ── Rate Limit Check ────────────────────────────────────────
@pytest.mark.asyncio
async def test_rate_limit_check_allowed(base_state, mocker):
    mocker.patch(
        "agent.nodes.async_check_rate_limit",
        return_value=mocker.Mock(allowed=True, count=1, threshold=10),
    )
    state = base_state
    result = await rate_limit_check_node(state)
    assert result["rate_limited"] is False
    assert result["status"] == "new"
    assert result["rate_limit_checked"] is True


@pytest.mark.asyncio
async def test_rate_limit_check_blocked(base_state, mocker):
    mocker.patch(
        "agent.nodes.async_check_rate_limit",
        return_value=mocker.Mock(allowed=False, count=11, threshold=10),
    )
    result = await rate_limit_check_node(base_state)
    assert result["rate_limited"] is True
    assert result["status"] == "rate_limited"


@pytest.mark.asyncio
async def test_rate_limit_check_idempotent(base_state, mocker):
    base_state["rate_limit_checked"] = True
    base_state["rate_limited"] = False
    # patch the helper to ensure it is NOT called
    mock_check = mocker.patch("agent.nodes.async_check_rate_limit")
    result = await rate_limit_check_node(base_state)
    mock_check.assert_not_called()
    assert result == base_state  # unchanged


# ── Triage ─────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_triage_success(base_state, mocker):
    mock_triage = mocker.patch(
        "agent.nodes.triage",
        return_value={
            "service_name": "svc-1",
            "resource_id": "res-1",
            "severity": "critical",
            "status": "triaged",
            "summary": "issue found",
        },
    )
    result = await triage_node(base_state)
    assert result["status"] == "triaged"
    assert result["triage_done"] is True
    assert result["service_name"] == "svc-1"
    mock_triage.assert_awaited_once()


@pytest.mark.asyncio
async def test_triage_idempotent(base_state, mocker):
    base_state["triage_done"] = True
    mock_triage = mocker.patch("agent.nodes.triage")
    result = await triage_node(base_state)
    mock_triage.assert_not_called()
    assert result == base_state


@pytest.mark.asyncio
async def test_triage_error_sets_error_status(base_state, mocker):
    mocker.patch("agent.nodes.triage", side_effect=Exception("LLM down"))
    result = await triage_node(base_state)
    assert result["status"] == "error"
    assert "LLM down" in result["last_error_message"]


# ── Investigate ────────────────────────────────────────────
@pytest.mark.asyncio
async def test_investigate_success(base_state, mocker):
    mocker.patch(
        "agent.nodes.async_query_traces",
        return_value=[
            {"message": "trace1"},
            {"message": "trace2"},
        ],
    )
    result = await investigate_node(base_state)
    assert result["investigation_done"] is True
    assert len(result["trace_records"]) == 2


@pytest.mark.asyncio
async def test_investigate_idempotent(base_state, mocker):
    base_state["investigation_done"] = True
    mock_traces = mocker.patch("agent.nodes.async_query_traces")
    result = await investigate_node(base_state)
    mock_traces.assert_not_called()
    assert result == base_state


@pytest.mark.asyncio
async def test_investigate_fallback_to_logs(base_state, mocker):
    mocker.patch("agent.nodes.async_query_traces", return_value=[])
    mock_logs = mocker.patch("agent.nodes.async_query_logs", return_value=[{"message": "log line"}])
    result = await investigate_node(base_state)
    assert len(result["log_records"]) == 1
    mock_logs.assert_awaited_once()


# ── Identify Root Cause ────────────────────────────────────
@pytest.mark.asyncio
async def test_identify_root_cause_with_location(base_state, mocker):
    mocker.patch("agent.nodes.extract_location", return_value=("src/main.py", 42))
    mocker.patch("agent.nodes.async_git_blame", return_value={"commit_sha": "abc123"})
    mocker.patch("agent.nodes.async_get_code_snippet", return_value={"content": "x=1"})
    base_state["trace_records"] = [{"message": "error at src/main.py:42"}]
    result = await identify_root_cause_node(base_state)
    assert result["suspected_file_path"] == "src/main.py"
    assert result["suspected_line_number"] == 42
    assert result["suspected_commit"] == "abc123"
    assert result["root_cause_done"] is True


@pytest.mark.asyncio
async def test_identify_root_cause_no_location(base_state, mocker):
    mocker.patch("agent.nodes.extract_location", return_value=None)
    result = await identify_root_cause_node(base_state)
    assert result["suspected_file_path"] == ""
    assert result["root_cause_done"] is True


@pytest.mark.asyncio
async def test_identify_root_cause_idempotent(base_state, mocker):
    base_state["root_cause_done"] = True
    mock_extract = mocker.patch("agent.nodes.extract_location")
    result = await identify_root_cause_node(base_state)
    mock_extract.assert_not_called()
    assert result == base_state


# ── Generate Fix ───────────────────────────────────────────
@pytest.mark.asyncio
async def test_generate_fix_with_llm(base_state, mocker):
    mocker.patch(
        "agent.nodes.generate_fix",
        return_value={
            "proposed_action": {
                "tool_name": "restart_aca_revision",
                "args": {"service_name": "svc"},
            },
            "fix_confidence": 0.95,
            "rationale": "safe restart",
        },
    )
    result = await generate_fix_node(base_state)
    assert result["proposed_action"]["tool_name"] == "restart_aca_revision"
    assert result["fix_confidence"] == 0.95
    assert result["fix_generated_done"] is True


@pytest.mark.asyncio
async def test_generate_fix_fallback_to_default(base_state, mocker):
    mocker.patch(
        "agent.nodes.generate_fix",
        return_value={
            "proposed_action": {},
            "fix_confidence": 0.2,
        },
    )
    result = await generate_fix_node(base_state)
    # default_action returns empty tool if no keywords, which triggers escalation later
    assert result["proposed_action"]["tool_name"] == ""


@pytest.mark.asyncio
async def test_generate_fix_idempotent(base_state, mocker):
    base_state["fix_generated_done"] = True
    mock_fix = mocker.patch("agent.nodes.generate_fix")
    result = await generate_fix_node(base_state)
    mock_fix.assert_not_called()
    assert result == base_state


# ── Execute ────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_execute_restart(base_state, mocker):
    base_state["proposed_action"] = {
        "tool_name": "restart_aca_revision",
        "args": {"service_name": "target-system"},
    }
    mock_restart = mocker.patch(
        "agent.nodes.async_restart_aca_revision", return_value={"message": "ok"}
    )
    result = await execute_node(base_state)
    assert result["execution_done"] is True
    assert "ok" in str(result["execution_result"])
    mock_restart.assert_awaited_once_with(service_name="target-system")


@pytest.mark.asyncio
async def test_execute_unsupported_tool_sets_error(base_state, mocker):
    base_state["proposed_action"] = {
        "tool_name": "unknown_tool",
        "args": {},
    }
    result = await execute_node(base_state)
    assert result["status"] == "error"
    assert "Unsupported tool" in result["last_error_message"]


@pytest.mark.asyncio
async def test_execute_idempotent(base_state, mocker):
    base_state["execution_done"] = True
    mock_restart = mocker.patch("agent.nodes.async_restart_aca_revision")
    result = await execute_node(base_state)
    mock_restart.assert_not_called()
    assert result == base_state


# ── Wait for Deploy ─────────────────────────────────────────
@pytest.mark.asyncio
async def test_wait_for_deploy(base_state, mocker):
    mocker.patch("agent.nodes.asyncio.sleep")
    result = await wait_for_deploy_node(base_state)
    assert result["wait_deploy_done"] is True
    assert result["status"] == "waiting_for_deploy"


@pytest.mark.asyncio
async def test_wait_for_deploy_idempotent(base_state, mocker):
    base_state["wait_deploy_done"] = True
    mock_sleep = mocker.patch("agent.nodes.asyncio.sleep")
    result = await wait_for_deploy_node(base_state)
    mock_sleep.assert_not_called()
    assert result == base_state


# ── Verify ─────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_verify_resolved(base_state, mocker):
    mocker.patch("agent.nodes.async_query_traces", return_value=[{"msg": "ok"}])
    mocker.patch("agent.nodes.verify", return_value={"error_resolved": True})
    result = await verify_node(base_state)
    assert result["error_resolved"] is True
    assert result["status"] == "resolved"


@pytest.mark.asyncio
async def test_verify_not_resolved_increments_retry(base_state, mocker):
    mocker.patch("agent.nodes.async_query_traces", return_value=[{"msg": "error"}])
    mocker.patch("agent.nodes.verify", return_value={"error_resolved": False})
    result = await verify_node(base_state)
    assert result["error_resolved"] is False
    assert result["retry_count"] == 1
