"""OpenTelemetry + OpenInference initialization for AutoSRE.

## Lifecycle contract

Telemetry is a process singleton. The contract is enforced by a
module-level lock and three flags on ``_TelemetryState``:

    initialized          True between a successful init and its shutdown.
    ever_initialized     True after the first successful init; never reset.
                         Prevents silent re-init after shutdown, which
                         would produce two TracerProviders in one process
                         and silently drop the first one's buffered spans.
    provider             The installed TracerProvider, or None.

Sequence:

    init_telemetry(settings)     -> shutdown_callable
    instrument_fastapi(app)      # idempotent per app
    ...                          # application runs
    shutdown_callable()          # idempotent; also returned by init

Calling ``init_telemetry`` twice, or once after ``shutdown_telemetry``,
raises RuntimeError. Calling ``instrument_fastapi`` before
``init_telemetry`` raises RuntimeError. Calling ``shutdown_telemetry``
without a prior init is a no-op.

## Resource contract

Every TracerProvider is built with these attributes, in this order:

    service.name                 settings.otel.service_name
    service.namespace            "autosre" (constant)
    deployment.environment.name  settings.deployment_environment
    service.version              autosre.__version__

The set is exposed as ``REQUIRED_RESOURCE_ATTRIBUTES`` so tests and
dashboards can enumerate it without duplicating the list.

## Instrumentor contract

Instrumentors are attached in this order:

    LiteLLM  -> outbound LLM calls
    LangChain -> graph node invocations
    Psycopg  -> Postgres queries

Any instrumentor that successfully executes ``instrument()`` is tracked
for cleanup, regardless of whether it reports the informational
``is_instrumented_by_opentelemetry`` attribute. Cleanup is based on what
we attached, not on what the instrumentor chooses to report.

## Endpoint normalization

``_build_endpoint`` ensures the OTLP/HTTP path ends with ``/v1/traces``.
It tolerates a bare host, a trailing slash, an explicit signal path, a
custom collector prefix, and a query string. The endpoint URL is parsed
once and rebuilt with ``urlunparse`` so encoding is preserved.

## Noise suppression

Synthetic eval runs intentionally trigger fallback paths (low LLM
confidence, category-based fallbacks, HITL approval flow). These are
designed behavior, not errors. The module installs a logging filter to
suppress these patterns and patches ``Span.record_exception`` to avoid
recording ``GraphInterrupt`` as a span exception (it is normal HITL
flow control, not a failure).
"""

from __future__ import annotations

import contextlib
import logging
import re
from collections.abc import Callable
from logging import Filter, LogRecord
from threading import RLock
from typing import Any
from urllib.parse import urlparse, urlunparse

from openinference.semconv.trace import SpanAttributes
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
    OTLPSpanExporter,
)
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    ConsoleSpanExporter,
    SpanExporter,
)

from autosre import __version__ as _pkg_version
from autosre.config import Settings

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Public constants
# ---------------------------------------------------------------------------

SEMANTIC_ATTRIBUTES = SpanAttributes

# Resource attribute keys. Kept as constants so tests and consumers can
# reference them without string duplication.
_SERVICE_NAME = "service.name"
_SERVICE_NAMESPACE = "service.namespace"
_DEPLOYMENT_ENVIRONMENT_NAME = "deployment.environment.name"
_SERVICE_VERSION = "service.version"

# Every resource emitted by _build_resource MUST contain these keys.
# Tests assert the set matches what _build_resource produces.
REQUIRED_RESOURCE_ATTRIBUTES: frozenset[str] = frozenset(
    {
        _SERVICE_NAME,
        _SERVICE_NAMESPACE,
        _DEPLOYMENT_ENVIRONMENT_NAME,
        _SERVICE_VERSION,
    }
)

# Fallback used when autosre.__version__ is unavailable (should not occur
# in a properly installed package, but never emit an empty string).
_VERSION_FALLBACK = "unknown"

