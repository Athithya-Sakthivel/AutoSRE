"""Create a draft GitHub pull request."""

from __future__ import annotations

from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from ..config import ConfigError
from ..runtime import get_runtime


def _parse_repo(repo: str | None, default: str) -> tuple[str, str]:
    value = repo or default
    if "/" not in value:
        raise ConfigError("Repository must be in owner/repo format")
    owner, name = value.split("/", 1)
    if not owner or not name:
        raise ConfigError("Repository must be in owner/repo format")
    return owner, name


async def create_pr(repo: str, title: str, description: str, diff: str) -> dict[str, Any]:
    """Create a draft pull request with the provided diff."""
    if not diff.strip():
        raise ValueError("diff must not be empty")

    runtime = get_runtime()
    settings = runtime.settings
    token, default_repo, head_branch = settings.require_github()
    owner, name = _parse_repo(repo, default_repo)
    base = settings.github_base_branch.strip()
    if not base:
        raise ConfigError("GITHUB_BASE_BRANCH is required")

    # Truncate diff to avoid sending an enormous PR body (GitHub limit is higher, but we keep payloads reasonable)
    body = description.strip()
    body = f"{body}\n\n---\nDiff preview:\n{diff[:12000]}".strip()

    url = f"https://api.github.com/repos/{owner}/{name}/pulls"
    tracer = trace.get_tracer(settings.service_name)
    with tracer.start_as_current_span("create_pr") as span:
        response = await runtime.http.post(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": settings.github_api_version,
            },
            json={
                "title": title,
                "body": body,
                "head": head_branch,
                "base": base,
                "draft": True,
            },
        )
        if response.status_code >= 400:
            span.record_exception(RuntimeError(response.text))
            span.set_status(Status(StatusCode.ERROR, response.text))
            raise RuntimeError(f"GitHub PR creation failed: {response.status_code} {response.text}")

        data = response.json()
        span.set_attribute("mcp.tool", "create_pr")
        return {
            "repo": f"{owner}/{name}",
            "title": title,
            "description": description,
            "head": head_branch,
            "base": base,
            "draft": True,
            "pull_request_url": data.get("html_url"),
            "number": data.get("number"),
            "state": data.get("state"),
            "created_at": data.get("created_at"),
        }
