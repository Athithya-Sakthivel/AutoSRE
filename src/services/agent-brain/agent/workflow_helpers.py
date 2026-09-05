"""Pure helper functions for workflow nodes – no side effects."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from datetime import UTC
from typing import Any

from infra.config import Settings, load_settings

SOURCE_PATTERNS = (
    re.compile(
        r'(?P<file>(?:[A-Za-z]:)?[^\s:"\']+\.(?:py|ts|tsx|js|jsx|go|cs|java|rb|rs|c|cpp|h|hpp|json|yml|yaml)):(?P<line>\d+)',
        re.IGNORECASE,
    ),
    re.compile(
        r'File ["\'](?P<file>[^"\']+\.(?:py|ts|tsx|js|jsx|go|cs|java|rb|rs|c|cpp|h|hpp|json|yml|yaml))["\'](?:, line (?P<line>\d+))?',
        re.IGNORECASE,
    ),
    re.compile(
        r"at (?P<file>[^\s:]+\.(?:py|ts|tsx|js|jsx|go|cs|java|rb|rs|c|cpp|h|hpp|json|yml|yaml)):(?P<line>\d+)",
        re.IGNORECASE,
    ),
)


def settings() -> Settings:
    return load_settings()


def now_iso() -> str:
    from datetime import datetime

    return datetime.now(UTC).isoformat()


def ensure_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def textify(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, default=str)
    except TypeError:
        return str(value)


def parse_jsonish(value: Any) -> Any:
    if isinstance(value, (dict, list, tuple)):
        return value
    if not isinstance(value, str):
        return value
    candidate = value.strip()
    if not candidate:
        return value
    if candidate.startswith("```"):
        candidate = re.sub(r"^```(?:json)?\s*", "", candidate, flags=re.IGNORECASE)
        candidate = re.sub(r"\s*```$", "", candidate)
    try:
        return json.loads(candidate)
    except Exception:
        return value


def flatten_text_blobs(value: Any) -> list[str]:
    blobs: list[str] = []

    def walk(item: Any) -> None:
        if item is None:
            return
        if isinstance(item, str):
            blobs.append(item)
            return
        if isinstance(item, Mapping):
            blobs.append(textify(item))
            for child in item.values():
                walk(child)
            return
        if isinstance(item, Sequence) and not isinstance(item, (bytes, bytearray, str)):
            for child in item:
                walk(child)
            return
        blobs.append(str(item))

    walk(value)
    return blobs


def extract_location(texts: Sequence[str]) -> tuple[str, int] | None:
    for text in texts:
        for pattern in SOURCE_PATTERNS:
            match = pattern.search(text)
            if match:
                file_path = match.group("file")
                line_raw = match.groupdict().get("line")
                line_number = int(line_raw) if line_raw and line_raw.isdigit() else 1
                return file_path, max(line_number, 1)
    return None


def merge_notes(state: Mapping[str, Any], *notes: str) -> list[str]:
    existing = [str(note) for note in state.get("notes", []) if note]
    existing.extend(note for note in notes if note)
    return existing


def base_alert_payload(state: Mapping[str, Any]) -> dict[str, Any]:
    alert = state.get("alert")
    if isinstance(alert, Mapping):
        return dict(alert)
    return {}


def default_action(state: Mapping[str, Any]) -> dict[str, Any]:
    evidence = textify(
        [state.get("trace_records"), state.get("log_records"), state.get("code_snippet")]
    ).lower()
    if any(
        kw in evidence
        for kw in ("oom", "out of memory", "crash", "deadlock", "timeout", "unhealthy")
    ):
        return {
            "tool_name": "restart_aca_revision",
            "args": {"service_name": state.get("service_name", "")},
        }
    # No safe fallback – escalate by returning an empty tool_name.
    return {"tool_name": "", "args": {}, "rationale": "No automated fix identified"}


__all__ = [
    "base_alert_payload",
    "default_action",
    "ensure_list",
    "extract_location",
    "flatten_text_blobs",
    "merge_notes",
    "now_iso",
    "parse_jsonish",
    "textify",
]
