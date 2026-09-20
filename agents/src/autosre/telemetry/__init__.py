"""OpenTelemetry integration for AutoSRE agent."""

from autosre.telemetry.otel import (
    init_telemetry,
    instrument_fastapi,
    shutdown_telemetry,
)

__all__ = [
    "init_telemetry",
    "instrument_fastapi",
    "shutdown_telemetry",
]
