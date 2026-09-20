"""Tool-result context eviction middleware.

Large tool results are summarized before they are sent back to an LLM. The
middleware uses deterministic extraction by default and supports an optional
async summarizer hook for a cheap subagent/CodeAct implementation. The final
summary is always constrained by both character and token budgets.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Awaitable, Callable, Mapping
from typing import Any

import tiktoken

logger = logging.getLogger(__name__)

DEFAULT_MAX_RESULT_CHARS = 2000
DEFAULT_MAX_RESULT_TOKENS = 450
DEFAULT_MAX_CONTEXT_CHARS = 50000
DEFAULT_TIKTOKEN_ENCODING = "cl100k_base"

AsyncSummarizer = Callable[
    [str, str, dict[str, Any] | None, int],
    Awaitable[str],
]


class ContextEviction:
    """Replace oversized tool results with compact evidence-preserving summaries."""

    _ERROR_RE = re.compile(
        r"error|failed?|failure|exception|traceback|fatal|panic|denied|timed? out",
        re.IGNORECASE,
    )

    _WARNING_RE = re.compile(
        r"warn(?:ing)?",
        re.IGNORECASE,
    )

    _METRIC_PATTERNS = (
        (
            re.compile(
                r"\b(\d+(?:\.\d+)?)\s*(ms|milliseconds?)\b",
                re.IGNORECASE,
            ),
            "duration",
        ),
        (
            re.compile(
                r"\b(\d+(?:\.\d+)?)\s*(s|seconds?)\b",
                re.IGNORECASE,
            ),
            "duration",
        ),
        (
            re.compile(
                r"\b(\d+(?:\.\d+)?)%\b",
                re.IGNORECASE,
            ),
            "percentage",
        ),
        (
            re.compile(
                r"\b(\d+(?:\.\d+)?)\s*(KB|MB|GB|bytes?)\b",
                re.IGNORECASE,
            ),
            "memory",
        ),
        (
            re.compile(
                r"\b(\d+(?:\.\d+)?)\s*(requests?|reqs?|rps)\b",
                re.IGNORECASE,
            ),
            "requests",
        ),
    )

    _KEY_PATTERNS = (
        "OOMKilled",
        "CrashLoopBackOff",
        "ImagePullBackOff",
        "Evicted",
        "Timeout",
    )

    _KNOWN_JSON_KEYS = (
        "error",
        "errors",
        "message",
        "reason",
        "status",
        "phase",
        "pod",
        "deployment",
        "service",
        "namespace",
        "name",
        "count",
        "total",
    )

    def __init__(
        self,
        max_result_chars: int = DEFAULT_MAX_RESULT_CHARS,
        max_context_chars: int = DEFAULT_MAX_CONTEXT_CHARS,
        *,
        max_result_tokens: int = DEFAULT_MAX_RESULT_TOKENS,
        encoder: Any | None = None,
        summarizer: AsyncSummarizer | None = None,
    ) -> None:
        if max_result_chars <= 0:
            raise ValueError("max_result_chars must be greater than zero")

        if max_context_chars <= 0:
            raise ValueError("max_context_chars must be greater than zero")

        if max_result_tokens <= 0:
            raise ValueError("max_result_tokens must be greater than zero")

        self.max_result_chars = max_result_chars
        self.max_context_chars = max_context_chars
        self.max_result_tokens = max_result_tokens
        self.encoder = encoder or tiktoken.get_encoding(DEFAULT_TIKTOKEN_ENCODING)
        self.summarizer = summarizer
        self.stats: dict[str, Any] = self._new_stats()

    @staticmethod
    def _new_stats() -> dict[str, Any]:
        return {
            "total_evictions": 0,
            "total_chars_evicted": 0,
            "total_context_compactions": 0,
            "eviction_history": [],
        }

    def count_tokens(self, text: str) -> int:
        """Count summary tokens using the same encoder used for fitting."""
        return len(self.encoder.encode(text))

    def process_messages(
        self,
        messages: list[dict[str, Any]],
        state: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Synchronously evict oversized tool messages."""
        if not messages:
            return []

        processed: list[dict[str, Any]] = []

        for message in messages:
            current = dict(message)

            if current.get("role") != "tool":
                processed.append(current)
                continue

            content = current.get("content")

            if self._is_evicted_marker(content):
                processed.append(current)
                continue

            raw = self._content_to_text(content)

            if len(raw) <= self.max_result_chars:
                processed.append(current)
                continue

            tool_name = str(current.get("name", "unknown"))

            summary = self._evict_tool_result(
                tool_name=tool_name,
                content=raw,
                state=state,
            )

            self._record_eviction(
                tool_name=tool_name,
                original=raw,
                summary=summary,
            )

            current["content"] = summary
            processed.append(current)

        return self._enforce_context_budget(processed)

    async def aprocess_messages(
        self,
        messages: list[dict[str, Any]],
        state: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Async variant using the optional cheap summarizer hook."""
        if self.summarizer is None:
            return self.process_messages(
                messages,
                state=state,
            )

        processed: list[dict[str, Any]] = []

        for message in messages:
            current = dict(message)

            if current.get("role") != "tool":
                processed.append(current)
                continue

            content = current.get("content")

            if self._is_evicted_marker(content):
                processed.append(current)
                continue

            raw = self._content_to_text(content)

            if len(raw) <= self.max_result_chars:
                processed.append(current)
                continue

            tool_name = str(current.get("name", "unknown"))

            try:
                candidate = await self.summarizer(
                    tool_name,
                    raw,
                    state,
                    self.max_result_tokens,
                )

                summary = self._fit_summary(str(candidate))

                if not summary.strip():
                    raise ValueError("summarizer returned an empty summary")

            except Exception as exc:
                logger.warning(
                    "Async tool summarizer failed for %s; using deterministic fallback: %s",
                    tool_name,
                    exc,
                )

                summary = self._evict_tool_result(
                    tool_name,
                    raw,
                    state=state,
                )

            self._record_eviction(
                tool_name,
                raw,
                summary,
            )

            current["content"] = summary
            processed.append(current)

        return self._enforce_context_budget(processed)

    @staticmethod
    def _is_evicted_marker(content: Any) -> bool:
        return isinstance(content, Mapping) and content.get("evicted") is True

    @staticmethod
    def _content_to_text(content: Any) -> str:
        if content is None:
            return ""

        if isinstance(content, str):
            return content

        try:
            return json.dumps(
                content,
                ensure_ascii=False,
                sort_keys=True,
                default=str,
            )

        except TypeError, ValueError:
            return str(content)

    def _record_eviction(
        self,
        tool_name: str,
        original: str,
        summary: str,
    ) -> None:
        chars_saved = max(
            0,
            len(original) - len(summary),
        )

        self.stats["total_evictions"] += 1
        self.stats["total_chars_evicted"] += chars_saved

        self.stats["eviction_history"].append(
            {
                "tool_name": tool_name,
                "original_chars": len(original),
                "evicted_chars": len(summary),
                "summary_tokens": self.count_tokens(summary),
            }
        )

    def _evict_tool_result(
        self,
        tool_name: str,
        content: str,
        state: dict[str, Any] | None = None,
    ) -> str:
        del state

        try:
            data = json.loads(content)

        except (
            json.JSONDecodeError,
            TypeError,
            ValueError,
        ):
            summary = self._summarize_text(
                tool_name,
                content,
            )

        else:
            summary = self._summarize_json(
                tool_name,
                data,
            )

        return self._fit_summary(summary)

    def _summarize_json(
        self,
        tool_name: str,
        data: Any,
    ) -> str:
        parts = [f"[{tool_name}] JSON summary"]

        if isinstance(data, dict):
            for key in self._KNOWN_JSON_KEYS:
                if key not in data:
                    continue

                value = data[key]

                if key in {"error", "errors"}:
                    values = value if isinstance(value, list) else [value]

                    rendered = "; ".join(str(item).strip()[:180] for item in values[:4])

                    parts.append(f"Errors({len(values)}): {rendered}")

                elif isinstance(
                    value,
                    (
                        str,
                        int,
                        float,
                        bool,
                    ),
                ):
                    parts.append(f"{key.title()}: {value}")

            numeric: list[str] = []

            for key, value in data.items():
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    numeric.append(f"{key}={value}")

            if numeric:
                parts.append("Metrics: " + ", ".join(numeric[:8]))

            for key in (
                "items",
                "data",
                "results",
            ):
                value = data.get(key)

                if isinstance(value, list):
                    parts.append(f"{key.title()}: {len(value)} items")

                    if value and isinstance(value[0], dict):
                        parts.append(
                            "Keys: "
                            + ", ".join(
                                map(
                                    str,
                                    list(value[0].keys())[:8],
                                )
                            )
                        )

                    break

            if len(parts) == 1:
                parts.append(
                    "Top-level keys: "
                    + ", ".join(
                        map(
                            str,
                            list(data.keys())[:12],
                        )
                    )
                )

        elif isinstance(data, list):
            parts.append(f"List: {len(data)} items")

            if data and isinstance(data[0], dict):
                parts.append(
                    "Keys: "
                    + ", ".join(
                        map(
                            str,
                            list(data[0].keys())[:8],
                        )
                    )
                )

        else:
            parts.append(f"Data type: {type(data).__name__}")

        return " | ".join(parts)

    def _summarize_text(
        self,
        tool_name: str,
        content: str,
    ) -> str:
        lines = [line.strip() for line in content.splitlines() if line.strip()]

        if not lines:
            return f"[{tool_name}] empty result"

        parts = [f"[{tool_name}] {len(lines)} non-empty lines"]

        error_lines = self._dedupe(self._ERROR_RE.search(line) and line for line in lines)

        if error_lines:
            parts.append("Errors: " + " | ".join(line[:180] for line in error_lines[:6]))

        warning_lines = self._dedupe(self._WARNING_RE.search(line) and line for line in lines)

        if warning_lines:
            parts.append("Warnings: " + " | ".join(line[:140] for line in warning_lines[:3]))

        metrics: list[str] = []

        for pattern, label in self._METRIC_PATTERNS:
            match = pattern.search(content)

            if match:
                metrics.append(f"{label}={match.group(1)} {match.group(2)}")

        if metrics:
            parts.append("Metrics: " + ", ".join(metrics[:6]))

        patterns = [
            pattern
            for pattern in self._KEY_PATTERNS
            if re.search(
                re.escape(pattern),
                content,
                re.IGNORECASE,
            )
        ]

        if patterns:
            parts.append("Patterns: " + ", ".join(patterns))

        resource_matches = re.findall(
            r"\b(?:pod|deployment|service|namespace)"
            r"\s*[=/ :]+\s*"
            r"([A-Za-z0-9._-]+)",
            content,
            re.IGNORECASE,
        )

        resource_matches = self._dedupe(resource_matches)

        if resource_matches:
            parts.append("Resources: " + ", ".join(resource_matches[:8]))

        head = self._dedupe(lines[:2])

        tail = self._dedupe(lines[-2:])

        context_lines = self._dedupe(head + tail)

        if context_lines:
            parts.append("Context: " + " | ".join(line[:140] for line in context_lines))

        return " | ".join(parts)

    @staticmethod
    def _dedupe(values: Any) -> list[str]:
        result: list[str] = []
        seen: set[str] = set()

        for value in values:
            if not value:
                continue

            text = str(value).strip()

            if text and text not in seen:
                seen.add(text)
                result.append(text)

        return result

    def _fit_summary(self, summary: str) -> str:
        """Apply both char and token caps to the final summary."""
        text = summary.strip()

        if not text:
            return "[tool] no summary available"

        if len(text) > self.max_result_chars:
            text = text[: self.max_result_chars].rstrip()

        if self.count_tokens(text) <= self.max_result_tokens:
            return text

        suffix = "\n[summary truncated]"
        suffix_tokens = self.count_tokens(suffix)

        budget = max(
            1,
            self.max_result_tokens - suffix_tokens,
        )

        token_ids = self.encoder.encode(text)[:budget]

        candidate = self.encoder.decode(token_ids).rstrip() + suffix

        while self.count_tokens(candidate) > self.max_result_tokens and token_ids:
            token_ids = token_ids[:-1]

            candidate = self.encoder.decode(token_ids).rstrip() + suffix

        return candidate[: self.max_result_chars].rstrip()

    def _enforce_context_budget(
        self,
        messages: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        total_chars = sum(
            len(self._content_to_text(message.get("content"))) for message in messages
        )

        if total_chars <= self.max_context_chars:
            return messages

        logger.warning(
            "Context exceeds char budget: %d > %d; compacting oldest tool results",
            total_chars,
            self.max_context_chars,
        )

        result = [dict(message) for message in messages]

        for index, message in enumerate(result):
            if total_chars <= self.max_context_chars:
                break

            if message.get("role") != "tool":
                continue

            original = self._content_to_text(message.get("content"))

            tool_name = str(message.get("name", "unknown"))

            marker = self._fit_summary(
                f"[{tool_name}] context budget compaction; "
                "retained summary omitted to protect context size."
            )

            result[index]["content"] = marker

            total_chars -= max(
                0,
                len(original) - len(marker),
            )

            self.stats["total_context_compactions"] += 1

        if total_chars > self.max_context_chars:
            logger.warning(
                "Context remains above budget (%d > %d); no removable tool results remain",
                total_chars,
                self.max_context_chars,
            )

        return result

    def get_stats(self) -> dict[str, Any]:
        """Return an independent statistics snapshot."""
        return {
            "total_evictions": self.stats["total_evictions"],
            "total_chars_evicted": self.stats["total_chars_evicted"],
            "total_context_compactions": self.stats["total_context_compactions"],
            "eviction_history": [dict(item) for item in self.stats["eviction_history"]],
        }

    def reset_stats(self) -> None:
        """Reset all eviction counters and history."""
        self.stats = self._new_stats()


# Backwards compatibility alias
ToolResultEviction = ContextEviction
