"""OpenTelemetry bootstrap for target-system.

Uses the Azure Monitor OpenTelemetry distro when a connection string is
available; otherwise falls back to a console exporter.
Sampling is configurable via environment variables.
"""

from __future__ import annotations

import logging
import os
import socket
import threading
from typing import Final

from opentelemetry.sdk.resources import (
    SERVICE_INSTANCE_ID,
    SERVICE_NAME,
    SERVICE_VERSION,
    Resource,
)
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

from .config import config

logger = logging.getLogger(__name__)

_TELEMETRY_LOCK: Final = threading.Lock()
_TELEMETRY_INITIALIZED = False


def init_telemetry(service_name: str = "target-system", service_version: str = "1.0.0") -> bool:
    """Initialise tracing once per process.

    With a valid Application Insights connection string, the Azure Monitor
    distro is configured using sampling settings from the application config.
    Without Azure, spans are printed to stdout.
    """

    global _TELEMETRY_INITIALIZED
    with _TELEMETRY_LOCK:
        if _TELEMETRY_INITIALIZED:
            return True

        resource = Resource(
            attributes={
                SERVICE_NAME: service_name,
                SERVICE_VERSION: service_version,
                SERVICE_INSTANCE_ID: _service_instance_id(),
                "deployment.environment": os.getenv("ENVIRONMENT", "development"),
            }
        )

        connection_string = config.appinsights_connection_string
        if connection_string:
            _configure_azure_monitor(
                connection_string=connection_string,
                resource=resource,
            )
            _TELEMETRY_INITIALIZED = True
            logger.info("Azure Monitor telemetry configured (mode=%s)", config.sampling_mode)
            return True

        # Fallback: console exporter for local development
        provider = TracerProvider(resource=resource)
        provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
        _set_tracer_provider(provider)
        _TELEMETRY_INITIALIZED = True
        logger.info("Console telemetry configured")
        return True


def _configure_azure_monitor(*, connection_string: str, resource: Resource) -> None:
    """Configure the Azure Monitor distro with sampling."""
    from azure.monitor.opentelemetry import configure_azure_monitor

    kwargs = {
        "connection_string": connection_string,
        "resource": resource,
    }

    # Apply sampling based on mode
    mode = config.sampling_mode
    if mode == "rate":
        kwargs["traces_per_second"] = config.traces_per_second
        logger.info(
            "Azure Monitor sampling: rate-limited (%s traces/sec)", config.traces_per_second
        )
    elif mode == "ratio":
        kwargs["sampling_ratio"] = config.sampling_ratio
        logger.info("Azure Monitor sampling: fixed ratio (%s)", config.sampling_ratio)
    else:  # "off" or unrecognised
        logger.info("Azure Monitor sampling: off (100%% collection)")

    if config.enable_live_metrics:
        kwargs["enable_live_metrics"] = True
        logger.info("Azure Monitor Live Metrics enabled")

    configure_azure_monitor(**kwargs)


def _set_tracer_provider(provider: TracerProvider) -> None:
    """Set the global tracer provider safely."""
    from opentelemetry import trace

    try:
        trace.set_tracer_provider(provider)
    except Exception:
        logger.exception("Tracer provider was already configured; keeping the existing provider")


def _service_instance_id() -> str:
    return os.getenv("SERVICE_INSTANCE_ID") or socket.gethostname()
