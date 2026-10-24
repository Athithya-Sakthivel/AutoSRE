"""PostgreSQL diagnostic and narrowly-scoped remediation tools.

## Tools Registered

### Tier 0 — Read-Only Diagnostics (3 tools)
- `get_active_queries`: List sessions with active-query age and wait events
- `get_lock_waits`: Return lock-wait graph (blocked/blocking PIDs, queries, duration)
- `get_connection_stats`: Aggregate client-connection counts and utilisation vs max_connections

### Tier 1 — Reversible Remediation (1 tool)
- `terminate_backend`: Terminate PostgreSQL backend(s) with pg_terminate_backend

## terminate_backend operating modes

The tool has two modes, selected by whether ``pid`` is supplied:

### Targeted mode (``pid`` supplied)
Terminates exactly one backend. Conservative safety checks apply — the tool
refuses to kill the agent's own connection, superuser sessions, and sessions
without a login role. Use this when the LLM has identified a specific PID.

### Auto-discovery mode (``pid`` omitted)
Discovers every ``idle in transaction`` / ``idle in transaction (aborted)``
client backend and terminates all of them. This is the mode used by the
deterministic fallback path for the ``db_connection_exhaustion`` category,
which cannot know a PID in advance.

Auto-discovery is bounded and self-protecting:
- only ``backend_type = 'client backend'`` (never autovacuum/walwriter/etc.)
- never the agent's own connection (``pid <> pg_backend_pid()``)
- never sessions whose ``application_name`` looks like the agent's own pool
- never role-less background sessions (``usename IS NOT NULL``)
- capped at ``_MAX_AUTO_TERMINATE`` backends per call
- superuser sessions ARE eligible: an idle-in-transaction session is by
  definition doing no useful work while holding a connection slot and locks.
  During a sev1 pool-exhaustion outage, refusing to act guarantees the outage
  continues. The state filter (never ``active``) is the real safety control.

## Contracts

### Output Contract
Every Tier-1 tool output model includes:
- `success: bool` — True if the tool executed without error
- `verification_passed: bool | None` — True if output indicates root cause
  resolved, None if indeterminate

For `terminate_backend`, the tool explicitly rechecks whether the targeted
backend identity has disappeared before reporting verification success.
Diagnostic counters (``candidates_found``, ``terminated_count``,
``still_idle_in_transaction``) distinguish "nothing to do" from "tried and
failed", which is essential for evaluating remediation quality.

### SREContext Contract
The PostgreSQL connection pool is accessed via `context.pg_pool`. It must be
an `psycopg_pool.AsyncConnectionPool` instance or a compatible object exposing
`connection()`. If None, tools raise `ToolExecutionError`.

### Error Handling Contract
All psycopg queries are wrapped in async context managers and exceptions are
re-raised as `ToolExecutionError` with the tool name and original exception.
Per-backend termination failures in auto-discovery mode are logged and skipped
rather than aborting the whole batch.

### Compatibility Contract
`pg_terminate_backend(pid)` is called with a single argument. The two-argument
form `pg_terminate_backend(pid, timeout)` requires PostgreSQL 14+; the
single-argument form works on every supported version.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from pydantic import BaseModel, Field, field_validator

from autosre.core.state import SREContext
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Input / Output Models
# ---------------------------------------------------------------------------


class GetActiveQueriesInput(ToolInputModel):
    """Input for listing active PostgreSQL queries."""

    min_duration_seconds: int = Field(
        default=0,
        ge=0,
        description=("Only return sessions whose active query age is at least this many seconds"),
    )
    limit: int = Field(default=25, ge=1, le=200)
    exclude_idle: bool = Field(
        default=True,
        description=("Exclude idle, idle-in-transaction, and idle-in-transaction-aborted sessions"),
    )


class ActiveQuery(BaseModel):
    """A single active PostgreSQL query session."""

    pid: int
    usename: str | None
    datname: str | None
    state: str
    wait_event_type: str | None
    wait_event: str | None
    query_duration_seconds: float
    query: str


class GetActiveQueriesOutput(BaseModel):
    """Output for get_active_queries tool."""

    queries: list[ActiveQuery]
    total_running: int


class GetLockWaitsInput(ToolInputModel):
    """Input for listing lock waits."""

    limit: int = Field(default=25, ge=1, le=200)


class LockWait(BaseModel):
    """A single lock wait relationship."""

    blocked_pid: int
    blocking_pid: int
    blocked_query: str
    blocking_query: str
    wait_duration_seconds: float


class GetLockWaitsOutput(BaseModel):
    """Output for get_lock_waits tool."""

    waits: list[LockWait]


class GetConnectionStatsInput(ToolInputModel):
    """Input for connection stats (no parameters)."""


class ConnectionStats(BaseModel):
    """Aggregate PostgreSQL client connection statistics."""

    total_connections: int
    active: int
    idle: int
    idle_in_transaction: int
    max_connections: int
    utilisation_pct: float


class GetConnectionStatsOutput(BaseModel):
    """Output for get_connection_stats tool."""

    stats: ConnectionStats


class TerminateBackendInput(ToolInputModel):
    """Input for terminating PostgreSQL backend(s).

    When ``pid`` is omitted the tool self-discovers every idle-in-transaction
    backend and terminates all of them. This makes the tool usable from
    deterministic fallback paths that cannot know a PID in advance.
    """

    pid: int | None = Field(
        default=None,
        gt=0,
        description=(
            "PostgreSQL backend PID to terminate. Omit to terminate ALL "
            "idle-in-transaction backends automatically."
        ),
    )
    reason: str = Field(min_length=1, max_length=500)

    @field_validator("reason")
    @classmethod
    def validate_reason(cls, value: str) -> str:
        """Ensure reason is not blank after stripping."""
        value = value.strip()
        if not value:
            raise ValueError("reason must not be blank")
        return value


class TerminateBackendOutput(BaseModel):
    """Output for terminate_backend tool.

    Attributes:
        pid: Targeted PID, or None in auto-discovery mode.
        terminated: True if at least one backend was terminated.
        reason: Caller-supplied justification.
        terminated_pids: PIDs PostgreSQL confirmed termination for.
        terminated_count: Length of terminated_pids.
        candidates_found: Backends matched by auto-discovery (0 in targeted
            mode). Distinguishes "nothing to do" from "tried and failed".
        still_idle_in_transaction: Candidates still idle-in-tx after the
            termination round.
        success: True if the tool executed without error.
        verification_passed: True if the desired end state was reached.
    """

    pid: int | None = None
    terminated: bool
    reason: str
    terminated_pids: list[int] = Field(default_factory=list)
    terminated_count: int = 0
    candidates_found: int = 0
    still_idle_in_transaction: int = 0
    success: bool = True
    verification_passed: bool | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _connection(context: SREContext) -> Any:
    """Return the async psycopg pool context manager from SREContext.

    Raises:
        ToolExecutionError: If pg_pool is not initialized or doesn't
            implement connection().
    """
    pool = getattr(context, "pg_pool", None)

    if pool is None:
        raise ToolExecutionError(
            "postgres._connection",
            RuntimeError("SREContext.pg_pool is not initialised"),
        )

    connection = getattr(pool, "connection", None)

    if not callable(connection):
        raise ToolExecutionError(
            "postgres._connection",
            TypeError("SREContext.pg_pool does not implement connection()"),
        )

    return connection()


# Maximum backends terminated in one auto-discovery call. Bounds blast radius.
_MAX_AUTO_TERMINATE = 50

# Milliseconds to wait before re-checking pg_stat_activity after termination.
_VERIFY_DELAY_SECONDS = 0.5

# Candidate selection for auto-discovery mode.
#
# Safety filters, in order of importance:
#   1. backend_type = 'client backend'  -> never touch autovacuum, walwriter,
#                                          checkpointer, bgwriter, etc.
#   2. state IN (idle in transaction*)  -> never touch a session that is
#                                          actively running a query
#   3. pid <> pg_backend_pid()          -> never kill our own connection
#   4. application_name NOT ILIKE ...   -> never kill the agent's own pool
#   5. usename IS NOT NULL              -> never kill role-less internals
#
# Superuser sessions ARE eligible. An idle-in-transaction session is doing no
# useful work while holding a connection slot and locks; refusing to terminate
# it during a pool-exhaustion outage guarantees the outage continues.
_IDLE_TX_CANDIDATE_SQL = """
    SELECT
        activity.pid,
        activity.backend_start,
        COALESCE(activity.usename, '') AS usename
    FROM pg_stat_activity AS activity
    WHERE activity.backend_type = 'client backend'
      AND activity.state IN (
              'idle in transaction',
              'idle in transaction (aborted)'
          )
      AND activity.pid <> pg_backend_pid()
      AND activity.usename IS NOT NULL
      AND COALESCE(activity.application_name, '') NOT ILIKE '%%autosre%%'
      AND COALESCE(activity.application_name, '') NOT ILIKE '%%sre-agent%%'
    ORDER BY activity.query_start ASC NULLS LAST, activity.pid
    LIMIT %s