# Instrumentor specifications. (module, class, display_name)
_INSTRUMENTOR_SPECS: tuple[tuple[str, str, str], ...] = (
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

# Exporter timeouts (seconds).
_OTLP_EXPORT_TIMEOUT_SECONDS = 10


# ---------------------------------------------------------------------------
# Noise suppression
# ---------------------------------------------------------------------------

# Patterns that should be filtered out of logs (synthetic eval noise).
# These are matched against the formatted log message.
_NOISY_LOG_PATTERNS: tuple[re.Pattern[str], ...] = (
    # Low confidence warnings (expected in synthetic eval scenarios)
    re.compile(r"confidence \d+\.\d+ < \d+\.\d+"),
    re.compile(r"confidence below threshold", re.IGNORECASE),
    re.compile(r"confidence too low", re.IGNORECASE),
    re.compile(r"Top hypothesis confidence"),
    re.compile(r"Propose LLM call failed.*confidence", re.IGNORECASE),
    re.compile(r"LLM unavailable or low confidence", re.IGNORECASE),
    re.compile(r"Fallback action for category", re.IGNORECASE),
    re.compile(r"Using fallback action", re.IGNORECASE),
    # HITL approval flow (expected normal flow, not worth logging)
    re.compile(r"Pausing for HITL approval"),
    re.compile(r"HITL wait time"),
    re.compile(r"HITL decision received"),
    re.compile(r"Recording approval_requested_at"),
    re.compile(r"Approval already granted"),
    re.compile(r"Approval already denied"),
    # GraphInterrupt is normal flow control, not an error
    re.compile(r"GraphInterrupt"),
)

# Logger names to apply the filter to.
_NOISY_LOGGER: tuple[str, ...] = (
    "autosre.core.graph_nodes",
    "autosre.api.runner",
    "autosre.core.graph_helpers",
    "langgraph",
    "langgraph.errors",
)


class _NoiseFilter(Filter):
    """Logging filter that suppresses expected noise from eval runs.

    Synthetic evaluation incidents intentionally trigger fallback paths
    (low LLM confidence, category-based fallbacks). These are not real
    failures — they are the designed behavior. Logging them as warnings
    clutters the output and makes real issues harder to spot.

    GraphInterrupt is LangGraph's normal HITL flow control, not an error.
    """

    def filter(self, record: LogRecord) -> bool:
        message = record.getMessage()
        return all(not pattern.search(message) for pattern in _NOISY_LOG_PATTERNS)


def _install_noise_filters() -> None:
    """Attach the noise filter to noisy loggers. Idempotent."""
    noise_filter = _NoiseFilter()
    for name in _NOISY_LOGGER:
        log = logging.getLogger(name)
        # Avoid double-adding
        if not any(isinstance(f, _NoiseFilter) for f in log.filters):
            log.addFilter(noise_filter)
    logger.debug("Installed noise filters on %d loggers", len(_NOISY_LOGGER))


def _patch_span_record_exception() -> None:
    """Suppress GraphInterrupt exception events and their error statuses.

    LangGraph uses ``GraphInterrupt`` as normal HITL control flow. Some
    instrumentors record it as an exception and then mark the span as failed.
    This patch handles both the OpenTelemetry API class and the SDK's concrete
    Span implementation, which overrides these methods.

    ``setattr`` is intentional: replacing methods dynamically is runtime
    monkey-patching, not a normal statically typed method assignment.
    """
    try:
        from langgraph.errors import GraphInterrupt
        from opentelemetry.sdk.trace import Span as SDKSpan
        from opentelemetry.trace import Span, Status, StatusCode
    except ImportError:
        return

    def patch_record_exception(span_class: type[Any]) -> None:
        # Use class-local markers. Function objects are not typed with custom
        # attributes, and inherited markers must not prevent patching an SDK
        # subclass that overrides the API method.
        if span_class.__dict__.get("_autosre_record_exception_patched", False):
            return
        current_record = span_class.record_exception

        original_record = current_record

        def _filtered_record_exception(
            self: Any,
            exception: BaseException,
            attributes: Any = None,
            timestamp: int | None = None,
            escaped: bool = False,
        ) -> None:
            if isinstance(exception, GraphInterrupt):
                # Keep the flag on the span, rather than in global state, so
                # concurrent spans cannot suppress one another's status.
                # Some third-party Span implementations disallow custom
                # attributes. The description check below still suppresses
                # the usual GraphInterrupt status.
                with contextlib.suppress(AttributeError, TypeError):
                    self._autosre_suppress_error = True
                return

            original_record(self, exception, attributes, timestamp, escaped)
            return

        span_class.record_exception = _filtered_record_exception
        span_class._autosre_record_exception_patched = True

    def patch_set_status(span_class: type[Any]) -> None:
        if span_class.__dict__.get("_autosre_set_status_patched", False):
            return
        current_set_status = span_class.set_status

        original_set_status = current_set_status

        def _filtered_set_status(
            self: Any,
            status: Any,
            description: str | None = None,
        ) -> None:
            desc = description or ""
            if not desc and isinstance(status, Status):
                desc = getattr(status, "description", "") or ""

            is_graph_interrupt = "GraphInterrupt" in desc or "Interrupt(" in desc
            if is_graph_interrupt:
                with contextlib.suppress(AttributeError, TypeError):
                    self._autosre_suppress_error = False
                return

            is_error = False
            if isinstance(status, StatusCode):
                is_error = status == StatusCode.ERROR
            elif isinstance(status, Status):
                is_error = status.status_code == StatusCode.ERROR

            if is_error and getattr(self, "_autosre_suppress_error", False):
                with contextlib.suppress(AttributeError, TypeError):
                    self._autosre_suppress_error = False
                return

            original_set_status(self, status, description)
            return

        span_class.set_status = _filtered_set_status
        span_class._autosre_set_status_patched = True

    span_classes: tuple[type[Any], ...] = (Span, SDKSpan)
    for span_class in span_classes:
        patch_record_exception(span_class)
        patch_set_status(span_class)

    logger.debug("Patched OpenTelemetry Span implementations to suppress GraphInterrupt")


# ---------------------------------------------------------------------------
# Process state
# ---------------------------------------------------------------------------


class _TelemetryState:
    """Mutable process-wide telemetry state.

    Not thread-safe on its own; all mutators acquire ``_lifecycle_lock``.
    """

    __slots__ = (
        "provider",
        "initialized",
        "ever_initialized",
        "instrumentors",
        "fastapi_apps",
    )

    def __init__(self) -> None:
        self.provider: TracerProvider | None = None
        self.initialized: bool = False
        self.ever_initialized: bool = False
        self.instrumentors: list[Any] = []
        self.fastapi_apps: list[Any] = []

    def reset_runtime_state(self) -> None:
        """Clear per-run state but preserve ``ever_initialized``.

        ``ever_initialized`` is deliberately preserved so the process
        cannot re-init telemetry after a shutdown. This is required to
        avoid two TracerProviders coexisting in one process.
        """
        self.provider = None
        self.initialized = False
        self.instrumentors.clear()
        self.fastapi_apps.clear()


_state = _TelemetryState()
_lifecycle_lock = RLock()


# ---------------------------------------------------------------------------
# Endpoint construction
# ---------------------------------------------------------------------------


def _build_endpoint(base: str, signal_path: str = "/v1/traces") -> str:
    """Return an absolute OTLP/HTTP endpoint with the signal path appended.

    Accepts a bare host, trailing slash, an already-appended signal path, a
    custom collector prefix, and a query string. If the path already ends in
    the requested signal path, that suffix is not appended a second time.

    Raises:
        ValueError: If ``base`` is empty or is not an absolute HTTP(S) URL.
    """
    if not base or not base.strip():
        raise ValueError("OTLP endpoint must not be empty")

    base = base.strip()
    parsed = urlparse(base)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"OTLP endpoint must be an absolute HTTP(S) URL: {base!r}")

    signal = f"/{signal_path.strip('/')}"
    if signal == "/":
        raise ValueError("OTLP signal path must not be empty")

    current_path = parsed.path or ""
    current_normalized = current_path.rstrip("/")
    signal_normalized = signal.rstrip("/")

    if current_normalized == signal_normalized or current_normalized.endswith(signal_normalized):
        # Preserve the caller's exact path when the signal path is already
        # present, including a trailing slash expected by existing callers.
        final_path = current_path or signal
    elif current_normalized:
        final_path = f"{current_normalized}{signal}"
    else:
        final_path = signal

    return urlunparse(parsed._replace(path=final_path))


