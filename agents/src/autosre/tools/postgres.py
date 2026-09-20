"""PostgreSQL diagnostic and narrowly-scoped remediation tools."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field, field_validator

from autosre.core.state import SREContext
from autosre.tools.registry import Tool, ToolExecutionError, ToolInputModel, ToolRegistry


class GetActiveQueriesInput(ToolInputModel):
    min_duration_seconds: int = Field(
        default=0,
        ge=0,
        description=("Only return sessions whose active query age is at least this many seconds"),
    )
    limit: int = Field(
        default=25,
        ge=1,
        le=200,
    )
    exclude_idle: bool = Field(
        default=True,
        description=("Exclude idle, idle-in-transaction, and idle-in-transaction-aborted sessions"),
    )


class ActiveQuery(BaseModel):
    pid: int
    usename: str | None
    datname: str | None
    state: str
    wait_event_type: str | None
    wait_event: str | None
    query_duration_seconds: float
    query: str


class GetActiveQueriesOutput(BaseModel):
    queries: list[ActiveQuery]
    total_running: int


class GetLockWaitsInput(ToolInputModel):
    limit: int = Field(
        default=25,
        ge=1,
        le=200,
    )


class LockWait(BaseModel):
    blocked_pid: int
    blocking_pid: int
    blocked_query: str
    blocking_query: str
    wait_duration_seconds: float


class GetLockWaitsOutput(BaseModel):
    waits: list[LockWait]


class GetConnectionStatsInput(ToolInputModel):
    """No parameters."""


class ConnectionStats(BaseModel):
    total_connections: int
    active: int
    idle: int
    idle_in_transaction: int
    max_connections: int
    utilisation_pct: float


class GetConnectionStatsOutput(BaseModel):
    stats: ConnectionStats


class TerminateBackendInput(ToolInputModel):
    pid: int = Field(
        gt=0,
        description="PostgreSQL backend PID to terminate",
    )
    reason: str = Field(
        min_length=1,
        max_length=500,
    )

    @field_validator("reason")
    @classmethod
    def validate_reason(cls, value: str) -> str:
        value = value.strip()

        if not value:
            raise ValueError("reason must not be blank")

        return value


class TerminateBackendOutput(BaseModel):
    pid: int
    terminated: bool
    reason: str


def _connection(context: SREContext) -> Any:
    """Return the async psycopg pool context manager from ``SREContext``."""

    pool = getattr(
        context,
        "pg_pool",
        None,
    )

    if pool is None:
        raise ToolExecutionError(
            "postgres._connection",
            RuntimeError("SREContext.pg_pool is not initialised"),
        )

    connection = getattr(
        pool,
        "connection",
        None,
    )

    if not callable(connection):
        raise ToolExecutionError(
            "postgres._connection",
            TypeError("SREContext.pg_pool does not implement connection()"),
        )

    return connection()


async def _get_active_queries(
    args: GetActiveQueriesInput,
    context: SREContext,
) -> GetActiveQueriesOutput:
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
              AND (%s = FALSE OR state NOT IN (
                  'idle',
                  'idle in transaction',
                  'idle in transaction (aborted)'
              ))
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
        await cur.execute(
            query,
            (args.limit,),
        )

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
            utilisation_pct=round(
                utilisation,
                2,
            ),
        )
    )


async def _terminate_backend(
    args: TerminateBackendInput,
    context: SREContext,
) -> TerminateBackendOutput:
    async with _connection(context) as conn, conn.cursor() as cur:
        await cur.execute(
            """
                SELECT
                    activity.usename,
                    COALESCE(roles.rolsuper, TRUE) AS is_superuser,
                    activity.pid = pg_backend_pid() AS is_self
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
                reason="pid not found",
            )

        usename = row[0]
        is_superuser = bool(row[1])
        is_self = bool(row[2])

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

        await cur.execute(
            "SELECT pg_terminate_backend(%s, %s)",
            (
                args.pid,
                1000,
            ),
        )

        result_row = await cur.fetchone()

        terminated = bool(result_row[0]) if result_row else False

    return TerminateBackendOutput(
        pid=args.pid,
        terminated=terminated,
        reason=args.reason,
    )


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all Postgres tools."""

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
                "Return aggregate PostgreSQL connection counts and utilisation "
                "against max_connections."
            ),
            input_model=GetConnectionStatsInput,
            output_model=GetConnectionStatsOutput,
            handler=_get_connection_stats,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="terminate_backend",
            description=(
                "Terminate one PostgreSQL backend with pg_terminate_backend; "
                "refuses superuser, self, and background backends. Tier-1 action."
            ),
            input_model=TerminateBackendInput,
            output_model=TerminateBackendOutput,
            handler=_terminate_backend,
            risk_tier=1,
        )
    )
