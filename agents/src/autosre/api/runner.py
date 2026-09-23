"""LangGraph runner for incident investigation.

Wraps the compiled graph with incident lifecycle methods:
- run_incident: start a new investigation from an alert webhook
- approve_incident: resume a paused investigation with HITL approval
"""

from __future__ import annotations

import logging
from typing import Any

from langchain_core.runnables import RunnableConfig
from langgraph.errors import GraphRecursionError
from langgraph.graph.state import CompiledStateGraph
from langgraph.types import Command

from autosre.core.graph_helpers import GraphContext
from autosre.core.state import (
    IncidentMetadata,
    SREContext,
    create_initial_state,
)

logger = logging.getLogger(__name__)


# LangGraph 1.2.x:
# CompiledStateGraph[StateT, ContextT, InputT, OutputT]
#
# The graph is constructed dynamically around the application's AgentState,
# so this runner boundary intentionally keeps the concrete generic parameters
# as Any rather than pretending to know a narrower type here.
type CompiledGraph = CompiledStateGraph[Any, Any, Any, Any]


class LangGraphRunner:
    """Run incidents through the compiled LangGraph state machine.

    Supports durable execution via an AsyncPostgresSaver checkpointer
    and HITL resume via Command(resume=...).
    """

    def __init__(
        self,
        graph: CompiledGraph,
        sre_context: SREContext,
        graph_context: GraphContext,
    ) -> None:
        self.graph: CompiledGraph = graph
        self.sre_context: SREContext = sre_context
        self.graph_context: GraphContext = graph_context

    def _build_config(self, incident_id: str) -> RunnableConfig:
        """Build the LangGraph RunnableConfig for an incident thread."""
        return RunnableConfig(
            configurable={
                "thread_id": incident_id,
                "sre_context": self.sre_context,
                "graph_context": self.graph_context,
            },
            recursion_limit=60,
        )

    async def run_incident(
        self,
        incident_id: str,
        alert: dict[str, Any],
    ) -> None:
        """Start a new incident investigation.

        The graph runs until completion or until an interrupt pauses execution
        for human approval. GraphRecursionError is handled locally so an
        exhausted investigation does not propagate through the HTTP layer.
        """
        raw_labels = alert.get("labels")
        labels: dict[str, str] = dict(raw_labels) if isinstance(raw_labels, dict) else {}

        raw_annotations = alert.get("annotations")
        annotations: dict[str, str] = (
            dict(raw_annotations) if isinstance(raw_annotations, dict) else {}
        )

        metadata = IncidentMetadata(
            incident_id=incident_id,
            alert_name=str(alert.get("alert_name", "Unknown")),
            service=str(alert.get("service", "unknown")),
            namespace=str(alert.get("namespace", "default")),
            severity=str(alert.get("severity", "medium")),
            started_at=str(alert.get("started_at", "")),
            fingerprint=str(
                alert.get("fingerprint", incident_id),
            ),
            description=str(
                alert.get("description", ""),
            ),
            labels=labels,
            annotations=annotations,
        )

        initial_state = create_initial_state(metadata)
        config = self._build_config(incident_id)

        logger.info(
            "Starting investigation for incident %s",
            incident_id,
        )

        try:
            await self.graph.ainvoke(
                initial_state,
                config=config,
            )
        except GraphRecursionError:
            logger.error(
                "Investigation hit recursion limit for incident %s",
                incident_id,
            )
        except Exception:
            logger.exception(
                "Investigation failed for incident %s",
                incident_id,
            )

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

        Returns True when a pending graph state was found and the resume
        command was successfully submitted.

        Returns False when the incident does not exist, is not paused,
        or resumption fails.
        """
        config = self._build_config(incident_id)

        try:
            state_snapshot = await self.graph.aget_state(config)
        except Exception:
            logger.exception(
                "Failed to retrieve state for incident %s",
                incident_id,
            )
            return False

        if state_snapshot is None:
            logger.warning(
                "Incident %s not found for approval",
                incident_id,
            )
            return False

        # LangGraph exposes pending next nodes when execution is paused
        # at an interrupt/HITL boundary.
        next_nodes = state_snapshot.next
        if not next_nodes:
            logger.warning(
                "Incident %s is not awaiting human approval",
                incident_id,
            )
            return False

        logger.info(
            "Resuming incident %s with approval=%s",
            incident_id,
            approved,
        )

        resume_command: Command[Any] = Command(
            resume={
                "approved": approved,
                "comment": comment,
            },
        )

        try:
            await self.graph.ainvoke(
                resume_command,
                config=config,
            )
        except GraphRecursionError:
            logger.error(
                "Resumed investigation hit recursion limit for incident %s",
                incident_id,
            )
            return False
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
