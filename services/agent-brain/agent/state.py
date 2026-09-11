"""Agent state definition with idempotency flags."""

from __future__ import annotations

from typing import Any, Literal, TypedDict

AlertStatus = Literal[
    "new",
    "rate_limited",
    "triaged",
    "investigating",
    "root_caused",
    "fix_generated",
    "awaiting_human",
    "approved",
    "rejected",
    "executing",
    "waiting_for_deploy",
    "verifying",
    "resolved",
    "escalated",
    "aborted",
    "error",
]

Severity = Literal["debug", "info", "warning", "error", "critical"]


class AlertPayload(TypedDict, total=False):
    id: str
    name: str
    resource: str
    resource_id: str
    severity: str
    description: str
    summary: str
    message: str
    region: str
    subscription_id: str
    subscription_name: str
    resource_group: str
    timestamp: str
    fired_at: str
    started_at: str
    custom_properties: dict[str, Any]
    dimensions: dict[str, Any]


class TraceRecord(TypedDict, total=False):
    timestamp: str
    severity: str
    service_name: str
    message: str
    exception_type: str
    stack_trace: str
    raw: dict[str, Any]


class LogRecord(TypedDict, total=False):
    timestamp: str
    severity: str
    service_name: str
    message: str
    raw: dict[str, Any]


class CodeSnippet(TypedDict, total=False):
    file_path: str
    line_start: int
    line_end: int
    content: str
    numbered_lines: str


class ProposedAction(TypedDict, total=False):
    tool_name: str
    args: dict[str, Any]
    rationale: str


class SREState(TypedDict, total=False):
    # Incoming alert and identity
    alert: AlertPayload
    alert_id: str
    thread_id: str
    service_name: str
    resource_id: str
    severity: Severity
    status: AlertStatus

    # Rate limiting and timing
    rate_limit_count: int
    rate_limit_threshold: int
    rate_limited: bool
    retry_count: int
    max_retries: int
    started_at: str
    updated_at: str

    # Investigation and root cause analysis
    investigation_logs: list[str]
    trace_records: list[TraceRecord]
    log_records: list[LogRecord]
    suspected_file_path: str
    suspected_line_number: int
    suspected_commit: str
    code_snippet: CodeSnippet

    # Fix generation and human review
    proposed_action: ProposedAction
    fix_confidence: float
    approval_status: Literal["pending", "approved", "rejected", "not_required"]
    human_decision: Literal["pending", "approved", "rejected"]

    # Execution and verification
    execution_result: dict[str, Any]
    verification_result: dict[str, Any]
    error_resolved: bool

    # Operational metadata
    last_error_message: str
    notes: list[str]
    telemetry_span_id: str
    telemetry_trace_id: str

    # Idempotency flags – set by each node after successful completion
    rate_limit_checked: bool
    triage_done: bool
    investigation_done: bool
    root_cause_done: bool
    fix_generated_done: bool
    execution_done: bool
    wait_deploy_done: bool


__all__ = [
    "AlertPayload",
    "AlertStatus",
    "CodeSnippet",
    "LogRecord",
    "ProposedAction",
    "SREState",
    "Severity",
    "TraceRecord",
]
