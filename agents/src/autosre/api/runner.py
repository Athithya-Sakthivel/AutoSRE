"""LangGraph runner: incident lifecycle API on top of a compiled graph.

## Responsibilities

    run_incident(alert)              Create incident_id, execute graph with
                                     a per-incident RunMetrics, enforce a
                                     wall-clock timeout, log metrics.
    get_incident_state(id)           Read one checkpointed state.
    list_incidents(limit)            List recent incidents, ordered by
                                     recency of last checkpoint.
    approve_incident(id, ...)        Resume a paused HITL interrupt with
                                     the operator's decision.

## Persistence notes

LangGraph's ``AsyncPostgresSaver`` exposes a ``.conn`` attribute whose type
is a union:

    AsyncConnection       — from AsyncPostgresSaver.from_conn_string()
    AsyncConnectionPool   — from an externally managed pool

Both shapes are handled by ``_read_connection()``, a context manager that
yields an ``AsyncConnection`` and returns it (or commits the read
transaction) on exit, whichever the mode requires.

The saver's underlying psycopg connection is configured with
``row_factory=dict_row``, so query results arrive as ``dict`` rows keyed
by column name. All row access in this module uses
``row.get("column_name")`` with a tuple-index fallback for defensive
compatibility with older saver versions.

## Read-transaction hygiene

The checkpointer's connection is shared with LangGraph's own checkpoint
writes. Leaving a read transaction open (idle-in-transaction) blocks
those writes. Every read path in this module commits or rolls back on
exit. If the connection is in autocommit mode, commit is skipped.

## Idempotency

    list_incidents       Pure read; identical inputs yield identical outputs.
    get_incident_state   Pure read.
    approve_incident     Idempotent: an incident that already has an
                         approval decision returns False without resuming.
                         LangGraph's interrupt/resume is single-shot.
    run_incident         NOT idempotent. Every call creates a new
                         incident_id and a new thread. Callers that need
                         deduplication must do it upstream (webhook
                         fingerprint, idempotency key, etc.).
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

# Column name for the thread identifier in the checkpoints table. Kept as
# a constant because it appears in both SQL and result parsing.
_THREAD_ID_COLUMN = "thread_id"

# Safety margin subtracted from the configured wall-clock timeout before
# wrapping the graph stream. Leaves room for telemetry flush and shutdown.
_TIMEOUT_SAFETY_MARGIN_SECONDS = 5.0


class LangGraphRunner:
    """Incident lifecycle wrapper around a compiled LangGraph.

    Satisfies RunnerProtocol structurally.

    ``sre_context`` and ``graph_context`` are stored on the instance and
    injected into every RunnableConfig so graph nodes can reach them via
    ``config['configurable']['sre_context']`` and ``['graph_context']``.
    ``run_metrics`` is created per incident so that no state leaks between
    investigations.
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
            checkpointer: AsyncPostgresSaver used for durable state. When
                None, ``list_incidents`` returns an empty list and
                ``get_incident_state`` returns None. ``run_incident`` will
                still execute but without checkpoint persistence.
            sre_context: Run-scoped dependencies (DB pools, K8s client).
            graph_context: Run-scoped graph dependencies (LLM router,
                tool registry, executor, policy engine, eviction).
            max_wall_clock_seconds: Hard upper bound on a single incident's
                wall-clock duration. Enforced via asyncio.wait_for around
                the graph stream. Must be > 0.
        """
        if max_wall_clock_seconds <= 0:
            raise ValueError("max_wall_clock_seconds must be greater than zero")

        self.graph = graph
        self.checkpointer = checkpointer
        self.sre_context = sre_context
        self.graph_context = graph_context
        self.max_wall_clock_seconds = max_wall_clock_seconds

    # ------------------------------------------------------------------
    # Config construction
    # ------------------------------------------------------------------

    def _build_config(
        self,
        incident_id: str,
        run_metrics: RunMetrics | None = None,
    ) -> RunnableConfig:
        """Build a RunnableConfig with thread_id and injected contexts.

        Only non-None values are inserted. This keeps the config dict
        minimal in tests that construct it via other means.
        """
        configurable: dict[str, Any] = {"thread_id": incident_id}

        if self.sre_context is not None:
            configurable["sre_context"] = self.sre_context

        if self.graph_context is not None:
            configurable["graph_context"] = self.graph_context

        if run_metrics is not None:
            configurable["run_metrics"] = run_metrics

        return {"configurable": configurable}

    # ------------------------------------------------------------------
    # Connection resolution
    # ------------------------------------------------------------------

    @asynccontextmanager
    async def _read_connection(
        self,
    ) -> AsyncIterator[AsyncConnection[Any]]:
        """Yield a live AsyncConnection for read-only queries.

        Handles both saver init modes. On exit, commits the read
        transaction if the connection is not in autocommit mode, so the
        shared connection is never left idle-in-transaction (which blocks
        LangGraph's checkpoint writes).

        Raises:
            RuntimeError: when no checkpointer is configured or the saver
                does not expose a usable ``conn``.
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
        """Return the thread_id from a query row, or None.

        The saver's connection uses ``row_factory=dict_row``, so rows are
        mappings keyed by column name. Older or externally pooled savers
        may return tuples; the tuple path is preserved as a fallback.
        """
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

    # ------------------------------------------------------------------
    # Public API — run
    # ------------------------------------------------------------------

    async def run_incident(self, alert: dict[str, Any]) -> str:
        """Execute a new investigation and return its incident_id.

        Not idempotent: every call generates a fresh thread. Deduplicate
        upstream if the caller may retry.

        The stream is bounded by ``max_wall_clock_seconds``. On timeout,
        the graph is cancelled and the incident is left in its last
        checkpointed state; the caller receives an error.

        Raises:
            asyncio.TimeoutError: The wall-clock budget expired.
            LLMBudgetExhaustedError: The provider outage budget expired.
            Exception: Any unhandled graph exception.
        """
        incident_id = str(uuid.uuid4())
        run_metrics = RunMetrics()
        config = self._build_config(incident_id, run_metrics)

        metadata: IncidentMetadata = IncidentMetadata(
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

        initial_state: AgentState = create_initial_state(metadata)

        logger.info(
            "Starting incident %s: alert=%s namespace=%s service=%s budget_seconds=%d",
            incident_id,
            alert.get("alert_name"),
            alert.get("namespace"),
            alert.get("service"),
            self.max_wall_clock_seconds,
        )

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

        return incident_id

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
    # Public API — read
    # ------------------------------------------------------------------

    async def get_incident_state(self, incident_id: str) -> Any | None:
        """Return the latest checkpointed state for an incident, or None.

        Returns None for a missing incident rather than raising, because
        the API layer translates "not found" into a 404 and this method is
        used in polling loops.
        """
        if not incident_id:
            return None

        config = self._build_config(incident_id)

        try:
            return await self.graph.aget_state(config)
        except Exception as exc:
            logger.warning("Failed to read state for %s: %s", incident_id, exc)
            return None

    async def list_incidents(self, limit: int = 100) -> list[tuple[str, Any]]:
        """Return recent incidents ordered by last checkpoint recency.

        Ordering uses ``MAX(checkpoint_id)`` per thread. thread_id is a
        random UUID and its lexicographic order carries no signal.

        Args:
            limit: Upper bound on returned incidents. Must be > 0.

        Returns:
            List of (incident_id, state_snapshot) tuples. Empty when no
            checkpointer is configured or the query fails.
        """
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
        value returns False without resuming. A second Slack or UI click
        therefore cannot double-resume the graph.

        Uses ``Command(resume={"approved": ..., "comment": ...})`` which
        is the LangGraph 1.x contract. Do not substitute
        ``aupdate_state()`` — it modifies channels without resuming.

        Returns:
            True if the graph was resumed.
            False if the incident is missing, does not require approval,
            already has a decision, or the resume raised.
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
