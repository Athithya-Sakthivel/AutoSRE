"""Tool registration, schema export, validation, tracing, and dispatch."""

from __future__ import annotations

import json
import re
from collections.abc import Awaitable, Callable, Iterator, Mapping
from dataclasses import dataclass, field
from threading import RLock
from typing import Any

from openinference.semconv.trace import SpanAttributes
from opentelemetry import trace
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, ConfigDict, ValidationError

from autosre.config import Settings
from autosre.core.state import SREContext

_TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class ToolError(Exception):
    """Base exception for tool-related errors."""


class ToolNotFoundError(ToolError):
    """Raised when a requested tool is not registered."""


class ToolExecutionError(ToolError):
    """Raised when tool input, execution, or output validation fails."""

    def __init__(
        self,
        tool_name: str,
        original: BaseException,
    ) -> None:
        super().__init__(f"Tool '{tool_name}' failed: {original!r}")
        self.tool_name = tool_name
        self.original = original


class ToolInputModel(BaseModel):
    """Strict base model for tool-call arguments."""

    model_config = ConfigDict(extra="forbid")


@dataclass(frozen=True, slots=True)
class Tool:
    """Immutable description of a registered tool.

    ``strict`` is opt-in because this project uses LiteLLM across multiple
    providers. Built-in models intentionally stay non-strict in this phase
    because they contain optional/defaulted fields.
    """

    name: str
    description: str
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    handler: Callable[..., Awaitable[Any]]  # Changed from ToolHandler
    risk_tier: int = field(default=0)
    strict: bool = field(default=False)

    def __post_init__(self) -> None:
        name = self.name.strip()
        description = self.description.strip()

        if not _TOOL_NAME_RE.fullmatch(name):
            raise ValueError(
                "tool name must contain only letters, digits, '_' or '-' "
                "and be at most 64 characters"
            )

        if not description:
            raise ValueError(f"tool '{name}' description must not be empty")

        if not 0 <= self.risk_tier <= 4:
            raise ValueError(f"tool '{name}' risk_tier must be between 0 and 4")

        if not isinstance(self.input_model, type) or not issubclass(self.input_model, BaseModel):
            raise TypeError(f"tool '{name}' input_model must be a Pydantic model")

        if not isinstance(self.output_model, type) or not issubclass(self.output_model, BaseModel):
            raise TypeError(f"tool '{name}' output_model must be a Pydantic model")

        if not callable(self.handler):
            raise TypeError(f"tool '{name}' handler must be callable")

    def to_openai_schema(self) -> dict[str, Any]:
        """Render the tool as an OpenAI/LiteLLM function-tool definition."""

        schema = dict(self.input_model.model_json_schema())

        schema.pop("title", None)

        if not schema.get("$defs"):
            schema.pop("$defs", None)

        function: dict[str, Any] = {
            "name": self.name,
            "description": self.description,
            "parameters": schema,
        }

        if self.strict:
            function["strict"] = True

        return {
            "type": "function",
            "function": function,
        }


