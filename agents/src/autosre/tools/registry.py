"""Tool registration, schema export, validation, tracing, and dispatch.

## Contracts

### Tool Registration Contract
- Tool names must be unique, alphanumeric (with `_` and `-`), max 64 chars.
- Every tool must declare: name, description, input_model, output_model,
  handler, and risk_tier (0-4).
- input_model and output_model must be Pydantic BaseModel subclasses.
- handler must be a callable that accepts (input_model, SREContext).

### Execution Contract
1. Input is validated against input_model (Pydantic v2 model_validate)
2. Handler is called with validated input + SREContext
3. Output is validated against output_model
4. All steps are traced via OpenTelemetry spans with OpenInference attributes
5. Errors are wrapped in ToolExecutionError with tool_name and original exception

### Schema Export Contract
- schemas() returns tool schemas sorted alphabetically by name
- This is critical for Groq's exact-prefix prompt caching
- Each schema includes: name, description, parameters (JSON Schema)

### Risk Tier Contract
- 0: Read-only diagnostics (no mutations)
- 1: Reversible mutations (restart, terminate, delete single resource)
- 2: Requires human approval (scaling, feature flags)
- 3: Irreversible mutations (not currently used)
- 4: Prohibited (delete_namespace, flush_all, drop_table)

### Thread Safety
- The registry uses RLock for all mutations and reads
- list_tools() returns a snapshot copy
- schemas() returns a sorted list

### Tracing Safety
Tool arguments and structured tool output are scrubbed for common secret-bearing
field names before being written to OpenTelemetry span attributes.
"""

from __future__ import annotations

import inspect
import json
import re
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass, field
from threading import RLock
from typing import Any

from openinference.semconv.trace import SpanAttributes
from opentelemetry import trace
from opentelemetry.trace import StatusCode
from pydantic import BaseModel, ConfigDict, ValidationError

from autosre.config import Settings
from autosre.core.state import SREContext

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


_TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

_SENSITIVE_KEYS = frozenset(
    {
        "password",
        "passwd",
        "secret",
        "token",
        "access_token",
        "refresh_token",
        "id_token",
        "api_key",
        "apikey",
        "authorization",
        "proxy_authorization",
        "cookie",
        "set_cookie",
        "private_key",
        "client_secret",
        "access_key",
        "secret_key",
        "credential",
        "credentials",
    }
)
_REDACTED = "[REDACTED]"


class ToolInputModel(BaseModel):
    """Strict base model for tool-call arguments.

    All tool input models should inherit from this. It enforces:
    - extra="forbid": unknown fields cause validation errors
    - strict=True: Pydantic will not silently coerce input types
    - Pydantic v2 semantics
    """

    model_config = ConfigDict(
        extra="forbid",
        strict=True,
    )


class ToolError(Exception):
    """Base exception for tool-related errors."""


class ToolNotFoundError(ToolError):
    """Raised when a requested tool is not registered."""


class ToolExecutionError(ToolError):
    """Raised when tool input, execution, or output validation fails.

    Attributes:
        tool_name: Name of the tool that failed
        original: The underlying exception that caused the failure
    """

    def __init__(
        self,
        tool_name: str,
        original: BaseException,
    ) -> None:
        super().__init__(f"Tool '{tool_name}' failed: {original!r}")
        self.tool_name = tool_name
        self.original = original


@dataclass(frozen=True, slots=True)
class Tool:
    """Immutable description of a registered tool.

    Attributes:
        name: Unique tool name
        description: Human-readable description for LLM prompts
        input_model: Pydantic model for validating tool arguments
        output_model: Pydantic model for validating tool output
        handler: Async or synchronous callable(validated_input, sre_context)
        risk_tier: 0=read-only, 1=reversible, 2=approval, 3=irreversible,
            4=blocked
        strict: Whether to enable strict mode in the OpenAI schema
    """

    name: str
    description: str
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    handler: Callable[..., Any]
    risk_tier: int = field(default=0)
    strict: bool = field(default=False)

    def __post_init__(self) -> None:
        if not isinstance(self.name, str):
            raise TypeError("tool name must be a string")

        if not isinstance(self.description, str):
            raise TypeError(f"tool '{self.name}' description must be a string")

        if not isinstance(self.strict, bool):
            raise TypeError(f"tool '{self.name}' strict must be a boolean")

        name = self.name.strip()
        description = self.description.strip()

        if not _TOOL_NAME_RE.fullmatch(name):
            raise ValueError(
                "tool name must contain only letters, digits, '_' or '-' "
                "and be at most 64 characters"
            )

        if not description:
            raise ValueError(f"tool '{name}' description must not be empty")

        if isinstance(self.risk_tier, bool) or not isinstance(
            self.risk_tier,
            int,
        ):
            raise TypeError(f"tool '{name}' risk_tier must be an integer")

        if not 0 <= self.risk_tier <= 4:
            raise ValueError(f"tool '{name}' risk_tier must be between 0 and 4")

        if not isinstance(self.input_model, type) or not issubclass(
            self.input_model,
            BaseModel,
        ):
            raise TypeError(f"tool '{name}' input_model must be a Pydantic model")

        if not isinstance(self.output_model, type) or not issubclass(
            self.output_model,
            BaseModel,
        ):
            raise TypeError(f"tool '{name}' output_model must be a Pydantic model")

        if not callable(self.handler):
            raise TypeError(f"tool '{name}' handler must be callable")

        object.__setattr__(self, "name", name)
        object.__setattr__(self, "description", description)

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


