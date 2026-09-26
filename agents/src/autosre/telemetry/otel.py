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
"""

from __future__ import annotations

import logging
from collections.abc import Callable
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
    """Return an OTLP/HTTP endpoint that ends with ``signal_path``.

    Accepts a bare host, a host with a trailing slash, an explicit
    signal path, a custom collector prefix, and a query string. The
    signal path is appended unless the current path already normalizes
    to it (trailing slashes ignored).

    Raises:
        ValueError: If ``base`` is empty or is not an absolute HTTP(S) URL.
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
    """Attach every available instrumentor to ``provider``.

    Returns:
        The list of instrumentors that successfully executed
        ``instrument()``. This list is the authoritative cleanup set;
        the informational ``is_instrumented_by_opentelemetry`` attribute
        is logged but not used for tracking, because some SDK versions
        set it lazily or not at all.

    Failures are logged and swallowed so a missing optional instrumentor
    cannot prevent application startup.
    """
    active: list[Any] = []

    for module_name, class_name, display_name in _INSTRUMENTOR_SPECS:
        try:
            module = __import__(module_name, fromlist=[class_name])
            instrumentor_cls = getattr(module, class_name)
            instrumentor = instrumentor_cls()
            instrumentor.instrument(tracer_provider=provider)

            reported = getattr(
                instrumentor,
                "is_instrumented_by_opentelemetry",
                None,
            )
            if reported is False:
                logger.warning(
                    "%s instrumentor reported itself as not instrumented "
                    "after a successful attach; tracking it for cleanup "
                    "anyway",
                    display_name,
                )

            active.append(instrumentor)
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
