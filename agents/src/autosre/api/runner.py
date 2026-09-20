"""Incident runner protocol and Phase 8 stub implementation."""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


class StubIncidentRunner:
    """In-memory stub that records incidents for test inspection.

    This is a Phase 8 placeholder. Phase 9 will replace it with a
    LangGraph-based runner using AsyncPostgresSaver for persistence.
    """

    def __init__(self) -> None:
        self._incidents: dict[str, dict[str, Any]] = {}

    async def run_incident(self, incident_id: str, alert: dict[str, Any]) -> None:
        """Record an incident as awaiting HITL approval."""
        logger.info(
            "StubIncidentRunner: Starting incident %s for %s",
            incident_id,
            alert.get("service", "unknown"),
        )

        self._incidents[incident_id] = {
            "incident_id": incident_id,
            "alert": dict(alert),
            "phase": "awaiting_approval",
            "approval": None,
        }

        logger.info(
            "StubIncidentRunner: Incident %s paused for HITL approval",
            incident_id,
        )

    async def approve_incident(self, incident_id: str, approved: bool, comment: str) -> bool:
        """Record an approval decision. Returns True if incident was found."""
        incident = self._incidents.get(incident_id)
        if incident is None:
            logger.warning("StubIncidentRunner: Incident %s not found", incident_id)
            return False

        if incident["phase"] != "awaiting_approval":
            logger.warning(
                "StubIncidentRunner: Incident %s not awaiting approval (phase=%s)",
                incident_id,
                incident["phase"],
            )
            return False

        incident["approval"] = {
            "approved": approved,
            "comment": comment,
        }
        incident["phase"] = "approved" if approved else "rejected"

        logger.info(
            "StubIncidentRunner: Incident %s %s (comment: %s)",
            incident_id,
            "approved" if approved else "rejected",
            comment,
        )
        return True

    def get_incident(self, incident_id: str) -> dict[str, Any] | None:
        """Return a copy of the incident record, or None if not found."""
        incident = self._incidents.get(incident_id)
        if incident is None:
            return None
        return dict(incident)