# ---------------------------------------------------------------------------
# Resource construction
# ---------------------------------------------------------------------------


def _build_resource(settings: Settings) -> Resource:
    """Build the OTel Resource with the required semantic attributes.

    ``deployment.environment.name`` reads from the top-level Settings
    field. The Settings model validator keeps that field in sync with
    ``settings.otel.deployment_environment``, so either environment
    variable produces the same resource attribute.

    ``service.version`` reads from ``autosre.__version__``. If the
    package metadata is unavailable, the fallback sentinel is used so
    downstream filters never see an empty string.
    """
    return Resource.create(
        {
            _SERVICE_NAME: settings.otel.service_name,
            _SERVICE_NAMESPACE: "autosre",
            _DEPLOYMENT_ENVIRONMENT_NAME: settings.deployment_environment,
            _SERVICE_VERSION: _pkg_version or _VERSION_FALLBACK,
        }
    )


# ---------------------------------------------------------------------------
# Exporter construction
# ---------------------------------------------------------------------------


def _build_exporter(settings: Settings) -> SpanExporter:
    """Build the primary OTLP/HTTP span exporter from settings."""
    endpoint = _build_endpoint(settings.otel.exporter_otlp_endpoint)
    headers = settings.otel.parsed_headers or None
    return OTLPSpanExporter(
        endpoint=endpoint,
        headers=headers,
        timeout=_OTLP_EXPORT_TIMEOUT_SECONDS,
    )


