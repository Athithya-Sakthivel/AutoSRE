"""Tool registry and built-in tool modules.

Public API:

* :class:`Tool` -- immutable description of a registered tool.
* :class:`ToolInputModel` -- strict base model for tool inputs.
* :class:`ToolRegistry` -- thread-safe registry and execution dispatcher.
* :func:`build_default_registry` -- registers all built-in tools.
* :func:`get_tool_schemas` -- returns OpenAI-compatible tool definitions.
"""

from __future__ import annotations

from autosre.tools.registry import (
    Tool,
    ToolError,
    ToolExecutionError,
    ToolInputModel,
    ToolNotFoundError,
    ToolRegistry,
    build_default_registry,
    get_tool_schemas,
)

__all__ = [
    "Tool",
    "ToolError",
    "ToolExecutionError",
    "ToolInputModel",
    "ToolNotFoundError",
    "ToolRegistry",
    "build_default_registry",
    "get_tool_schemas",
]
