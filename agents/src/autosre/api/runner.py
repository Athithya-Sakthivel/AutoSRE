"""LangGraph runner for AutoSRE agent.

Manages incident lifecycle: trigger, execute, approve, query state.
Supports durable execution via an AsyncPostgresSaver checkpointer.

Implements RunnerProtocol via structural subtyping (PEP 544).
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

logger = logging.getLogger(__name__)


class LangGraphRunner:
    """LangGraph runner for AutoSRE incident investigation.

    Satisfies RunnerProtocol structurally: any class with matching method
    signatures is compatible without explicit inheritance.

    The sre_context and graph_context are stored on the instance and
    injected into every RunnableConfig so graph nodes can access them
    via config["configurable"]["sre_context"] and
    config["configurable"]["graph_context"].
    """

    def __init__(
        self,
        graph: Any,
        checkpointer: AsyncPostgresSaver | None = None,
        sre_context: Any | None = None,
        graph_context: Any | None = None,
    ) -> None:
        self.graph = graph
        self.checkpointer = checkpointer
        self.sre_context = sre_context
        self.graph_context = graph_context

    def _build_config(self, incident_id: str) -> RunnableConfig:
        """Build a RunnableConfig with thread ID and injected contexts."""
        configurable: dict[str, Any] = {"thread_id": incident_id}

        if self.sre_context is not None:
            configurable["sre_context"] = self.sre_context
        if self.graph_context is not None:
            configurable["graph_context"] = self.graph_context

        return {"configurable": configurable}

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Run an incident investigation. Returns incident_id."""
        incident_id = str(uuid.uuid4())
        config = self._build_config(incident_id)

        initial_state = {
            "incident_metadata": {
                "incident_id": incident_id,
                "alert_name": alert.get("alert_name", ""),
                "service": alert.get("service", ""),
                "namespace": alert.get("namespace", ""),
                "severity": alert.get("severity", ""),
                "started_at": alert.get("started_at", ""),
                "fingerprint": alert.get("fingerprint", ""),
                "description": alert.get("description", ""),
                "labels": alert.get("labels", {}),
                "annotations": alert.get("annotations", {}),
            },
            "current_phase": "triage",
            "hypotheses": [],
            "proposed_actions": [],
            "executed_actions": [],
            "tokens_used": 0,
            "cost_usd": 0.0,
            "wall_clock_seconds": 0.0,
            "iteration_count": 0,
            "requires_human_approval": False,
            "approval_granted": None,
            "status": "running",
        }

        logger.info(
            "Starting incident %s for alert %s on %s/%s",
            incident_id,
            alert.get("alert_name"),
            alert.get("namespace"),
            alert.get("service"),
        )

        try:
            async for _ in self.graph.astream(initial_state, config, stream_mode="updates"):
                pass
            logger.info("Incident %s completed", incident_id)
        except Exception as exc:
            logger.error("Incident %s failed: %s", incident_id, exc, exc_info=True)
            raise

        return incident_id

    async def get_incident_state(self, incident_id: str) -> Any | None:
        """Get the current state of an incident."""
        config = self._build_config(incident_id)
        try:
            return await self.graph.aget_state(config)
        except Exception as exc:
            logger.warning("Failed to get state for %s: %s", incident_id, exc)
            return None

    async def list_incidents(self, limit: int = 100) -> list[tuple[str, Any]]:
        """List all incidents from the AsyncPostgresSaver checkpointer."""
        if self.checkpointer is None:
            logger.warning("No checkpointer configured — cannot list incidents")
            return []

        pool = getattr(self.checkpointer, "pool", None)
        if pool is None:
            pool = getattr(self.checkpointer, "conn", None)

        if pool is None:
            logger.warning("Checkpointer has no 'pool' or 'conn' attribute")
            return []

        results: list[tuple[str, Any]] = []

        try:
            async with pool.connection() as conn, conn.cursor() as cur:
                await cur.execute(
                    """
                        SELECT DISTINCT thread_id
                        FROM checkpoints
                        ORDER BY thread_id DESC
                        LIMIT %s
                        """,
                    (limit,),
                )
                rows = await cur.fetchall()

                for row in rows:
                    thread_id = str(row[0])
                    try:
                        state = await self.graph.aget_state(
                            {"configurable": {"thread_id": thread_id}}
                        )
                        if state is not None:
                            results.append((thread_id, state))
                    except Exception as exc:
                        logger.warning(
                            "Failed to load state for %s: %s",
                            thread_id,
                            exc,
                        )

            logger.info("Listed %d incidents", len(results))
            return results

        except Exception as exc:
            logger.error("Failed to list incidents: %s", exc, exc_info=True)
            return []

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "",
    ) -> bool:
        """Approve or reject a pending Tier-2+ action."""
        config = self._build_config(incident_id)

        try:
            state = await self.graph.aget_state(config)
            if state is None:
                logger.warning("Cannot approve: incident %s not found", incident_id)
                return False

            values = state.values
            if not values.get("requires_human_approval", False):
                logger.warning("Incident %s does not require approval", incident_id)
                return False

            if values.get("approval_granted") is not None:
                logger.warning("Incident %s already has approval decision", incident_id)
                return False

            await self.graph.aupdate_state(
                config,
                {"approval_granted": approved, "approval_comment": comment},
            )

            logger.info(
                "Incident %s %s (comment: %s)",
                incident_id,
                "approved" if approved else "rejected",
                comment,
            )
            return True

        except Exception as exc:
            logger.error(
                "Failed to approve incident %s: %s",
                incident_id,
                exc,
                exc_info=True,
            )
            return False