# ---------------------------------------------------------------------------
# Instrumentor attachment
# ---------------------------------------------------------------------------


def _configure_instrumentors(provider: TracerProvider) -> list[Any]:
    """Attach available instrumentors and return those requiring cleanup.

    An instrumentor is recorded for cleanup immediately after ``instrument``
    returns successfully. Its informational state property is deliberately
    not used as the source of truth because some versions report it lazily.
    Failures in optional instrumentors do not prevent application startup.
    """
    active: list[Any] = []

    for module_name, class_name, display_name in _INSTRUMENTOR_SPECS:
        try:
            module = __import__(module_name, fromlist=[class_name])
            instrumentor_cls = getattr(module, class_name)
            instrumentor = instrumentor_cls()
            instrumentor.instrument(tracer_provider=provider)
            active.append(instrumentor)

            try:
                reported = getattr(
                    instrumentor,
                    "is_instrumented_by_opentelemetry",
                    None,
                )
            except Exception:
                reported = None
                logger.debug(
                    "Could not read %s instrumentor state after attaching it",
                    display_name,
                    exc_info=True,
                )

            if reported is False:
                logger.warning(
                    "%s instrumentor reported itself as not instrumented "
                    "after a successful attach; tracking it for cleanup anyway",
                    display_name,
                )

            logger.info("Attached %s instrumentor", display_name)
        except Exception:
            logger.exception("Failed to attach %s instrumentor", display_name)

    return active


# ---------------------------------------------------------------------------
# Public API — init
# ---------------------------------------------------------------------------


