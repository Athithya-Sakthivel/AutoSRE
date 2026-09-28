"""Protocol contract for LangGraph runner implementations.

This module defines the interface that routes.py and the eval harness
depend on. Both LangGraphRunner and any test doubles must satisfy this
Protocol structurally.

The Protocol defines six methods for incident lifecycle management:

    run_incident(alert)                Trigger and block until complete
    schedule_incident(alert)           Trigger and return immediately
    get_incident_state(incident_id)    Retrieve current state
    list_incidents(limit)              List all incidents
    approve_incident(id, ...)          Resume a paused HITL interrupt
    shutdown(timeout)                  Drain background tasks

The concrete implementation is LangGraphRunner in api/runner.py.
"""

from __future__ import annotations

from typing import Any, Protocol


class RunnerProtocol(Protocol):
    """Contract for incident lifecycle operations."""

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Execute an investigation to completion; return the incident_id.

        Blocking. The HTTP webhook handler MUST NOT use this method;
        use ``schedule_incident`` instead.
        """
        ...

    async def schedule_incident(self, alert: dict[str, Any]) -> str:
        """Start an investigation in the background; return the incident_id.

        Non-blocking. Returns within milliseconds. The graph runs in a
        task tracked by the runner.
        """
        ...

    async def get_incident_state(self, incident_id: str) -> Any | None:
        """Retrieve the current state of an incident."""
        ...

    async def list_incidents(self, limit: int = 100) -> list[tuple[str, Any]]:
        """List all incidents from the checkpointer."""
        ...

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "",
    ) -> bool:
        """Approve or reject a pending Tier-2+ action."""
        ...

    async def shutdown(self, timeout: float = 30.0) -> None:
        """Drain background tasks. Called from the FastAPI lifespan."""
        ...
