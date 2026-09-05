"""Shared helpers: KQL, Log Analytics API, Git operations, and validation."""

from __future__ import annotations

import asyncio
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

from .config import ConfigError
from .runtime import get_runtime

_SAFE_NAME_RE = re.compile(r"[^a-zA-Z0-9_\-.]")


def sanitize_kql_identifier(name: str) -> str:
    """Escape single quotes to prevent KQL injection."""
    return name.replace("'", "''")


def traces_kql(service_name: str, time_range_minutes: int, limit: int) -> str:
    safe = sanitize_kql_identifier(service_name)
    return f"""
union AppTraces, AppExceptions
| where TimeGenerated > ago({time_range_minutes}m)
| where AppRoleName == '{safe}'
| project TimeGenerated, Type, Message, SeverityLevel, OperationName, OperationId, ParentId, AppRoleName, AppRoleInstance, Properties, Measurements, ItemCount, _ResourceId
| order by TimeGenerated desc
| take {limit}
""".strip()


def logs_kql(service_name: str, time_range_minutes: int, limit: int) -> str:
    safe = sanitize_kql_identifier(service_name)
    return f"""
union AppTraces, AppExceptions
| where TimeGenerated > ago({time_range_minutes}m)
| where AppRoleName == '{safe}'
| project TimeGenerated, Message, SeverityLevel, OperationName, OperationId, ParentId, AppRoleName, AppRoleInstance, Properties, Measurements, ItemCount, _ResourceId
| order by TimeGenerated desc
| take {limit}
""".strip()


async def run_log_analytics_query(query: str, time_range_minutes: int) -> dict[str, Any]:
    runtime = get_runtime()
    token = await runtime.get_token("https://api.loganalytics.io/.default")
    url = (
        f"{runtime.settings.log_analytics_endpoint}/v1/workspaces/"
        f"{runtime.settings.log_analytics_workspace_id}/query"
    )
    response = await runtime.http.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        params={"timespan": f"PT{time_range_minutes}M"},
        json={"query": query},
    )
    response.raise_for_status()
    return cast("dict[str, Any]", response.json())


def format_log_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for table in payload.get("tables", []):
        columns = [column["name"] for column in table.get("columns", [])]
        for raw_row in table.get("rows", []):
            rows.append(dict(zip(columns, raw_row, strict=False)))
    formatted = []
    for row in rows:
        formatted.append(
            {
                "timestamp": row.get("TimeGenerated"),
                "message": row.get("Message") or "",
                "type": row.get("Type") or "",
                "severity_level": row.get("SeverityLevel"),
                "operation_name": row.get("OperationName") or "",
                "operation_id": row.get("OperationId") or "",
                "parent_id": row.get("ParentId") or "",
                "app_role_name": row.get("AppRoleName") or "",
                "app_role_instance": row.get("AppRoleInstance") or "",
                "resource_id": row.get("_ResourceId") or "",
                "properties": row.get("Properties"),
                "measurements": row.get("Measurements"),
                "item_count": row.get("ItemCount"),
            }
        )
    return formatted


async def git_command(args: list[str], cwd: Path) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        "git",
        *args,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    return (
        proc.returncode if proc.returncode is not None else -1,
        stdout.decode(errors="replace"),
        stderr.decode(errors="replace"),
    )


def parse_blame_porcelain(output: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "commit_sha": "",
        "author": "",
        "author_time": "",
        "summary": "",
        "line_text": "",
    }
    for line in output.splitlines():
        if not line:
            continue
        if line.startswith("author "):
            result["author"] = line[len("author ") :]
        elif line.startswith("author-time "):
            ts = int(line[len("author-time ") :])
            result["author_time"] = (
                datetime.fromtimestamp(ts, tz=UTC).isoformat().replace("+00:00", "Z")
            )
        elif line.startswith("summary "):
            result["summary"] = line[len("summary ") :]
        elif line.startswith("\t"):
            result["line_text"] = line[1:]
        elif not result["commit_sha"]:
            result["commit_sha"] = line.split()[0]
    return result


def validate_file_in_repo(repo_root: Path, file_path: str) -> Path:
    candidate = (repo_root / file_path).resolve()
    if repo_root not in candidate.parents and candidate != repo_root:
        raise ConfigError(f"Path escapes repository root: {file_path}")
    if not candidate.exists() or not candidate.is_file():
        raise ConfigError(f"File does not exist or not a regular file: {file_path}")
    return candidate


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")
