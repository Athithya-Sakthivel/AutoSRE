"""Mock tool implementations for local development.
Each function matches the signature of its production counterpart exactly.
"""

from __future__ import annotations

from typing import Any


async def query_traces(
    service_name: str, time_range_minutes: int = 30, limit: int = 25
) -> dict[str, Any]:
    if time_range_minutes <= 0:
        raise ValueError("time_range_minutes must be > 0")
    if limit <= 0:
        raise ValueError("limit must be > 0")
    return {
        "service_name": service_name,
        "time_range_minutes": time_range_minutes,
        "limit": limit,
        "count": 2,
        "rows": [
            {
                "timestamp": "2026-07-13T14:25:01Z",
                "message": "NullPointerException: IncidentService.java:42",
                "type": "AppExceptions",
                "severity_level": 3,
                "operation_name": "",
                "operation_id": "abc-123",
                "parent_id": "",
                "app_role_name": service_name,
                "app_role_instance": "target-system-abc",
                "resource_id": "",
                "properties": '{"error":"null pointer"}',
                "measurements": None,
                "item_count": 1,
            },
            {
                "timestamp": "2026-07-13T14:25:03Z",
                "message": "Timeout: calls to OpenAI API",
                "type": "AppTraces",
                "severity_level": 2,
                "operation_name": "api.process",
                "operation_id": "def-456",
                "parent_id": "",
                "app_role_name": service_name,
                "app_role_instance": "target-system-abc",
                "resource_id": "",
                "properties": "{}",
                "measurements": None,
                "item_count": 1,
            },
        ],
        "queried_at": "2026-07-13T14:26:00Z",
    }


async def query_logs(
    service_name: str, time_range_minutes: int = 30, limit: int = 25
) -> dict[str, Any]:
    if time_range_minutes <= 0:
        raise ValueError("time_range_minutes must be > 0")
    if limit <= 0:
        raise ValueError("limit must be > 0")
    return {
        "service_name": service_name,
        "time_range_minutes": time_range_minutes,
        "limit": limit,
        "count": 2,
        "lines": [
            "ERROR: NullPointerException at IncidentService.handleCreation",
            "ERROR: ...",
        ],
        "rows": [
            {
                "timestamp": "2026-07-13T14:25:01Z",
                "message": "ERROR: NullPointerException at IncidentService.handleCreation",
                "type": "AppTraces",
                "severity_level": 3,
                "operation_name": "",
                "operation_id": "ghi-789",
                "parent_id": "",
                "app_role_name": service_name,
                "app_role_instance": "target-system-abc",
                "resource_id": "",
                "properties": None,
                "measurements": None,
                "item_count": 1,
            }
        ],
        "queried_at": "2026-07-13T14:26:00Z",
    }


async def git_blame(repo: str, file_path: str, line_number: int) -> dict[str, Any]:
    if line_number <= 0:
        raise ValueError("line_number must be > 0")
    return {
        "repo_root": "/mock/repo",
        "file_path": file_path,
        "line_number": line_number,
        "commit_sha": "f3a2b1c",
        "author": "dev@company.com",
        "author_time": "2026-07-13T14:20:00Z",
        "summary": "Add incident creation endpoint",
        "line_text": "String priority = incident.getPriority();",
    }


async def get_code_snippet(
    repo: str, file_path: str, line_start: int, line_end: int
) -> dict[str, Any]:
    if line_start <= 0:
        raise ValueError("line_start must be > 0")
    if line_end < line_start:
        raise ValueError("line_end must be >= line_start")
    return {
        "repo_root": "/mock/repo",
        "file_path": file_path,
        "line_start": line_start,
        "line_end": line_end,
        "snippet": [
            {"line_number": 40, "text": "public void handleCreation(Incident incident) {"},
            {"line_number": 41, "text": "    // missing null check"},
            {"line_number": 42, "text": "    String priority = incident.getPriority();"},
        ],
    }


async def create_pr(repo: str, title: str, description: str, diff: str) -> dict[str, Any]:
    if not diff.strip():
        raise ValueError("diff must not be empty")
    return {
        "repo": repo or "owner/mock-repo",
        "title": title,
        "description": description,
        "head": "feat/auto-fix-mock",
        "base": "main",
        "draft": True,
        "pull_request_url": "https://github.com/owner/mock-repo/pull/1",
        "number": 1,
        "state": "open",
        "created_at": "2026-07-13T14:30:00Z",
    }


async def restart_aca_revision(service_name: str) -> dict[str, Any]:
    return {
        "service_name": service_name,
        "subscription_id": "mock-sub",
        "resource_group": "mock-rg",
        "container_app_name": service_name,
        "revision_name": "mock-revision-001",
        "message": "revision restart accepted (mock)",
        "timestamp": "2026-07-13T14:30:00Z",
    }
