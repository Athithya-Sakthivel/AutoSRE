"""Return commit metadata for a specific source line."""

from __future__ import annotations

from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from ..helpers import git_command, parse_blame_porcelain, validate_file_in_repo
from ..runtime import get_runtime


async def git_blame(repo: str, file_path: str, line_number: int) -> dict[str, Any]:
    """Return commit SHA, author, and summary for the given line."""
    if line_number <= 0:
        raise ValueError("line_number must be > 0")

    runtime = get_runtime()
    repo_root = runtime.git_repo_root
    target = validate_file_in_repo(repo_root, file_path)
    rel_path = target.relative_to(repo_root)

    tracer = trace.get_tracer(runtime.settings.service_name)
    with tracer.start_as_current_span("git_blame") as span:
        rc, stdout, stderr = await git_command(
            ["blame", "--porcelain", f"-L{line_number},{line_number}", "--", str(rel_path)],
            cwd=repo_root,
        )
        if rc != 0:
            msg = stderr.strip() or stdout.strip()
            span.record_exception(RuntimeError(msg))
            span.set_status(Status(StatusCode.ERROR, msg))
            raise RuntimeError(f"git blame failed: {msg}")

        parsed = parse_blame_porcelain(stdout)
        span.set_attribute("mcp.tool", "git_blame")
        return {
            "repo_root": str(repo_root),
            "file_path": str(rel_path),
            "line_number": line_number,
            **parsed,
        }
