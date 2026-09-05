"""Production‑grade telemetry – Azure Monitor + OpenInference."""

from __future__ import annotations

import logging
import socket
from functools import lru_cache

from infra.config import Settings, load_settings

logger = logging.getLogger(__name__)
_INITIALIZED = False


def setup_telemetry(settings: Settings | None = None) -> None:
    """Configure Azure Monitor telemetry once per process.

    If no Application Insights connection string is available, telemetry
    is silently disabled (console logging only).
    """
    global _INITIALIZED
    if _INITIALIZED:
        return
    _INITIALIZED = True

    settings = settings or load_settings()

    if not settings.applicationinsights_connection_string:
        logger.warning(
            "APPLICATIONINSIGHTS_CONNECTION_STRING not set – Azure Monitor telemetry is DISABLED"
        )
        _setup_openinference()
        return

    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
    except ImportError:
        logger.warning("azure-monitor-opentelemetry not installed – telemetry disabled")
        _setup_openinference()
        return

    try:
        from opentelemetry.sdk.resources import Resource

        resource = Resource.create(
            {
                "service.name": settings.service_name,
                "service.version": settings.service_version,
                "deployment.environment": settings.environment,
                "service.instance.id": socket.gethostname(),
            }
        )
    except ImportError:
        resource = None

    kwargs = {
        "connection_string": settings.applicationinsights_connection_string,
        "logger_name": "agent-brain.telemetry",
        "enable_live_metrics": settings.enable_live_metrics,
    }
    if resource is not None:
        kwargs["resource"] = resource

    configure_azure_monitor(**kwargs)
    logger.info("Azure Monitor telemetry configured for %s", settings.service_name)

    _setup_openinference()


def _setup_openinference() -> None:
    try:
        from openinference.instrumentation.langchain import LangChainInstrumentor

        LangChainInstrumentor().instrument()
        logger.info("OpenInference LangChain instrumentation enabled")
    except ImportError:
        logger.warning("openinference-instrumentation-langchain not installed")
    except Exception:
        logger.exception("OpenInference instrumentation failed")


@lru_cache(maxsize=1)
def get_telemetry_logger() -> logging.Logger:
    return logging.getLogger("agent-brain.telemetry")


__all__ = ["setup_telemetry", "get_telemetry_logger"]
