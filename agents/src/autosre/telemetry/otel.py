"""
OpenTelemetry + OpenInference initialization for AutoSRE.

This module owns the application's process-wide tracing provider, configures an
OTLP/HTTP trace exporter, and attaches the OpenInference/OpenTelemetry
instrumentors used by the application.

Lifecycle:
    1. Call ``init_telemetry(settings)`` exactly once per process.
    2. Call ``instrument_fastapi(app)`` after initialization and before serving.
    3. Call ``shutdown_telemetry()`` during process/application shutdown.

The OpenTelemetry API permits the global TracerProvider to be set only once.
Accordingly, this module does not support re-initializing telemetry after
shutdown in the same Python process.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from threading import RLock
from typing import Any
from urllib.parse import urlparse, urlunparse

from openinference.semconv.trace import SpanAttributes
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    ConsoleSpanExporter,
    SpanExporter,
)

from autosre.config import Settings

logger = logging.getLogger(__name__)

# Re-exported for callers that want OpenInference semantic-convention keys
# without importing the semantic-conventions package at every call site.
SEMANTIC_ATTRIBUTES = SpanAttributes

# Current stable OpenTelemetry resource attribute names.
_SERVICE_NAME = "service.name"
_SERVICE_NAMESPACE = "service.namespace"
_DEPLOYMENT_ENVIRONMENT_NAME = "deployment.environment.name"


class _TelemetryState:
    """Hold process-local references needed for deterministic lifecycle management."""

    def __init__(self) -> None:
        self.provider: TracerProvider | None = None
        self.initialized = False
        self.ever_initialized = False
        self.instrumentors: list[Any] = []
        self.fastapi_apps: list[Any] = []

    def reset_runtime_state(self) -> None:
        """Clear runtime references without allowing global-provider reinitialization."""
        self.provider = None
        self.initialized = False
        self.instrumentors.clear()
        self.fastapi_apps.clear()


_state = _TelemetryState()
_lifecycle_lock = RLock()


def _build_endpoint(base: str, signal_path: str = "/v1/traces") -> str:
    """Return an OTLP/HTTP signal endpoint derived from a base endpoint.

    ``base`` may be a host/root URL such as ``http://otel:4318`` or a URL with a
    collector prefix such as ``http://otel:4318/otlp``. The trace signal path is
    appended unless it is already the final path component.

    Query strings, fragments, scheme, authority, and any existing non-root path
    prefix are preserved.
    """
    if not base:
        raise ValueError("OTLP endpoint must not be empty")

    parsed = urlparse(base)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"OTLP endpoint must be an absolute HTTP(S) URL: {base!r}")

    signal = f"/{signal_path.lstrip('/')}"
    current_path = parsed.path or ""
    current_normalized = current_path.rstrip("/")
    signal_normalized = signal.rstrip("/")

    if current_normalized == signal_normalized:
        final_path = current_path or signal
    elif current_normalized:
        final_path = f"{current_normalized}{signal}"
    else:
        final_path = signal

    return urlunparse(parsed._replace(path=final_path))


def _build_resource(settings: Settings) -> Resource:
    """Build the OpenTelemetry Resource describing this service."""
    return Resource.create(
        {
            _SERVICE_NAME: settings.otel.service_name,
            _SERVICE_NAMESPACE: "autosre",
            _DEPLOYMENT_ENVIRONMENT_NAME: settings.deployment_environment,
        }
    )


def _build_exporter(settings: Settings) -> SpanExporter:
    """Construct the production OTLP/HTTP span exporter."""
    endpoint = _build_endpoint(settings.otel.exporter_otlp_endpoint)
    headers = settings.otel.parsed_headers or None

    return OTLPSpanExporter(
        endpoint=endpoint,
        headers=headers,
        timeout=10,
    )


def _configure_instrumentors(provider: TracerProvider) -> list[Any]:
    """Attach the supported instrumentors and return only successfully attached ones."""
    specs = (
        (
            "openinference.instrumentation.litellm",
            "LiteLLMInstrumentor",
            "LiteLLM",
        ),
        (
            "openinference.instrumentation.langchain",
            "LangChainInstrumentor",
            "LangChain",
        ),
        (
            "opentelemetry.instrumentation.psycopg",
            "PsycopgInstrumentor",
            "psycopg",
        ),
    )

    active: list[Any] = []

    for module_name, class_name, display_name in specs:
        try:
            module = __import__(module_name, fromlist=[class_name])
            instrumentor_cls = getattr(module, class_name)
            instrumentor = instrumentor_cls()
            instrumentor.instrument(tracer_provider=provider)

            if getattr(
                instrumentor,
                "is_instrumented_by_opentelemetry",
                False,
            ):
                active.append(instrumentor)
            else:
                logger.warning(
                    "%s instrumentor did not report itself as instrumented",
                    display_name,
                )
        except Exception:  # pragma: no cover - observability must not block app startup
            logger.exception("Failed to attach %s instrumentor", display_name)

    return active


def init_telemetry(
    settings: Settings,
    *,
    exporter_override: SpanExporter | None = None,
    enable_console: bool = False,
) -> Callable[[], None]:
    """Initialize the global OpenTelemetry provider and supported instrumentors.

    Args:
        settings: Validated application settings.
        exporter_override: Optional exporter used instead of the OTLP exporter,
            primarily for tests.
        enable_console: Add a console exporter in addition to the primary exporter.

    Returns:
        A zero-argument shutdown callable suitable for a FastAPI lifespan hook.

    Raises:
        RuntimeError: If telemetry was already initialized or another global
            tracer provider was installed before this function was called.
        ValueError: If the configured OTLP endpoint is invalid.
    """
    with _lifecycle_lock:
        if _state.initialized:
            raise RuntimeError("init_telemetry() called more than once")

        if _state.ever_initialized:
            raise RuntimeError(
                "init_telemetry() cannot be reinitialized after shutdown in the same process"
            )

        current_provider = trace.get_tracer_provider()
        if not isinstance(current_provider, trace.ProxyTracerProvider):
            raise RuntimeError(
                "A global TracerProvider is already installed; "
                "telemetry must be initialized before it"
            )

        resource = _build_resource(settings)
        provider = TracerProvider(resource=resource)

        primary = exporter_override if exporter_override is not None else _build_exporter(settings)
        provider.add_span_processor(BatchSpanProcessor(primary))

        if enable_console and exporter_override is None:
            provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))

        trace.set_tracer_provider(provider)

        # Guard against another subsystem winning the global-provider race.
        if trace.get_tracer_provider() is not provider:
            provider.shutdown()
            raise RuntimeError(
                "OpenTelemetry rejected this TracerProvider because another "
                "provider was installed concurrently"
            )

        _state.provider = provider
        _state.ever_initialized = True
        _state.instrumentors = _configure_instrumentors(provider)
        _state.initialized = True

    logger.info(
        "Telemetry initialized: service=%s env=%s",
        settings.otel.service_name,
        settings.deployment_environment,
    )

    return shutdown_telemetry


def instrument_fastapi(app: Any) -> None:
    """Attach OpenTelemetry instrumentation to one FastAPI application instance."""
    with _lifecycle_lock:
        if not _state.initialized or _state.provider is None:
            raise RuntimeError("init_telemetry() must be called before instrument_fastapi()")

        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        if any(existing is app for existing in _state.fastapi_apps):
            return

        FastAPIInstrumentor.instrument_app(
            app,
            tracer_provider=_state.provider,
        )
        _state.fastapi_apps.append(app)


def get_tracer(name: str = "autosre") -> trace.Tracer:
    """Return a tracer from the current global provider."""
    return trace.get_tracer(name)


def _shutdown_instrumentors() -> None:
    """Detach instrumentors that this module successfully attached."""
    for instrumentor in reversed(_state.instrumentors):
        try:
            instrumentor.uninstrument()
        except Exception:  # pragma: no cover - defensive cleanup
            logger.exception(
                "Failed to detach %s instrumentor",
                type(instrumentor).__name__,
            )

    _state.instrumentors.clear()


def _shutdown_fastapi_apps() -> None:
    """Detach FastAPI instrumentation from every app instance we instrumented."""
    if not _state.fastapi_apps:
        return

    try:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    except Exception:  # pragma: no cover - defensive cleanup
        logger.exception("Failed to import FastAPI instrumentor during shutdown")
        _state.fastapi_apps.clear()
        return

    for app in reversed(_state.fastapi_apps):
        try:
            FastAPIInstrumentor.uninstrument_app(app)
        except Exception:  # pragma: no cover - defensive cleanup
            logger.exception("Failed to detach FastAPI instrumentation")

    _state.fastapi_apps.clear()


def shutdown_telemetry() -> None:
    """Detach instrumentors, flush spans, and shut down the provider.

    Safe to call multiple times. The global provider remains registered after
    shutdown because the OpenTelemetry API does not support replacing it.
    """
    with _lifecycle_lock:
        if not _state.initialized:
            return

        _shutdown_fastapi_apps()
        _shutdown_instrumentors()

        provider = _state.provider
        if provider is not None:
            try:
                flushed = provider.force_flush()
                if not flushed:
                    logger.warning("TracerProvider force_flush() timed out")
            except Exception:  # pragma: no cover - defensive cleanup
                logger.exception("TracerProvider force_flush() failed")

            try:
                provider.shutdown()
            except Exception:  # pragma: no cover - defensive cleanup
                logger.exception("TracerProvider shutdown failed")

        _state.reset_runtime_state()
        logger.info("Telemetry shut down cleanly")
