"""LangGraph-based incident runner replacing StubIncidentRunner."""

from __future__ import annotations

import logging
from typing import Any

from langchain_core.runnables import RunnableConfig
from langgraph.graph.state import CompiledStateGraph
from langgraph.types import Command

from autosre.core.graph_helpers import GraphContext
from autosre.core.state import (
    AgentState,
    IncidentMetadata,
    SREContext,
    create_initial_state,
)

logger = logging.getLogger(__name__)


class LangGraphRunner:
    """Run incidents through the real LangGraph state machine.

    Supports durable execution and HITL resume via ``Command(resume=...)``.
    """

    def __init__(
        self,
        graph: CompiledStateGraph[AgentState, Any, AgentState, AgentState],
        sre_context: SREContext,
        graph_context: GraphContext,
    ) -> None:
        self.graph = graph
        self.sre_context = sre_context
        self.graph_context = graph_context

    def _build_config(self, incident_id: str) -> RunnableConfig:
        """Build the LangGraph configuration for an incident thread."""
        return {
            "configurable": {
                "thread_id": incident_id,
                "sre_context": self.sre_context,
                "graph_context": self.graph_context,
            },
            "recursion_limit": 30,
        }

    async def run_incident(
        self,
        incident_id: str,
        alert: dict[str, Any],
    ) -> None:
        """Start an incident investigation.

        The graph runs until completion or until an interrupt pauses execution.
        """
        metadata = IncidentMetadata(
            incident_id=incident_id,
            alert_name=alert["alert_name"],
            service=alert["service"],
            namespace=alert["namespace"],
            severity=alert["severity"],
            started_at=alert["started_at"],
            fingerprint=alert["fingerprint"],
        )

        initial_state = create_initial_state(metadata)
        config = self._build_config(incident_id)

        logger.info(
            "Starting investigation for incident %s",
            incident_id,
        )

        try:
            await self.graph.ainvoke(initial_state, config=config)
        except Exception:
            logger.exception(
                "Investigation failed for incident %s",
                incident_id,
            )
            raise

        logger.info(
            "Completed investigation for incident %s",
            incident_id,
        )

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str,
    ) -> bool:
        """Resume an incident paused at a human interrupt.

        Returns ``True`` when a pending interrupt was found and resumed.
        Returns ``False`` when the incident does not exist or is not awaiting
        human input.
        """
        config = self._build_config(incident_id)

        state_snapshot = await self.graph.aget_state(config)

        if state_snapshot is None:
            logger.warning(
                "Incident %s not found for approval",
                incident_id,
            )
            return False

        if not state_snapshot.interrupts:
            logger.warning(
                "Incident %s is not awaiting human approval",
                incident_id,
            )
            return False

        logger.info(
            "Resuming incident %s with approval=%s, comment=%s",
            incident_id,
            approved,
            comment,
        )

        try:
            resume_value: dict[str, Any] = {
                "approved": approved,
                "comment": comment,
            }
            resume_command: Command[Any] = Command(
                resume=resume_value,
            )

            await self.graph.ainvoke(
                resume_command,
                config=config,
            )
        except Exception:
            logger.exception(
                "Failed to resume incident %s",
                incident_id,
            )
            return False

        logger.info(
            "Successfully resumed incident %s",
            incident_id,
        )
        return True