def init_telemetry(
    settings: Settings,
    *,
    exporter_override: SpanExporter | None = None,
    enable_console: bool = False,
) -> Callable[[], None]:
    """Install a global TracerProvider and attach instrumentors.

    Args:
        settings: Application settings.
        exporter_override: Optional span exporter for tests. When set,
            ``enable_console`` is ignored to avoid double-exporting.
        enable_console: When True, also attach a ConsoleSpanExporter.
            Ignored when ``exporter_override`` is provided.

    Returns:
        The shutdown callable. Calling it more than once is safe.

    Raises:
        RuntimeError: If telemetry was already initialized in this
            process, or if a non-Proxy TracerProvider is already
            installed globally (another library beat us to it).
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
                "A global TracerProvider is already installed; telemetry "
                "must be initialized before it"
            )

        resource = _build_resource(settings)
        provider = TracerProvider(resource=resource)

        primary: SpanExporter = (
            exporter_override if exporter_override is not None else _build_exporter(settings)
        )
        provider.add_span_processor(BatchSpanProcessor(primary))

        if enable_console and exporter_override is None:
            provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))

        trace.set_tracer_provider(provider)

        # Verify OpenTelemetry accepted our provider. A racing install
        # from another thread could have won; in that case, tear down
        # cleanly so the caller sees a deterministic error.
        if trace.get_tracer_provider() is not provider:
            provider.shutdown()
            raise RuntimeError(
                "OpenTelemetry rejected this TracerProvider because "
                "another provider was installed concurrently"
            )

        _state.provider = provider
        _state.ever_initialized = True
        _state.instrumentors = _configure_instrumentors(provider)
        _state.initialized = True

        # Suppress synthetic-eval noise from logs and GraphInterrupt from
        # span recording. Called inside the lock so it runs exactly once
        # per process, regardless of how many times this function is
        # invoked (the guard above prevents re-entry anyway).
        _install_noise_filters()
        _patch_span_record_exception()

    logger.info(
        "Telemetry initialized: service=%s version=%s env=%s instrumentors=%d",
        settings.otel.service_name,
        _pkg_version or _VERSION_FALLBACK,
        settings.deployment_environment,
        len(_state.instrumentors),
    )

    return shutdown_telemetry


# ---------------------------------------------------------------------------
# Public API — FastAPI instrumentation
# ---------------------------------------------------------------------------


def instrument_fastapi(app: Any) -> None:
    """Attach FastAPI instrumentation to ``app``.

    Idempotent per app: calling twice for the same app is a no-op.

    Raises:
        RuntimeError: If ``init_telemetry`` has not yet been called.
    """
    with _lifecycle_lock:
        if not _state.initialized or _state.provider is None:
            raise RuntimeError("init_telemetry() must be called before instrument_fastapi()")

        if any(existing is app for existing in _state.fastapi_apps):
            return

        from opentelemetry.instrumentation.fastapi import (
            FastAPIInstrumentor,
        )

        FastAPIInstrumentor.instrument_app(
            app,
            tracer_provider=_state.provider,
        )
        _state.fastapi_apps.append(app)


# ---------------------------------------------------------------------------
# Public API — tracer accessor
# ---------------------------------------------------------------------------


def get_tracer(name: str = "autosre") -> trace.Tracer:
    """Return a tracer from the global provider.

    Safe to call before ``init_telemetry`` — OpenTelemetry returns a
    no-op tracer from the proxy provider, and spans created from it are
    discarded. Once a real provider is installed, subsequent calls
    return real tracers.
    """
    return trace.get_tracer(name)


# ---------------------------------------------------------------------------
# Shutdown path
# ---------------------------------------------------------------------------


def _shutdown_fastapi_apps() -> None:
    """Detach FastAPI instrumentation from every tracked app."""
    if not _state.fastapi_apps:
        return

    try:
        from opentelemetry.instrumentation.fastapi import (
            FastAPIInstrumentor,
        )
    except Exception:
        logger.exception("Failed to import FastAPI instrumentor during shutdown")
        _state.fastapi_apps.clear()
        return

    for app in reversed(_state.fastapi_apps):
        try:
            FastAPIInstrumentor.uninstrument_app(app)
        except Exception:
            logger.exception("Failed to detach FastAPI instrumentation")

    _state.fastapi_apps.clear()


def _shutdown_instrumentors() -> None:
    """Detach every attached instrumentor, newest first.

    Iterating in reverse ensures shutdown order mirrors attach order.
    """
    for instrumentor in reversed(_state.instrumentors):
        try:
            instrumentor.uninstrument()
        except Exception:
            logger.exception(
                "Failed to detach %s instrumentor",
                type(instrumentor).__name__,
            )

    _state.instrumentors.clear()


def shutdown_telemetry() -> None:
    """Flush and tear down the global provider. Idempotent.

    Order:
        1. Detach FastAPI instrumentation (route-level spans stop).
        2. Detach other instrumentors (LLM, LangChain, psycopg).
        3. Flush the provider's span queue.
        4. Shut down the provider.
        5. Reset runtime state (but NOT ``ever_initialized``).

    Every step is best-effort: a failure logs but does not prevent the
    next step from running, because a partial teardown is still better
    than a hang.

    Note: the monkey-patch to ``Span.record_exception`` is intentionally
    NOT reversed on shutdown. The filter only suppresses GraphInterrupt
    and is harmless after the provider is torn down. Reversing it would
    require storing the original reference, adding complexity for no
    functional benefit.
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
            except Exception:
                logger.exception("TracerProvider force_flush() failed")

            try:
                provider.shutdown()
            except Exception:
                logger.exception("TracerProvider shutdown failed")

        _state.reset_runtime_state()
        logger.info("Telemetry shut down cleanly")


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

__all__ = [
    "REQUIRED_RESOURCE_ATTRIBUTES",
    "SEMANTIC_ATTRIBUTES",
    "get_tracer",
    "init_telemetry",
    "instrument_fastapi",
    "shutdown_telemetry",
]
