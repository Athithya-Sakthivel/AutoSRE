"""Protocol contract for LangGraph runner implementations.

This module defines the interface that main.py, routes.py, and tests depend
on. Both LangGraphRunner and any test doubles must satisfy this Protocol.

This uses Python's structural subtyping via typing.Protocol. Any class with
matching method signatures automatically implements this Protocol without
explicit inheritance.

The Protocol defines 4 methods for incident lifecycle management:

- run_incident(alert): Trigger a new incident investigation
- get_incident_state(incident_id): Retrieve current state of an incident
- list_incidents(limit): List all incidents from the checkpointer
- approve_incident(incident_id, approved, comment): Approve or reject a
  pending Tier-2+ action

The concrete implementation is LangGraphRunner in src/autosre/api/runner.py.
"""

from __future__ import annotations

from typing import Any, Protocol


class RunnerProtocol(Protocol):
    """Contract for incident lifecycle operations."""

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Trigger a new incident investigation."""
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
