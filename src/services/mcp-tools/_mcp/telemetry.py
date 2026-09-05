"""OpenTelemetry bootstrap – production uses Azure Monitor, development uses console."""

from __future__ import annotations

import logging
import os
import socket
import threading
from typing import Final

from opentelemetry import trace
from opentelemetry.sdk.resources import SERVICE_INSTANCE_ID, SERVICE_NAME, SERVICE_VERSION, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

from .config import ConfigError, Settings

logger = logging.getLogger(__name__)

_TELEMETRY_LOCK: Final = threading.Lock()
_TELEMETRY_INITIALIZED = False


def init_telemetry(settings: Settings) -> None:
    """Configure Azure Monitor (production) or console (development)."""
    global _TELEMETRY_INITIALIZED
    with _TELEMETRY_LOCK:
        if _TELEMETRY_INITIALIZED:
            return

        resource = Resource(
            attributes={
                SERVICE_NAME: settings.service_name,
                SERVICE_VERSION: settings.service_version,
                SERVICE_INSTANCE_ID: _service_instance_id(),
                "deployment.environment": settings.environment,
            }
        )

        if settings.mode == "production":
            _init_azure_monitor(settings, resource)
        else:
            _init_console_exporter(resource)

        _TELEMETRY_INITIALIZED = True


def _init_azure_monitor(settings: Settings, resource: Resource) -> None:
    """Fail‑fast Azure Monitor configuration."""
    settings.require_observability()
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
    except ImportError as exc:
        raise ConfigError("azure-monitor-opentelemetry is required for production") from exc

    kwargs = {
        "connection_string": settings.applicationinsights_connection_string,
        "resource": resource,
        "enable_live_metrics": settings.enable_live_metrics,
    }
    if settings.sampling_mode == "rate":
        kwargs["traces_per_second"] = settings.traces_per_second
    elif settings.sampling_mode == "ratio":
        kwargs["sampling_ratio"] = settings.sampling_ratio
    # else "off" – no extra args

    configure_azure_monitor(**kwargs)
    logger.info("Azure Monitor telemetry configured (mode=%s)", settings.sampling_mode)


def _init_console_exporter(resource: Resource) -> None:
    """Simple console exporter for local development."""
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    logger.info("Console telemetry configured – no data sent to Azure")


def _service_instance_id() -> str:
    return os.getenv("SERVICE_INSTANCE_ID") or socket.gethostname()