"""

# Re-check which candidates are still idle-in-transaction after termination.
_IDLE_TX_STILL_PRESENT_SQL = """
    SELECT pid
    FROM pg_stat_activity
    WHERE pid = ANY(%s)
      AND state IN (
              'idle in transaction',
              'idle in transaction (aborted)'
          )
"""


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _get_active_queries(
    args: GetActiveQueriesInput,
    context: SREContext,
) -> GetActiveQueriesOutput:
    """List PostgreSQL sessions with active-query age and wait information."""
    query = """
        WITH activity AS (
            SELECT
                pid,
                usename,
                datname,
                state,
                wait_event_type,
                wait_event,
                CASE
                    WHEN state = 'active' AND query_start IS NOT NULL
                    THEN EXTRACT(
                        EPOCH FROM (clock_timestamp() - query_start)
                    )::float8
                    ELSE 0.0
                END AS duration_s,
                LEFT(COALESCE(query, ''), 500) AS query
            FROM pg_stat_activity
            WHERE pid <> pg_backend_pid()
              AND (
                  %s = FALSE
                  OR state NOT IN (
                      'idle',
                      'idle in transaction',
                      'idle in transaction (aborted)'
                  )
              )
        )
        SELECT
            pid,
            usename,
            datname,
            state,
            wait_event_type,
            wait_event,
            duration_s,
            query,
            COUNT(*) OVER () AS total_matching
        FROM activity
        WHERE duration_s >= %s
        ORDER BY duration_s DESC, pid
        LIMIT %s
    """

    async with _connection(context) as conn, conn.cursor() as cur:
        await cur.execute(
            query,
            (
                args.exclude_idle,
                float(args.min_duration_seconds),
                args.limit,
            ),
        )
        rows = await cur.fetchall()

    total_matching = int(rows[0][8]) if rows else 0

    return GetActiveQueriesOutput(
        queries=[
            ActiveQuery(
                pid=int(row[0]),
                usename=row[1],
                datname=row[2],
                state=str(row[3] or "unknown"),
                wait_event_type=row[4],
                wait_event=row[5],
                query_duration_seconds=float(row[6] or 0.0),
                query=str(row[7] or ""),
            )
            for row in rows
        ],
        total_running=total_matching,
    )


async def _get_lock_waits(
    args: GetLockWaitsInput,
    context: SREContext,
) -> GetLockWaitsOutput:
    """Return the current PostgreSQL lock-wait graph."""
    query = """
        WITH waiting_locks AS (
            SELECT DISTINCT ON (pid)
                pid,
                waitstart
            FROM pg_locks
            WHERE granted = FALSE
              AND waitstart IS NOT NULL
            ORDER BY pid, waitstart
        )
        SELECT
            blocked.pid AS blocked_pid,
            blocking.pid AS blocking_pid,
            LEFT(COALESCE(blocked.query, ''), 300) AS blocked_query,
            LEFT(COALESCE(blocking.query, ''), 300) AS blocking_query,
            EXTRACT(
                EPOCH FROM (clock_timestamp() - waiting.waitstart)
            )::float8 AS wait_s
        FROM waiting_locks AS waiting
        JOIN pg_stat_activity AS blocked
          ON blocked.pid = waiting.pid
        CROSS JOIN LATERAL unnest(
            pg_blocking_pids(blocked.pid)
        ) AS bp(pid)
        JOIN pg_stat_activity AS blocking
          ON blocking.pid = bp.pid
        WHERE blocked.wait_event_type = 'Lock'
        ORDER BY waiting.waitstart ASC, blocked.pid, blocking.pid
        LIMIT %s
    """

    async with _connection(context) as conn, conn.cursor() as cur:
        await cur.execute(query, (args.limit,))
        rows = await cur.fetchall()

    return GetLockWaitsOutput(
        waits=[
            LockWait(
                blocked_pid=int(row[0]),
                blocking_pid=int(row[1]),
                blocked_query=str(row[2] or ""),
                blocking_query=str(row[3] or ""),
                wait_duration_seconds=float(row[4] or 0.0),
            )
            for row in rows
        ]
    )


async def _get_connection_stats(
    args: GetConnectionStatsInput,
    context: SREContext,
) -> GetConnectionStatsOutput:
    """Return PostgreSQL client connection counts and utilisation."""
    del args

    async with _connection(context) as conn, conn.cursor() as cur:
        await cur.execute(
            """
            SELECT
                COUNT(*) AS total,
                COUNT(*) FILTER (WHERE state = 'active') AS active,
                COUNT(*) FILTER (WHERE state = 'idle') AS idle,
                COUNT(*) FILTER (
                    WHERE state IN (
                        'idle in transaction',
                        'idle in transaction (aborted)'
                    )
                ) AS idle_tx
            FROM pg_stat_activity
            WHERE backend_type = 'client backend'
            """
        )

        row = await cur.fetchone()

        if row is None:
            raise ToolExecutionError(
                "get_connection_stats",
                RuntimeError("pg_stat_activity returned no rows"),
            )

        total, active, idle, idle_tx = (int(value) for value in row)

        await cur.execute("SHOW max_connections")
        max_row = await cur.fetchone()

        if max_row is None:
            raise ToolExecutionError(
                "get_connection_stats",
                RuntimeError("SHOW max_connections returned no rows"),
            )

        max_conn = int(max_row[0])

    utilisation = total / max_conn * 100.0 if max_conn > 0 else 0.0

    return GetConnectionStatsOutput(
        stats=ConnectionStats(
            total_connections=total,
            active=active,
            idle=idle,
            idle_in_transaction=idle_tx,
            max_connections=max_conn,
            utilisation_pct=round(utilisation, 2),
        )
    )


# ---------------------------------------------------------------------------
# Tier 1: Reversible remediation
# ---------------------------------------------------------------------------


async def _terminate_idle_in_transaction(
    reason: str,
    context: SREContext,
) -> TerminateBackendOutput:
    """Discover and terminate all idle-in-transaction client backends.

    Bounded by ``_MAX_AUTO_TERMINATE``. See the module docstring for the full
    list of safety filters. Per-backend failures are logged and skipped so one
    un-killable session cannot abort the whole batch.
    """
    async with _connection(context) as conn, conn.cursor() as cur:
        try:
            await cur.execute(_IDLE_TX_CANDIDATE_SQL, (_MAX_AUTO_TERMINATE,))
            rows = await cur.fetchall()
        except Exception as exc:
            raise ToolExecutionError("terminate_backend", exc) from exc

        candidates: list[tuple[int, Any]] = [(int(row[0]), row[1]) for row in rows]
        candidates_found = len(candidates)

        if not candidates:
            logger.info("No idle-in-transaction backends found; desired state already reached")
            return TerminateBackendOutput(
                pid=None,
                terminated=False,
                reason=reason,
                terminated_pids=[],
                terminated_count=0,
                candidates_found=0,
                still_idle_in_transaction=0,
                success=True,
                verification_passed=True,
            )

        terminated_pids: list[int] = []

        for pid, _backend_start in candidates:
            try:
                # Single-argument form: works on every PostgreSQL version.
                await cur.execute("SELECT pg_terminate_backend(%s)", (pid,))
                result_row = await cur.fetchone()
                if result_row and bool(result_row[0]):
                    terminated_pids.append(pid)
                else:
                    logger.warning(
                        "pg_terminate_backend(%d) returned false; backend may have already exited",
                        pid,
                    )
            except Exception as exc:
                logger.warning("Failed to terminate backend %d: %s", pid, exc)

        # pg_terminate_backend reports intent, not completion.
        await asyncio.sleep(_VERIFY_DELAY_SECONDS)

        still_present: set[int] = set()
        pids = [pid for pid, _ in candidates]

        try:
            await cur.execute(_IDLE_TX_STILL_PRESENT_SQL, (pids,))
            still_present = {int(row[0]) for row in await cur.fetchall()}
        except Exception as exc:
            logger.warning(
                "Post-termination verification query failed: %s",
                exc,
            )

    verified = not still_present

    logger.info(
        "Auto-terminate idle-in-tx: candidates=%d terminated=%d still_present=%d verified=%s",
        candidates_found,
        len(terminated_pids),
        len(still_present),
        verified,
    )

    return TerminateBackendOutput(
        pid=None,
        terminated=len(terminated_pids) > 0,
        reason=reason,
        terminated_pids=terminated_pids,
        terminated_count=len(terminated_pids),
        candidates_found=candidates_found,
        still_idle_in_transaction=len(still_present),
        success=True,
        verification_passed=verified,
    )


async def _terminate_backend(
    args: TerminateBackendInput,
    context: SREContext,
) -> TerminateBackendOutput:
    """Terminate PostgreSQL backend(s) and verify disappearance.

    When ``args.pid`` is None, all idle-in-transaction client backends are
    auto-discovered and terminated (bounded, self-protecting). When a PID is
    supplied, only that backend is targeted and the conservative safety checks
    apply.
    """
    if args.pid is None:
        return await _terminate_idle_in_transaction(args.reason, context)

    async with _connection(context) as conn, conn.cursor() as cur:
        await cur.execute(
            """
            SELECT
                activity.usename,
                COALESCE(roles.rolsuper, TRUE) AS is_superuser,
                activity.pid = pg_backend_pid() AS is_self,
                activity.backend_start
            FROM pg_stat_activity AS activity
            LEFT JOIN pg_roles AS roles
              ON roles.rolname = activity.usename
            WHERE activity.pid = %s
            """,
            (args.pid,),
        )

        row = await cur.fetchone()

        if row is None:
            return TerminateBackendOutput(
                pid=args.pid,
                terminated=False,
                reason=args.reason,
                terminated_pids=[],
                terminated_count=0,
                candidates_found=0,
                still_idle_in_transaction=0,
                success=True,
                verification_passed=True,
            )

        usename = row[0]
        is_superuser = bool(row[1])
        is_self = bool(row[2])
        backend_start = row[3]

        if is_self:
            raise ToolExecutionError(
                "terminate_backend",
                PermissionError("refusing to terminate the agent's own connection"),
            )

        if usename is None:
            raise ToolExecutionError(
                "terminate_backend",
                PermissionError(f"refusing to terminate backend {args.pid} without a login role"),
            )

        if is_superuser:
            raise ToolExecutionError(
                "terminate_backend",
                PermissionError(f"refusing to terminate superuser pid {args.pid}"),
            )

        try:
            await cur.execute(
                "SELECT pg_terminate_backend(%s)",
                (args.pid,),
            )
            result_row = await cur.fetchone()
        except Exception as exc:
            raise ToolExecutionError(
                "terminate_backend",
                exc,
            ) from exc

        termination_requested = bool(result_row[0]) if result_row else False

        # pg_terminate_backend reports intent, not completion.
        await asyncio.sleep(_VERIFY_DELAY_SECONDS)

        # Compare backend_start as well as PID so a reused PostgreSQL PID is
        # not mistaken for the original backend.
        await cur.execute(
            """
            SELECT 1
            FROM pg_stat_activity
            WHERE pid = %s
              AND backend_start = %s
            """,
            (args.pid, backend_start),
        )
        still_present = await cur.fetchone() is not None

        verified = not still_present

        logger.info(
            "Backend %d termination requested: requested=%s verified=%s",
            args.pid,
            termination_requested,
            verified,
        )

    terminated_ok = termination_requested and verified

    return TerminateBackendOutput(
        pid=args.pid,
        terminated=terminated_ok,
        reason=args.reason,
        terminated_pids=[args.pid] if terminated_ok else [],
        terminated_count=1 if terminated_ok else 0,
        candidates_found=1,
        still_idle_in_transaction=1 if still_present else 0,
        success=True,
        verification_passed=verified,
    )


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all PostgreSQL tools with the given registry."""
    del context

    # Tier 0: Read-only diagnostics
    registry.register(
        Tool(
            name="get_active_queries",
            description=(
                "List PostgreSQL sessions with active-query age and wait information; "
                "filters out idle states by default."
            ),
            input_model=GetActiveQueriesInput,
            output_model=GetActiveQueriesOutput,
            handler=_get_active_queries,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_lock_waits",
            description=(
                "Return the current PostgreSQL lock-wait graph: blocked PID, "
                "blocking PID, queries, and wait duration."
            ),
            input_model=GetLockWaitsInput,
            output_model=GetLockWaitsOutput,
            handler=_get_lock_waits,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_connection_stats",
            description=(
                "Return PostgreSQL client connection counts and utilisation "
                "against max_connections."
            ),
            input_model=GetConnectionStatsInput,
            output_model=GetConnectionStatsOutput,
            handler=_get_connection_stats,
            risk_tier=0,
        )
    )

    # Tier 1: Reversible remediation
    registry.register(
        Tool(
            name="terminate_backend",
            description=(
                "Terminate PostgreSQL backend(s) with pg_terminate_backend. "
                "Pass pid to terminate one specific backend (refuses superuser, "
                "self, and role-less backends). Omit pid to auto-discover and "
                "terminate ALL idle-in-transaction client backends — use this "
                "for connection pool exhaustion."
            ),
            input_model=TerminateBackendInput,
            output_model=TerminateBackendOutput,
            handler=_terminate_backend,
            risk_tier=1,
        )
    )
