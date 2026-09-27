"""LangGraph runner: incident lifecycle API on top of a compiled graph.

## Two execution modes

``run_incident`` (blocking)
    Runs the graph to completion and returns the incident_id. Used by the
    eval harness, which needs the incident to be terminal before it moves
    on. The HTTP layer must NOT use this method.

``schedule_incident`` (non-blocking)
    Generates the incident_id synchronously, starts the graph in a
    background task, and returns the incident_id immediately. Used by the
    webhook ingress so OpenObserve receives a 202 within milliseconds.

## Background task lifecycle

Background tasks are tracked in ``self._background_tasks``. A done-callback
discards the task and logs any exception. ``shutdown()`` drains them on
graceful shutdown; ``main.py`` must call it from the FastAPI lifespan.

## Persistence notes

LangGraph's ``AsyncPostgresSaver`` exposes a ``.conn`` attribute whose type
is a union of ``AsyncConnection`` and ``AsyncConnectionPool``, depending on
how the saver was constructed. Both shapes are handled by
``_read_connection()``.

The saver's underlying psycopg connection uses ``row_factory=dict_row``,
so query results arrive as mappings keyed by column name. All row access in
this module uses ``row.get("column_name")`` with a tuple-index fallback.

## Read-transaction hygiene

The checkpointer's connection is shared with LangGraph's checkpoint writes.
Leaving a read transaction open (idle-in-transaction) blocks those writes.
Every read path commits or rolls back on exit.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import uuid
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from typing import Any

from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from langgraph.types import Command
from psycopg import AsyncConnection
from psycopg_pool import AsyncConnectionPool

from autosre.core.router import LLMBudgetExhaustedError
from autosre.core.state import (
    AgentState,
    IncidentMetadata,
    RunMetrics,
    create_initial_state,
)

logger = logging.getLogger(__name__)

# Column name for the thread identifier in the checkpoints table.
_THREAD_ID_COLUMN = "thread_id"

# Safety margin subtracted from the configured wall-clock timeout before
# wrapping the graph stream. Leaves room for telemetry flush and shutdown.
_TIMEOUT_SAFETY_MARGIN_SECONDS = 5.0


class LangGraphRunner:
    """Incident lifecycle wrapper around a compiled LangGraph.

    Satisfies RunnerProtocol structurally. Provides both blocking
    (run_incident) and non-blocking (schedule_incident) entry points.
    """

    def __init__(
        self,
        graph: Any,
        checkpointer: AsyncPostgresSaver | None = None,
        sre_context: Any | None = None,
        graph_context: Any | None = None,
        *,
        max_wall_clock_seconds: int = 600,
    ) -> None:
        """Initialize the runner.

        Args:
            graph: Compiled LangGraph StateGraph.
            checkpointer: AsyncPostgresSaver for durable state.
            sre_context: Run-scoped dependencies (DB pools, K8s client).
            graph_context: Run-scoped graph dependencies (LLM router, tools).
            max_wall_clock_seconds: Hard upper bound on a single incident's
                wall-clock duration. Must be > 0.
        """
        if max_wall_clock_seconds <= 0:
            raise ValueError("max_wall_clock_seconds must be greater than zero")

        self.graph = graph
        self.checkpointer = checkpointer
        self.sre_context = sre_context
        self.graph_context = graph_context
        self.max_wall_clock_seconds = max_wall_clock_seconds

        # Background task tracking. Populated only by schedule_incident.
        self._background_tasks: set[asyncio.Task[None]] = set()
        self._background_lock = asyncio.Lock()

    # ------------------------------------------------------------------
    # Config construction
    # ------------------------------------------------------------------

    def _build_config(
        self,
        incident_id: str,
        run_metrics: RunMetrics | None = None,
    ) -> RunnableConfig:
        """Build a RunnableConfig with thread_id and injected contexts."""
        configurable: dict[str, Any] = {"thread_id": incident_id}

        if self.sre_context is not None:
            configurable["sre_context"] = self.sre_context

        if self.graph_context is not None:
            configurable["graph_context"] = self.graph_context

        if run_metrics is not None:
            configurable["run_metrics"] = run_metrics

        return {"configurable": configurable}

    # ------------------------------------------------------------------
    # Incident preparation (shared by both entry points)
    # ------------------------------------------------------------------

    def _prepare_incident(
        self,
        alert: dict[str, Any],
    ) -> tuple[str, AgentState, RunnableConfig, RunMetrics]:
        """Return everything needed to run one incident.

        Extracted so both run_incident and schedule_incident construct the
        incident identically. Pure: no I/O, no side effects beyond UUID
        generation and object construction.
        """
        incident_id = str(uuid.uuid4())
        run_metrics = RunMetrics()
        config = self._build_config(incident_id, run_metrics)

        metadata = IncidentMetadata(
            incident_id=incident_id,
            alert_name=alert.get("alert_name", ""),
            service=alert.get("service", ""),
            namespace=alert.get("namespace", ""),
            severity=alert.get("severity", ""),
            started_at=alert.get("started_at", ""),
            fingerprint=alert.get("fingerprint", ""),
            description=alert.get("description", ""),
            labels=alert.get("labels", {}),
            annotations=alert.get("annotations", {}),
        )

        initial_state = create_initial_state(metadata)

        return incident_id, initial_state, config, run_metrics

    # ------------------------------------------------------------------
    # Graph execution (shared by both entry points)
    # ------------------------------------------------------------------

    async def _execute_graph(
        self,
        incident_id: str,
        initial_state: AgentState,
        config: RunnableConfig,
        run_metrics: RunMetrics,
        alert: Mapping[str, Any],
    ) -> None:
        """Run the graph stream to completion with a wall-clock timeout.

        Cancellable. Records final metrics regardless of outcome.

        Raises:
            asyncio.TimeoutError: The wall-clock budget expired.
            LLMBudgetExhaustedError: The provider outage budget expired.
            Exception: Any unhandled graph exception.
        """
        timeout = max(
            1.0,
            float(self.max_wall_clock_seconds) - _TIMEOUT_SAFETY_MARGIN_SECONDS,
        )

        try:
            await asyncio.wait_for(
                self._stream_to_completion(initial_state, config),
                timeout=timeout,
            )

        except TimeoutError:
            logger.error(
                "Incident %s exceeded wall-clock budget (%ds). "
                "Graph cancelled; last checkpoint preserved.",
                incident_id,
                self.max_wall_clock_seconds,
            )
            raise

        except LLMBudgetExhaustedError:
            logger.error(
                "Incident %s aborted: LLM provider budget exhausted "
                "(llm_calls=%d consecutive_failures=%d)",
                incident_id,
                run_metrics.llm_call_count,
                run_metrics.llm_consecutive_failures,
            )
            raise

        except Exception as exc:
            logger.error("Incident %s failed: %s", incident_id, exc, exc_info=True)
            raise

        finally:
            logger.info(
                "Incident %s finished: llm_calls=%d retries=%d "
                "consecutive_failures=%d backoff=%.1fs",
                incident_id,
                run_metrics.llm_call_count,
                run_metrics.llm_retry_count,
                run_metrics.llm_consecutive_failures,
                run_metrics.backoff_seconds,
            )

    async def _stream_to_completion(
        self,
        initial_state: AgentState,
        config: RunnableConfig,
    ) -> None:
        """Drive the graph stream to completion. Cancellable."""
        async for _ in self.graph.astream(
            initial_state,
            config,
            stream_mode="updates",
        ):
            pass

    # ------------------------------------------------------------------
    # Public API — run (blocking)
    # ------------------------------------------------------------------

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Execute a new investigation to completion and return its ID.

        Blocking. The HTTP webhook handler must NOT use this method;
        it exists for the eval harness and CLI tooling where the caller
        genuinely needs the incident to be terminal before proceeding.

        Not idempotent: every call generates a fresh thread. Deduplicate
        upstream (fingerprint index in routes.py) if the caller may retry.
        """
        incident_id, initial_state, config, run_metrics = self._prepare_incident(alert)

        logger.info(
            "Starting incident %s (blocking): alert=%s namespace=%s service=%s budget_seconds=%d",
            incident_id,
            alert.get("alert_name"),
            alert.get("namespace"),
            alert.get("service"),
            self.max_wall_clock_seconds,
        )

        await self._execute_graph(
            incident_id,
            initial_state,
            config,
            run_metrics,
            alert,
        )

        return incident_id

    # ------------------------------------------------------------------
    # Public API — schedule (non-blocking)
    # ------------------------------------------------------------------

    async def schedule_incident(self, alert: dict[str, Any]) -> str:
        """Start an investigation in the background and return its ID.

        Returns within milliseconds. The graph runs in an asyncio task
        tracked by the runner; failures are logged via the done-callback.
        Deduplicate upstream (fingerprint index in routes.py) if the
        caller may retry.
        """
        incident_id, initial_state, config, run_metrics = self._prepare_incident(alert)

        logger.info(
            "Scheduling incident %s (background): alert=%s namespace=%s service=%s",
            incident_id,
            alert.get("alert_name"),
            alert.get("namespace"),
            alert.get("service"),
        )

        task = asyncio.create_task(
            self._execute_graph(
                incident_id,
                initial_state,
                config,
                run_metrics,
                alert,
            ),
            name=f"autosre-incident-{incident_id}",
        )

        async with self._background_lock:
            self._background_tasks.add(task)

        task.add_done_callback(self._on_background_task_done)

        return incident_id

    def _on_background_task_done(self, task: asyncio.Task[None]) -> None:
        """Discard the task and log any exception it raised.

        Called by asyncio on task completion. Never raises; a raise here
        would be swallowed by the event loop's default exception handler
        with less context than we have.
        """
        self._background_tasks.discard(task)

        if task.cancelled():
            return

        exc = task.exception()
        if exc is not None:
            logger.error(
                "Background incident task failed: %s",
                exc,
                exc_info=exc,
            )

    async def shutdown(self, timeout: float = 30.0) -> None:
        """Drain background tasks. Called from the FastAPI lifespan.

        Waits up to ``timeout`` seconds for in-flight incidents to
        finish; cancels the remainder. Safe to call when no tasks are
        pending.

        Args:
            timeout: Maximum seconds to wait before cancelling.
        """
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")

        async with self._background_lock:
            pending = list(self._background_tasks)

        if not pending:
            return

        logger.info(
            "Draining %d background incident task(s) (timeout=%.0fs)",
            len(pending),
            timeout,
        )

        done, still_pending = await asyncio.wait(pending, timeout=timeout)

        for task in still_pending:
            task.cancel()

        if still_pending:
            await asyncio.gather(*still_pending, return_exceptions=True)
            logger.warning(
                "Cancelled %d background task(s) after %.0fs timeout",
                len(still_pending),
                timeout,
            )

        if done:
            logger.info("Background tasks completed: %d", len(done))

    # ------------------------------------------------------------------
    # Public API — read
    # ------------------------------------------------------------------

    @asynccontextmanager
    async def _read_connection(
        self,
    ) -> AsyncIterator[AsyncConnection[Any]]:
        """Yield a live AsyncConnection for read-only queries.

        Handles both saver init modes. On exit, commits the read
        transaction if the connection is not in autocommit mode, so the
        shared connection is never left idle-in-transaction.
        """
        if self.checkpointer is None:
            raise RuntimeError("checkpointer is not configured")

        conn_or_pool = getattr(self.checkpointer, "conn", None)
        if conn_or_pool is None:
            raise RuntimeError("checkpointer has no 'conn' attribute")

        if isinstance(conn_or_pool, AsyncConnectionPool):
            async with conn_or_pool.connection() as conn:
                try:
                    yield conn
                finally:
                    if not conn.autocommit:
                        with contextlib.suppress(Exception):
                            await conn.commit()
            return

        if isinstance(conn_or_pool, AsyncConnection):
            try:
                yield conn_or_pool
            finally:
                if not conn_or_pool.autocommit:
                    with contextlib.suppress(Exception):
                        await conn_or_pool.commit()
            return

        raise RuntimeError(f"checkpointer.conn has unsupported type: {type(conn_or_pool).__name__}")

    @staticmethod
    def _extract_thread_id(row: Any) -> str | None:
        """Return the thread_id from a query row, or None."""
        if row is None:
            return None

        if isinstance(row, Mapping):
            value = row.get(_THREAD_ID_COLUMN)
        else:
            try:
                value = row[0]
            except IndexError, KeyError, TypeError:
                return None

        if value is None:
            return None

        text = str(value).strip()
        return text or None

    async def get_incident_state(self, incident_id: str) -> Any | None:
        """Return the latest checkpointed state for an incident, or None."""
        if not incident_id:
            return None

        config = self._build_config(incident_id)

        try:
            return await self.graph.aget_state(config)
        except Exception as exc:
            logger.warning("Failed to read state for %s: %s", incident_id, exc)
            return None

    async def list_incidents(self, limit: int = 100) -> list[tuple[str, Any]]:
        """Return recent incidents ordered by last checkpoint recency."""
        if limit <= 0:
            raise ValueError("limit must be greater than zero")

        if self.checkpointer is None:
            logger.warning("No checkpointer configured — cannot list incidents")
            return []

        thread_ids: list[str] = []

        try:
            async with self._read_connection() as conn, conn.cursor() as cur:
                await cur.execute(
                    """
                        SELECT thread_id
                        FROM (
                            SELECT thread_id,
                                   MAX(checkpoint_id) AS last_checkpoint
                            FROM checkpoints
                            GROUP BY thread_id
                        ) AS recent
                        ORDER BY last_checkpoint DESC
                        LIMIT %s
                        """,
                    (limit,),
                )
                rows = await cur.fetchall()

            for row in rows:
                thread_id = self._extract_thread_id(row)
                if thread_id:
                    thread_ids.append(thread_id)

        except RuntimeError as exc:
            logger.warning("Cannot list incidents: %s", exc)
            return []

        except Exception as exc:
            logger.error(
                "Failed to query checkpoint thread IDs: %s",
                exc,
                exc_info=True,
            )
            return []

        results: list[tuple[str, Any]] = []

        for thread_id in thread_ids:
            try:
                state = await self.graph.aget_state({"configurable": {"thread_id": thread_id}})
                if state is not None:
                    results.append((thread_id, state))
            except Exception as exc:
                logger.warning("Failed to load state for %s: %s", thread_id, exc)

        logger.info("Listed %d incidents from checkpointer", len(results))
        return results

    # ------------------------------------------------------------------
    # Public API — HITL
    # ------------------------------------------------------------------

    async def approve_incident(
        self,
        incident_id: str,
        approved: bool,
        comment: str = "",
    ) -> bool:
        """Resume a paused graph with the operator's approval decision.

        Idempotent: an incident that already has an ``approval_granted``
        value returns False without resuming.
        """
        if not incident_id:
            logger.warning("approve_incident called with empty incident_id")
            return False

        config = self._build_config(incident_id)

        try:
            state_snapshot = await self.graph.aget_state(config)

            if state_snapshot is None:
                logger.warning("Cannot approve: incident %s not found", incident_id)
                return False

            values = state_snapshot.values

            if not isinstance(values, Mapping):
                logger.warning(
                    "Incident %s has malformed state values (%s)",
                    incident_id,
                    type(values).__name__,
                )
                return False

            if not values.get("requires_human_approval", False):
                logger.warning("Incident %s does not require approval", incident_id)
                return False

            if values.get("approval_granted") is not None:
                logger.warning(
                    "Incident %s already has approval decision=%s",
                    incident_id,
                    values.get("approval_granted"),
                )
                return False

            await self.graph.ainvoke(
                Command(
                    resume={
                        "approved": bool(approved),
                        "comment": str(comment),
                    }
                ),
                config=config,
            )

            logger.info(
                "Incident %s %s (comment=%r)",
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


__all__ = ["LangGraphRunner"]