class ToolRegistry:
    """Thread-safe registry and execution dispatcher for :class:`Tool` objects."""

    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}
        self._lock = RLock()

    def register(
        self,
        tool: Tool,
    ) -> None:
        """Register a tool, rejecting duplicate names."""

        with self._lock:
            if tool.name in self._tools:
                raise ToolError(
                    f"Tool '{tool.name}' is already registered; tool names must be unique"
                )

            self._tools[tool.name] = tool

    def unregister(
        self,
        name: str,
    ) -> None:
        """Remove a tool by name. No-op if absent."""

        with self._lock:
            self._tools.pop(
                name,
                None,
            )

    def __contains__(
        self,
        name: str,
    ) -> bool:
        with self._lock:
            return name in self._tools

    def __len__(self) -> int:
        with self._lock:
            return len(self._tools)

    def __iter__(self) -> Iterator[Tool]:
        with self._lock:
            snapshot = tuple(self._tools.values())

        return iter(snapshot)

    def get(
        self,
        name: str,
    ) -> Tool:
        with self._lock:
            tool = self._tools.get(name)

        if tool is None:
            raise ToolNotFoundError(f"Tool '{name}' is not registered")

        return tool

    def list_tools(self) -> list[Tool]:
        with self._lock:
            return list(self._tools.values())

    def schemas(self) -> list[dict[str, Any]]:
        """Return tool schemas sorted by name for deterministic prompts/caching."""

        with self._lock:
            tools = [self._tools[name] for name in sorted(self._tools)]

        return [tool.to_openai_schema() for tool in tools]

    async def execute(
        self,
        name: str,
        raw_args: Mapping[str, Any],
        context: SREContext,
    ) -> dict[str, Any]:
        """Validate, trace, execute, and validate a tool call."""

        tool = self.get(name)

        if not isinstance(
            raw_args,
            Mapping,
        ):
            raise ToolExecutionError(
                name,
                TypeError("tool arguments must be a mapping"),
            )

        args_dict = dict(raw_args)

        tracer = trace.get_tracer("autosre.tools")

        input_json = json.dumps(
            args_dict,
            default=str,
            sort_keys=True,
            separators=(",", ":"),
        )

        with tracer.start_as_current_span(
            f"tool.{name}",
            attributes={
                SpanAttributes.OPENINFERENCE_SPAN_KIND: "TOOL",
                SpanAttributes.TOOL_NAME: name,
                SpanAttributes.TOOL_PARAMETERS: input_json,
            },
        ) as span:
            try:
                validated_input = tool.input_model.model_validate(args_dict)
            except ValidationError as exc:
                span.record_exception(exc)
                span.set_attribute(
                    "tool.validation_error",
                    str(exc),
                )
                span.set_status(
                    StatusCode.ERROR,
                    "input validation failed",
                )
                raise ToolExecutionError(
                    name,
                    exc,
                ) from exc

            try:
                result = await tool.handler(
                    validated_input,
                    context,
                )
            except ToolExecutionError as exc:
                span.record_exception(exc.original)
                span.set_attribute(
                    "tool.error",
                    str(exc),
                )
                span.set_status(
                    StatusCode.ERROR,
                    "tool rejected execution",
                )
                raise
            except Exception as exc:  # noqa: BLE001 - tool boundary
                span.record_exception(exc)
                span.set_attribute(
                    "tool.error",
                    repr(exc),
                )
                span.set_status(
                    StatusCode.ERROR,
                    "tool handler failed",
                )
                raise ToolExecutionError(
                    name,
                    exc,
                ) from exc

            try:
                validated_output = tool.output_model.model_validate(result)

                output_dict = validated_output.model_dump(mode="json")
            except (
                ValidationError,
                TypeError,
                ValueError,
            ) as exc:
                span.record_exception(exc)
                span.set_attribute(
                    "tool.output_validation_error",
                    str(exc),
                )
                span.set_status(
                    StatusCode.ERROR,
                    "output validation failed",
                )
                raise ToolExecutionError(
                    name,
                    exc,
                ) from exc

            output_json = json.dumps(
                output_dict,
                default=str,
                sort_keys=True,
                separators=(",", ":"),
            )

            span.set_attribute(
                SpanAttributes.OUTPUT_VALUE,
                output_json,
            )
            span.set_attribute(
                SpanAttributes.OUTPUT_MIME_TYPE,
                "application/json",
            )
            span.set_status(StatusCode.OK)

            return output_dict


def get_tool_schemas(
    registry: ToolRegistry,
) -> list[dict[str, Any]]:
    """Return OpenAI-compatible tool schemas for ``registry``."""

    return registry.schemas()


def build_default_registry(
    settings: Settings,  # noqa: ARG001 - retained for the phase-wide API
    context: SREContext,
) -> ToolRegistry:
    """Build the default registry with all built-in tool modules."""

    from autosre.tools import k8s as k8s_tools
    from autosre.tools import observability as o11y_tools
    from autosre.tools import postgres as pg_tools
    from autosre.tools import valkey as valkey_tools

    registry = ToolRegistry()

    k8s_tools.register(
        registry,
        context,
    )
    pg_tools.register(
        registry,
        context,
    )
    o11y_tools.register(
        registry,
        context,
    )
    valkey_tools.register(
        registry,
        context,
    )

    return registry
