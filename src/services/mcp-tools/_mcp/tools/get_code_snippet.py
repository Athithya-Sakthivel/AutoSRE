"""Read a range of lines from a source file."""

from __future__ import annotations

import asyncio
from typing import Any

from opentelemetry import trace

from ..helpers import validate_file_in_repo
from ..runtime import get_runtime


async def get_code_snippet(
    repo: str, file_path: str, line_start: int, line_end: int
) -> dict[str, Any]:
    """Return numbered lines from a source file within the repository."""
    if line_start <= 0:
        raise ValueError("line_start must be > 0")
    if line_end < line_start:
        raise ValueError("line_end must be >= line_start")

    runtime = get_runtime()
    repo_root = runtime.git_repo_root
    target = validate_file_in_repo(repo_root, file_path)
    rel_path = target.relative_to(repo_root)

    content = await asyncio.to_thread(target.read_text, encoding="utf-8", errors="replace")
    all_lines = content.splitlines()
    start_idx = line_start - 1
    end_idx = min(line_end, len(all_lines))
    snippet = [
        {"line_number": idx + 1, "text": all_lines[idx]} for idx in range(start_idx, end_idx)
    ]

    tracer = trace.get_tracer(runtime.settings.service_name)
    with tracer.start_as_current_span("get_code_snippet") as span:
        span.set_attribute("mcp.tool", "get_code_snippet")
        span.set_attribute("mcp.snippet_lines", len(snippet))
        return {
            "repo_root": str(repo_root),
            "file_path": str(rel_path),
            "line_start": line_start,
            "line_end": line_end,
            "snippet": snippet,
        }
