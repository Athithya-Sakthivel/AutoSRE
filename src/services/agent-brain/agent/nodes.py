"""Workflow node implementations – idempotent, error‑resilient."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping
from typing import Any

from infra.config import load_settings
from infra.ws import manager
from langgraph.types import interrupt

from agent.llm import generate_fix, triage, verify
from agent.rate_limiter import async_check_rate_limit
from agent.tools_client import (
    MCPToolsError,
    async_create_pr,
    async_get_code_snippet,
    async_git_blame,
    async_query_logs,
    async_query_traces,
    async_restart_aca_revision,
)
from agent.workflow_helpers import (
    base_alert_payload,
    default_action,
    ensure_list,
    extract_location,
    flatten_text_blobs,
    merge_notes,
    now_iso,
    parse_jsonish,
    textify,
)

logger = logging.getLogger(__name__)

VERIFY_LOOKBACK_MINUTES = 15


async def rate_limit_check_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("rate_limit_checked"):
        return state
    try:
        settings = load_settings()
        alert = base_alert_payload(state)
        resource_id = str(
            state.get("resource_id")
            or alert.get("resource_id")
            or alert.get("resource")
            or state.get("service_name")
            or settings.service_name
        )
        decision = await async_check_rate_limit(resource_id)
        state["resource_id"] = resource_id
        state["rate_limit_count"] = decision.count
        state["rate_limit_threshold"] = decision.threshold
        state["rate_limited"] = not decision.allowed
        state["status"] = "rate_limited" if not decision.allowed else "new"
        state["rate_limit_checked"] = True
        state["updated_at"] = now_iso()
        state["notes"] = merge_notes(
            state, f"rate_limit_check: count={decision.count}, threshold={decision.threshold}"
        )
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("rate_limit_check_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def triage_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("triage_done"):
        return state
    try:
        settings = load_settings()
        alert = base_alert_payload(state)
        triage_payload = {
            "alert": alert,
            "service_name": state.get("service_name")
            or alert.get("service_name")
            or settings.service_name,
            "resource_id": state.get("resource_id")
            or alert.get("resource_id")
            or alert.get("resource"),
            "severity": state.get("severity") or alert.get("severity"),
            "description": alert.get("description") or alert.get("summary") or alert.get("message"),
        }
        triaged = await triage(triage_payload, settings=settings)
        state["alert_id"] = str(
            state.get("alert_id") or alert.get("id") or alert.get("alert_id") or ""
        )
        state["service_name"] = str(
            triaged.get("service_name") or triage_payload["service_name"] or settings.service_name
        )
        state["resource_id"] = str(
            triaged.get("resource_id")
            or triage_payload["resource_id"]
            or state.get("service_name", "")
        )
        state["severity"] = str(triaged.get("severity") or state.get("severity") or "warning")
        state["status"] = "triaged"
        state["triage_done"] = True
        state["notes"] = merge_notes(state, f"triage: {triaged.get('summary', 'triaged')}")
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("triage_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def investigate_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("investigation_done"):
        return state
    try:
        settings = load_settings()
        service_name = str(state.get("service_name") or settings.service_name)
        traces_result = await async_query_traces(service_name, VERIFY_LOOKBACK_MINUTES)
        trace_content = parse_jsonish(traces_result)
        trace_records = ensure_list(trace_content)

        log_records = ensure_list(state.get("log_records"))
        if not trace_records or len(trace_records) < 2:
            try:
                logs_result = await async_query_logs(service_name, VERIFY_LOOKBACK_MINUTES)
                log_content = parse_jsonish(logs_result)
                log_records = ensure_list(log_content)
            except MCPToolsError as exc:
                log_records.append({"message": f"query_logs failed: {exc}"})

        investigation_logs = list(state.get("investigation_logs", []))
        investigation_logs.append(
            f"investigate: traces={len(trace_records)} logs={len(log_records)} service={service_name}"
        )

        state["trace_records"] = trace_records
        state["log_records"] = log_records
        state["investigation_logs"] = investigation_logs
        state["status"] = "investigating"
        state["investigation_done"] = True
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("investigate_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def identify_root_cause_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("root_cause_done"):
        return state
    try:
        texts = flatten_text_blobs(
            [state.get("trace_records"), state.get("log_records"), state.get("investigation_logs")]
        )
        location = extract_location(texts)
        suspected_file_path = str(state.get("suspected_file_path") or "")
        suspected_line_number = int(state.get("suspected_line_number") or 0)
        suspected_commit = str(state.get("suspected_commit") or "")
        code_snippet: dict[str, Any] = dict(state.get("code_snippet") or {})

        if location:
            suspected_file_path, suspected_line_number = location
            try:
                blame = await async_git_blame(
                    file_path=suspected_file_path, line_number=suspected_line_number
                )
                blame_content = parse_jsonish(blame)
                if isinstance(blame_content, Mapping):
                    suspected_commit = str(
                        blame_content.get("commit_sha", blame_content.get("sha", suspected_commit))
                    )
                    code_snippet.setdefault("git_blame", blame_content)
                snippet = await async_get_code_snippet(
                    file_path=suspected_file_path,
                    line_start=max(1, suspected_line_number - 12),
                    line_end=suspected_line_number + 12,
                )
                snippet_content = parse_jsonish(snippet)
                if isinstance(snippet_content, Mapping):
                    code_snippet.update(snippet_content)
                else:
                    code_snippet["content"] = textify(snippet_content)
                code_snippet.setdefault("file_path", suspected_file_path)
            except MCPToolsError as exc:
                code_snippet.setdefault("content", f"source lookup failed: {exc}")

        investigation_logs = list(state.get("investigation_logs", []))
        investigation_logs.append(
            f"root_cause: file={suspected_file_path} line={suspected_line_number} commit={suspected_commit or 'unknown'}"
        )

        state["suspected_file_path"] = suspected_file_path
        state["suspected_line_number"] = suspected_line_number
        state["suspected_commit"] = suspected_commit
        state["code_snippet"] = code_snippet
        state["investigation_logs"] = investigation_logs
        state["status"] = "root_caused"
        state["root_cause_done"] = True
        state["updated_at"] = now_iso()
        state["notes"] = merge_notes(state, "root cause identified")
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("identify_root_cause_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def generate_fix_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("fix_generated_done"):
        return state
    try:
        settings = load_settings()
        fix_payload = {
            "service_name": state.get("service_name"),
            "resource_id": state.get("resource_id"),
            "severity": state.get("severity"),
            "investigation_logs": state.get("investigation_logs", []),
            "trace_records": state.get("trace_records", []),
            "log_records": state.get("log_records", []),
            "suspected_commit": state.get("suspected_commit"),
            "suspected_file_path": state.get("suspected_file_path"),
            "suspected_line_number": state.get("suspected_line_number"),
            "code_snippet": state.get("code_snippet", {}),
        }
        fix_result = await generate_fix(fix_payload, settings=settings)
        proposed_action = (
            fix_result.get("proposed_action") if isinstance(fix_result, Mapping) else None
        )
        if not isinstance(proposed_action, Mapping) or not proposed_action.get("tool_name"):
            proposed_action = default_action(state)

        confidence_raw = (
            fix_result.get("fix_confidence") if isinstance(fix_result, Mapping) else None
        )
        try:
            fix_confidence = min(
                1.0, max(0.0, float(confidence_raw if confidence_raw is not None else 0.0))
            )
        except TypeError, ValueError:
            fix_confidence = 0.0

        state["proposed_action"] = {
            "tool_name": proposed_action.get("tool_name", ""),
            "args": dict(proposed_action.get("args", {})),
            "rationale": str(fix_result.get("rationale", "Generated by fix model")),
        }
        state["fix_confidence"] = fix_confidence
        state["status"] = "fix_generated"
        state["fix_generated_done"] = True
        state["notes"] = merge_notes(
            state,
            f"fix: tool={state['proposed_action']['tool_name']}, confidence={fix_confidence:.2f}",
        )
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("generate_fix_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def human_in_the_loop_node(state: dict[str, Any]) -> dict[str, Any]:
    # Interrupt-based – inherently idempotent, cannot be executed twice without resume.
    try:
        state["status"] = "awaiting_human"
        state["approval_status"] = "pending"
        state["human_decision"] = "pending"
        state["updated_at"] = now_iso()
        await manager.publish_state(state)

        decision = interrupt(
            {
                "thread_id": state.get("thread_id"),
                "proposed_action": state.get("proposed_action"),
                "fix_confidence": state.get("fix_confidence"),
            }
        )

        decision_value = (
            str(decision.get("decision", "")).lower() if isinstance(decision, Mapping) else ""
        )
        if decision_value == "approved":
            state["approval_status"] = "approved"
            state["human_decision"] = "approved"
            state["status"] = "approved"
        elif decision_value == "rejected":
            state["approval_status"] = "rejected"
            state["human_decision"] = "rejected"
            state["status"] = "rejected"
        else:
            state["status"] = "escalated"

        state["notes"] = merge_notes(state, f"human decision: {state['human_decision']}")
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("human_in_the_loop_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def execute_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("execution_done"):
        return state
    try:
        proposed_action = state.get("proposed_action")
        if not isinstance(proposed_action, Mapping) or not proposed_action.get("tool_name"):
            # No valid action – escalate
            state["status"] = "escalated"
            state["notes"] = merge_notes(state, "No actionable fix proposed; escalating")
            state["execution_done"] = True
            state["updated_at"] = now_iso()
            await manager.publish_state(state)
            return state

        tool_name = str(proposed_action.get("tool_name", "")).strip()
        args = dict(proposed_action.get("args", {}))
        state["status"] = "executing"
        state["updated_at"] = now_iso()
        await manager.publish_state(state)

        if tool_name == "create_pr":
            result = await async_create_pr(
                repo=str(args.get("repo", load_settings().github_repo)),
                title=str(args.get("title", "Automated fix")),
                description=str(args.get("description", "")),
                diff=str(args.get("diff", "")),
            )
        elif tool_name == "restart_aca_revision":
            result = await async_restart_aca_revision(
                service_name=str(args.get("service_name", state.get("service_name", "")))
            )
        else:
            raise ValueError(f"Unsupported tool: {tool_name}")

        state["execution_result"] = {"tool_name": tool_name, "result": parse_jsonish(result)}
        state["execution_done"] = True
        state["notes"] = merge_notes(state, f"execute: {tool_name}")
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("execute_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["execution_done"] = True  # prevent retrying the same broken action
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def wait_for_deploy_node(state: dict[str, Any]) -> dict[str, Any]:
    if state.get("wait_deploy_done"):
        return state
    try:
        settings = load_settings()
        state["status"] = "waiting_for_deploy"
        state["updated_at"] = now_iso()
        state["notes"] = merge_notes(
            state, f"waiting {settings.wait_after_deploy_seconds}s for deployment"
        )
        await manager.publish_state(state)

        if settings.wait_after_deploy_seconds > 0:
            await asyncio.sleep(settings.wait_after_deploy_seconds)

        state["wait_deploy_done"] = True
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("wait_for_deploy_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def verify_node(state: dict[str, Any]) -> dict[str, Any]:
    # Not idempotent in the sense that verification must be re-run; but we still guard against double‑counting via retry_count.
    try:
        settings = load_settings()
        service_name = str(state.get("service_name") or settings.service_name)
        traces_result = await async_query_traces(service_name, VERIFY_LOOKBACK_MINUTES)
        trace_content = parse_jsonish(traces_result)
        trace_records = ensure_list(trace_content)

        verification_payload = {
            "service_name": service_name,
            "trace_records": trace_records,
            "log_records": state.get("log_records", []),
            "previous_error_count": len(ensure_list(state.get("trace_records"))),
            "current_error_count": len(trace_records),
            "execution_result": state.get("execution_result", {}),
        }
        verify_result = await verify(verification_payload, settings=settings)
        resolved = (
            bool(verify_result.get("error_resolved"))
            if isinstance(verify_result, Mapping)
            else False
        )

        retry_count = int(state.get("retry_count", 0))
        if not resolved:
            retry_count += 1

        state["verification_result"] = (
            verify_result if isinstance(verify_result, Mapping) else {"result": verify_result}
        )
        state["trace_records"] = trace_records
        state["error_resolved"] = resolved
        state["retry_count"] = retry_count
        state["status"] = "resolved" if resolved else "verifying"
        state["notes"] = merge_notes(
            state, f"verify: resolved={resolved}, retry_count={retry_count}"
        )
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state
    except Exception as exc:
        logger.exception("verify_node failed")
        state["status"] = "error"
        state["last_error_message"] = str(exc)
        state["updated_at"] = now_iso()
        await manager.publish_state(state)
        return state


async def escalate_node(state: dict[str, Any]) -> dict[str, Any]:
    state["status"] = "escalated"
    state["notes"] = merge_notes(state, "workflow escalated to human operator")
    state["updated_at"] = now_iso()
    await manager.publish_state(state)
    await manager.publish_event(
        str(state.get("thread_id", "")), "escalated", {"reason": "max retries exceeded"}
    )
    return state


async def abort_and_notify_node(state: dict[str, Any]) -> dict[str, Any]:
    state["status"] = "aborted"
    state["notes"] = merge_notes(state, "human rejected proposed action; workflow aborted")
    state["updated_at"] = now_iso()
    await manager.publish_state(state)
    return state


__all__ = [
    "abort_and_notify_node",
    "escalate_node",
    "execute_node",
    "generate_fix_node",
    "human_in_the_loop_node",
    "identify_root_cause_node",
    "investigate_node",
    "rate_limit_check_node",
    "triage_node",
    "verify_node",
    "wait_for_deploy_node",
]