async def _maybe_await(value: Any) -> Any:
    """Await awaitables while allowing synchronous test handlers."""
    if inspect.isawaitable(value):
        return await value
    return value


def _is_sensitive_key(key: object) -> bool:
    """Return whether a mapping key conventionally contains a secret."""
    if not isinstance(key, str):
        return False

    normalized = key.strip().lower().replace("-", "_")
    return normalized in _SENSITIVE_KEYS


def _scrub_sensitive(value: Any) -> Any:
    """Recursively redact common secret-bearing mapping fields."""
    if isinstance(value, Mapping):
        return {
            key: (_REDACTED if _is_sensitive_key(key) else _scrub_sensitive(item))
            for key, item in value.items()
        }

    if isinstance(value, (list, tuple, set, frozenset)):
        return [_scrub_sensitive(item) for item in value]

    return value


def _stable_json(value: Any) -> str:
    """Serialize tracing values deterministically and safely."""
    scrubbed = _scrub_sensitive(value)

    try:
        return json.dumps(
            scrubbed,
            default=str,
            sort_keys=True,
            separators=(",", ":"),
        )
    except TypeError, ValueError:
        return repr(scrubbed)


class ToolRegistry:
    """Thread-safe registry and execution dispatcher for Tool objects."""

    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}
        self._lock = RLock()

    def register(self, tool: Tool) -> None:
        """Register a tool, rejecting duplicate names."""
        with self._lock:
            if tool.name in self._tools:
                raise ToolError(
                    f"Tool '{tool.name}' is already registered; tool names must be unique"
                )
            self._tools[tool.name] = tool

    def unregister(self, name: str) -> None:
        """Remove a tool by name. No-op if absent."""
        with self._lock:
            self._tools.pop(name, None)

    def __contains__(self, name: str) -> bool:
        with self._lock:
            return name in self._tools

    def __len__(self) -> int:
        with self._lock:
            return len(self._tools)

    def __iter__(self) -> Iterator[Tool]:
        with self._lock:
            snapshot = tuple(self._tools.values())
        return iter(snapshot)

    def get(self, name: str) -> Tool:
        """Return a registered tool or raise ToolNotFoundError."""
        with self._lock:
            tool = self._tools.get(name)

        if tool is None:
            raise ToolNotFoundError(f"Tool '{name}' is not registered")

        return tool

    def list_tools(self) -> list[Tool]:
        """Return a snapshot of currently registered tools."""
        with self._lock:
            return list(self._tools.values())

    def schemas(self) -> list[dict[str, Any]]:
        """Return tool schemas sorted by name for deterministic prompts."""
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

        if not isinstance(raw_args, Mapping):
            raise ToolExecutionError(
                name,
                TypeError("tool arguments must be a mapping"),
            )

        args_dict = dict(raw_args)
        input_json = _stable_json(args_dict)

        tracer = trace.get_tracer("autosre.tools")

        with tracer.start_as_current_span(
            f"tool.{name}",
            attributes={
                SpanAttributes.OPENINFERENCE_SPAN_KIND: "TOOL",
                SpanAttributes.TOOL_NAME: name,
                SpanAttributes.TOOL_PARAMETERS: input_json,
            },
        ) as span:
            # Step 1: Validate input
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

            # Step 2: Execute handler
            try:
                result = await _maybe_await(
                    tool.handler(
                        validated_input,
                        context,
                    )
                )
            except ToolExecutionError as exc:
                span.record_exception(exc)
                span.set_attribute(
                    "tool.error",
                    repr(exc.original),
                )
                span.set_status(
                    StatusCode.ERROR,
                    "tool rejected execution",
                )
                raise
            except Exception as exc:
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

            # Step 3: Validate output
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

            output_json = _stable_json(output_dict)

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
    """Return OpenAI-compatible tool schemas for registry."""
    return registry.schemas()


def build_default_registry(
    settings: Settings,  # noqa: ARG001
    context: SREContext,
) -> ToolRegistry:
    """Build the default registry with all built-in tool modules.

    Registers tools from:
    - k8s: Kubernetes diagnostics and remediation
    - postgres: Database diagnostics and connection management
    - observability: OpenObserve log/metric queries
    - valkey: Cache diagnostics and key management
    """
    from autosre.tools import k8s as k8s_tools
    from autosre.tools import observability as o11y_tools
    from autosre.tools import postgres as pg_tools
    from autosre.tools import valkey as valkey_tools

    registry = ToolRegistry()

    k8s_tools.register(registry, context)
    pg_tools.register(registry, context)
    o11y_tools.register(registry, context)
    valkey_tools.register(registry, context)

    return registry
