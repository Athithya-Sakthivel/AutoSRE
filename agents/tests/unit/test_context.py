"""Unit tests for ContextEviction."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock

import pytest

from autosre.core.context import ContextEviction


@pytest.fixture
def eviction() -> ContextEviction:
    return ContextEviction(
        max_result_chars=2000,
        max_result_tokens=450,
        max_context_chars=50000,
    )


class TestToolResultEviction:
    def test_small_result_unchanged(
        self,
        eviction: ContextEviction,
    ) -> None:
        messages = [
            {
                "role": "user",
                "content": "Check pod",
            },
            {
                "role": "tool",
                "name": "get_pod",
                "content": "Pod is running",
            },
        ]

        processed = eviction.process_messages(messages)

        assert processed[1]["content"] == "Pod is running"

        assert messages[1]["content"] == "Pod is running"

    def test_large_result_is_evicted_by_chars_and_tokens(
        self,
        eviction: ContextEviction,
    ) -> None:
        large_content = "Log line " * 300

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_logs",
                    "content": large_content,
                }
            ]
        )

        content = processed[0]["content"]

        assert len(content) <= 2000
        assert eviction.count_tokens(content) < 500

    def test_evicted_result_preserves_tool_name(
        self,
        eviction: ContextEviction,
    ) -> None:
        large_content = "Error: Connection timeout\n" * 100

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "check_connection",
                    "content": large_content,
                }
            ]
        )

        assert "[check_connection]" in processed[0]["content"]

    def test_already_evicted_result_is_skipped(
        self,
        eviction: ContextEviction,
    ) -> None:
        original = {
            "evicted": True,
            "summary": "Already evicted",
        }

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_logs",
                    "content": original,
                }
            ]
        )

        assert processed[0]["content"] == original

        assert eviction.get_stats()["total_evictions"] == 0


class TestJSONSummarization:
    def test_valid_json_with_errors_and_padding(
        self,
        eviction: ContextEviction,
    ) -> None:
        data = {
            "errors": [
                "Connection failed",
                "Timeout",
            ],
            "status": "failed",
            "count": 5,
            "padding": "x" * 12000,
        }

        large_json = json.dumps(data)

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "check_status",
                    "content": large_json,
                }
            ]
        )

        summary = processed[0]["content"]

        assert "Errors" in summary
        assert "Connection failed" in summary
        assert "Status: failed" in summary

    def test_valid_json_with_metrics_and_padding(
        self,
        eviction: ContextEviction,
    ) -> None:
        data = {
            "cpu_usage": 85.5,
            "memory_mb": 1024,
            "requests_per_second": 150,
            "status": "healthy",
            "padding": "x" * 12000,
        }

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_metrics",
                    "content": json.dumps(data),
                }
            ]
        )

        summary = processed[0]["content"]

        assert "Metrics" in summary
        assert "cpu_usage" in summary

    def test_json_list_summary(
        self,
        eviction: ContextEviction,
    ) -> None:
        data = [
            {
                "pod": "api-1",
                "status": "running",
            },
            {
                "pod": "api-2",
                "status": "running",
            },
        ]

        large_json = json.dumps(data * 100)

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "list_pods",
                    "content": large_json,
                }
            ]
        )

        summary = processed[0]["content"]

        assert "List: 200 items" in summary
        assert "Keys:" in summary


class TestTextSummarization:
    def test_logs_with_errors(
        self,
        eviction: ContextEviction,
    ) -> None:
        logs = "\n".join(
            [
                "INFO: Starting service",
                "ERROR: Connection timeout",
                "INFO: Retrying",
                "ERROR: Failed to connect",
                "INFO: Shutting down",
            ]
            * 100
        )

        summary = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_logs",
                    "content": logs,
                }
            ]
        )[0]["content"]

        assert "Errors" in summary
        assert "timeout" in summary.lower()

    def test_logs_with_metrics(
        self,
        eviction: ContextEviction,
    ) -> None:
        logs = "\n".join(
            [
                "Request completed in 150ms",
                "Memory usage: 512MB",
                "CPU: 85%",
                "Requests per second: 1000",
            ]
            * 100
        )

        summary = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_metrics",
                    "content": logs,
                }
            ]
        )[0]["content"]

        assert "Metrics" in summary
        assert "duration=150" in summary

    def test_logs_with_patterns(
        self,
        eviction: ContextEviction,
    ) -> None:
        logs = "\n".join(
            [
                "Pod status: OOMKilled",
                "Restart count: 5",
                "CrashLoopBackOff detected",
            ]
            * 100
        )

        summary = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_pod_status",
                    "content": logs,
                }
            ]
        )[0]["content"]

        assert "Patterns" in summary
        assert "OOMKilled" in summary
        assert "CrashLoopBackOff" in summary


class TestTenKToFiveHundred:
    def test_10k_token_payload_shrinks_to_under_500_tokens(
        self,
        eviction: ContextEviction,
    ) -> None:
        large_payload = "word " * 10000

        processed = eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "get_logs",
                    "content": large_payload,
                }
            ]
        )

        evicted_content = processed[0]["content"]

        assert eviction.count_tokens(evicted_content) < 500

        stats = eviction.get_stats()

        assert stats["total_evictions"] == 1

        assert stats["total_chars_evicted"] > 38000

        assert stats["eviction_history"][0]["summary_tokens"] < 500


class TestContextBudget:
    def test_aggressive_compaction_preserves_message_order(
        self,
    ) -> None:
        eviction = ContextEviction(
            max_result_chars=2000,
            max_result_tokens=450,
            max_context_chars=350,
        )

        messages = [
            {
                "role": "system",
                "content": "System prompt",
            },
            {
                "role": "tool",
                "name": "tool1",
                "content": "A" * 15000,
            },
            {
                "role": "assistant",
                "content": "Assistant response",
            },
            {
                "role": "tool",
                "name": "tool2",
                "content": "B" * 15000,
            },
            {
                "role": "tool",
                "name": "tool3",
                "content": "C" * 15000,
            },
            {
                "role": "tool",
                "name": "tool4",
                "content": "D" * 15000,
            },
        ]

        processed = eviction.process_messages(messages)

        assert [message["role"] for message in processed] == [
            "system",
            "tool",
            "assistant",
            "tool",
            "tool",
            "tool",
        ]

        tool_names = [message["name"] for message in processed if message["role"] == "tool"]

        assert tool_names == [
            "tool1",
            "tool2",
            "tool3",
            "tool4",
        ]

        compacted_tools = [
            message
            for message in processed
            if (message["role"] == "tool" and "context budget compaction" in message["content"])
        ]

        assert compacted_tools

        assert eviction.get_stats()["total_context_compactions"] >= 1

    def test_non_tool_messages_are_not_removed(
        self,
    ) -> None:
        eviction = ContextEviction(max_context_chars=100)

        messages = [
            {
                "role": "system",
                "content": "S" * 500,
            },
            {
                "role": "user",
                "content": "U" * 500,
            },
            {
                "role": "assistant",
                "content": "A" * 500,
            },
        ]

        processed = eviction.process_messages(messages)

        assert processed == messages


class TestAsyncSummarizer:
    @pytest.mark.asyncio
    async def test_async_summarizer_hook_is_used(
        self,
    ) -> None:
        summarizer = AsyncMock(return_value=("[get_logs] concise subagent summary"))

        eviction = ContextEviction(
            max_result_chars=100,
            max_result_tokens=450,
            summarizer=summarizer,
        )

        processed = await eviction.aprocess_messages(
            [
                {
                    "role": "tool",
                    "name": "get_logs",
                    "content": "line " * 1000,
                }
            ]
        )

        assert processed[0]["content"] == "[get_logs] concise subagent summary"

        summarizer.assert_awaited_once()


class TestStatistics:
    def test_initial_stats(
        self,
        eviction: ContextEviction,
    ) -> None:
        stats = eviction.get_stats()

        assert stats["total_evictions"] == 0
        assert stats["total_chars_evicted"] == 0
        assert stats["total_context_compactions"] == 0
        assert stats["eviction_history"] == []

    def test_stats_accumulate_and_are_independent(
        self,
        eviction: ContextEviction,
    ) -> None:
        eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "tool1",
                    "content": "A" * 5000,
                }
            ]
        )

        stats = eviction.get_stats()

        stats["eviction_history"].append({"tampered": True})

        assert len(eviction.get_stats()["eviction_history"]) == 1

    def test_stats_reset(
        self,
        eviction: ContextEviction,
    ) -> None:
        eviction.process_messages(
            [
                {
                    "role": "tool",
                    "name": "tool1",
                    "content": "A" * 5000,
                }
            ]
        )

        eviction.reset_stats()

        stats = eviction.get_stats()

        assert stats["total_evictions"] == 0
        assert stats["total_chars_evicted"] == 0
        assert stats["total_context_compactions"] == 0
        assert stats["eviction_history"] == []
