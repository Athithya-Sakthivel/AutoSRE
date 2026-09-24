"""Protocol contract for LangGraph runner implementations.

This module defines the interface that main.py, routes.py, and tests depend on.
Both LangGraphRunner and any test doubles must satisfy this Protocol.

Structural subtyping (PEP 544): Any class with matching method signatures
automatically implements this Protocol without explicit inheritance.
"""

from __future__ import annotations

from typing import Any, Protocol


class RunnerProtocol(Protocol):
    """Contract for incident lifecycle operations.

    Methods:
        run_incident: Trigger a new incident investigation
        get_incident_state: Retrieve current state of an incident
        list_incidents: List all incidents from the checkpointer
        approve_incident: Approve or reject a pending Tier-2+ action
    """

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Trigger a new incident investigation.

        Args:
            alert: Alert payload with alert_name, service, namespace, etc.

        Returns:
            incident_id: UUID string identifying this incident thread.
        """
        ...

    async def get_incident_state(self, incident_id: str) -> Any | None:
        """Retrieve the current state of an incident.

        Args:
            incident_id: The incident thread ID.

        Returns:
            State object with .values attribute, or None if not found.
        """
        ...

    async def list_incidents(self, limit: int = 100) -> list[tuple[str, Any]]:
        """List all incidents from the checkpointer.

        Args:
            limit: Maximum number of incidents to return.

        Returns:
            List of (incident_id, state) tuples.
        """
        ...

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "",
    ) -> bool:
        """Approve or reject a pending Tier-2+ action.

        Args:
            incident_id: The incident thread ID.
            approved: True to approve, False to reject.
            comment: Optional comment from the approver.

        Returns:
            True if approval was recorded, False otherwise.
        """
        ...
