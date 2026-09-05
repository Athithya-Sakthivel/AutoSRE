"""Unit tests for the mock tool implementations used in development mode."""

import pytest
from _mcp.tools.tools_mock import (
    create_pr,
    get_code_snippet,
    git_blame,
    query_logs,
    query_traces,
    restart_aca_revision,
)


class TestQueryTraces:
    async def test_returns_expected_structure(self):
        result = await query_traces("target-system")
        assert result["service_name"] == "target-system"
        assert result["count"] > 0
        assert len(result["rows"]) == result["count"]
        assert "timestamp" in result["rows"][0]

    async def test_rejects_invalid_time_range(self):
        with pytest.raises(ValueError, match="time_range_minutes must be > 0"):
            await query_traces("target-system", time_range_minutes=0)

    async def test_rejects_invalid_limit(self):
        with pytest.raises(ValueError, match="limit must be > 0"):
            await query_traces("target-system", limit=0)


class TestQueryLogs:
    async def test_returns_expected_structure(self):
        result = await query_logs("target-system")
        assert result["service_name"] == "target-system"
        assert result["count"] > 0
        assert isinstance(result["lines"], list)

    async def test_rejects_invalid_time_range(self):
        with pytest.raises(ValueError):
            await query_logs("target-system", time_range_minutes=-1)


class TestGitBlame:
    async def test_returns_commit_metadata(self):
        result = await git_blame("", "src/main.py", 42)
        assert result["commit_sha"] == "f3a2b1c"
        assert result["line_number"] == 42

    async def test_rejects_invalid_line_number(self):
        with pytest.raises(ValueError):
            await git_blame("", "file.py", 0)


class TestGetCodeSnippet:
    async def test_returns_snippet_lines(self):
        result = await get_code_snippet("", "file.py", 40, 42)
        assert len(result["snippet"]) == 3
        assert result["snippet"][0]["line_number"] == 40

    async def test_rejects_invalid_range(self):
        with pytest.raises(ValueError):
            await get_code_snippet("", "file.py", 42, 40)


class TestCreatePR:
    async def test_returns_pr_url(self):
        result = await create_pr("owner/repo", "Fix bug", "Fixes the NPE", "--- diff ---")
        assert result["pull_request_url"].startswith("https://")
        assert result["draft"] is True

    async def test_rejects_empty_diff(self):
        with pytest.raises(ValueError, match="diff must not be empty"):
            await create_pr("owner/repo", "title", "desc", "")


class TestRestartACARevision:
    async def test_returns_success_message(self):
        result = await restart_aca_revision("target-system")
        assert result["message"] == "revision restart accepted (mock)"
        assert result["container_app_name"] == "target-system"
