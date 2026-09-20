"""Integration tests for Postgres tools against a real Postgres container.

Bootstrap strategy:
    PostgresContainer is started with the default ``postgres`` superuser.
    After the container is ready, we connect as that bootstrap superuser
    to create a *non-superuser* test role (``autosre_test``) and grant it
    the minimal privileges the agent needs (pg_monitor, pg_signal_backend).
    All tool execution goes through the non-superuser pool.

    This avoids the PostgreSQL constraint that the bootstrap superuser
    cannot have its SUPERUSER attribute removed by itself.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from typing import Any

import psycopg
import pytest
import pytest_asyncio
from psycopg_pool import AsyncConnectionPool
from testcontainers.community.postgres import PostgresContainer

from autosre.core.state import SREContext
from autosre.tools import postgres as pg_tools
from autosre.tools.registry import ToolExecutionError, ToolRegistry

# Non-superuser role used by the tool pool. The bootstrap superuser
# creates it in the session-scoped fixture.
_TEST_ROLE = "autosre_test"
_TEST_ROLE_PASSWORD = "autosre_test"
_TEST_DB = "autosre_test"
_PG_IMAGE = "docker.io/library/postgres:18.6-trixie@sha256:86c951e05bf56c93d95d397747fb8820ac76cc3bedb78f43abd83eedbe3666ae"


@pytest.fixture(scope="session")
def postgres_container() -> Any:
    """Spin up PostgreSQL 18.6 with a separate non-superuser test role."""

    with PostgresContainer(
        image=_PG_IMAGE,
        dbname=_TEST_DB,
        username="postgres",  # bootstrap superuser
        password="postgres",
    ) as pg:
        bootstrap_dsn = (
            f"postgresql://postgres:postgres"
            f"@{pg.get_container_host_ip()}"
            f":{pg.get_exposed_port(5432)}/{_TEST_DB}"
        )

        # Connect as the bootstrap superuser and create a non-superuser role
        # with only the minimal privileges the agent needs.
        with psycopg.connect(bootstrap_dsn, autocommit=True) as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s",
                (_TEST_ROLE,),
            )
            if cur.fetchone() is None:
                cur.execute(
                    f"CREATE ROLE {_TEST_ROLE} "
                    f"WITH LOGIN PASSWORD '{_TEST_ROLE_PASSWORD}' NOSUPERUSER"
                )
            cur.execute(f"GRANT pg_monitor TO {_TEST_ROLE}")
            cur.execute(f"GRANT pg_signal_backend TO {_TEST_ROLE}")
            cur.execute(f"GRANT ALL PRIVILEGES ON DATABASE {_TEST_DB} TO {_TEST_ROLE}")
            # The test role needs to create tables for the lock-wait test.
            cur.execute(f"GRANT ALL ON SCHEMA public TO {_TEST_ROLE}")

        yield pg


@pytest_asyncio.fixture
async def pg_pool(
    postgres_container: Any,
) -> AsyncIterator[AsyncConnectionPool]:
    """Async pool logged in as the non-superuser test role."""

    dsn = (
        f"postgresql://{_TEST_ROLE}:{_TEST_ROLE_PASSWORD}"
        f"@{postgres_container.get_container_host_ip()}"
        f":{postgres_container.get_exposed_port(5432)}/{_TEST_DB}"
    )

    pool = AsyncConnectionPool(
        conninfo=dsn,
        min_size=1,
        max_size=5,
        open=False,
    )
    await pool.open()

    try:
        yield pool
    finally:
        await pool.close()


@pytest_asyncio.fixture
async def context(pg_pool: AsyncConnectionPool) -> SREContext:
    """Build an SREContext carrying the real psycopg pool."""
    from unittest.mock import AsyncMock

    ctx = SREContext(db_session=AsyncMock())  # type: ignore[arg-type]
    ctx.pg_pool = pg_pool  # type: ignore[attr-defined]
    return ctx


@pytest_asyncio.fixture
async def registry(context: SREContext) -> ToolRegistry:
    """Registry with only the Postgres tools registered."""
    reg = ToolRegistry()
    pg_tools.register(reg, context)
    return reg


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_connection_stats_returns_shape(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    result = await registry.execute("get_connection_stats", {}, context=context)
    stats = result["stats"]
    assert stats["total_connections"] >= 1
    assert stats["max_connections"] > 0
    assert 0.0 <= stats["utilisation_pct"] <= 100.0


@pytest.mark.asyncio
async def test_get_active_queries_returns_shape(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    result = await registry.execute(
        "get_active_queries",
        {"min_duration_seconds": 0, "limit": 10},
        context=context,
    )
    assert isinstance(result["queries"], list)
    assert result["total_running"] >= 0


@pytest.mark.asyncio
async def test_get_active_queries_sees_long_query(
    registry: ToolRegistry,
    context: SREContext,
    pg_pool: AsyncConnectionPool,
) -> None:
    """A background pg_sleep should be visible in pg_stat_activity."""
    task = asyncio.create_task(_slow_query(pg_pool))
    try:
        deadline = asyncio.get_running_loop().time() + 5.0
        while True:
            result = await registry.execute(
                "get_active_queries",
                {"min_duration_seconds": 0, "limit": 20},
                context=context,
            )
            if any(
                row["state"] == "active" and "pg_sleep" in row["query"] for row in result["queries"]
            ):
                break
            if asyncio.get_running_loop().time() >= deadline:
                raise AssertionError("pg_sleep was not visible in pg_stat_activity")
            await asyncio.sleep(0.05)
    finally:
        if not task.done():
            task.cancel()
        with suppress(asyncio.CancelledError):
            await task


async def _slow_query(pool: AsyncConnectionPool) -> None:
    async with pool.connection() as conn:
        await conn.set_autocommit(True)
        await conn.execute("SELECT pg_sleep(3)")


@pytest.mark.asyncio
async def test_get_lock_waits_sees_blocker(
    registry: ToolRegistry,
    context: SREContext,
    pg_pool: AsyncConnectionPool,
) -> None:
    """Create a real row lock and verify the tool exposes the wait graph."""
    async with pg_pool.connection() as setup_conn:
        await setup_conn.set_autocommit(True)
        await setup_conn.execute(
            "CREATE TABLE IF NOT EXISTS autosre_lock_test "
            "(id integer PRIMARY KEY, value integer NOT NULL)"
        )
        await setup_conn.execute(
            "INSERT INTO autosre_lock_test (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING"
        )

    async with (
        pg_pool.connection() as holder,
        pg_pool.connection() as waiter,
    ):
        await holder.execute("BEGIN")
        await holder.execute("SELECT * FROM autosre_lock_test WHERE id = 1 FOR UPDATE")

        waiter_task = asyncio.create_task(_blocked_update(waiter))
        try:
            deadline = asyncio.get_running_loop().time() + 5.0
            while True:
                result = await registry.execute("get_lock_waits", {"limit": 20}, context=context)
                if any(row["blocking_pid"] == holder.info.backend_pid for row in result["waits"]):
                    break
                if asyncio.get_running_loop().time() >= deadline:
                    raise AssertionError("lock wait was not visible in pg_locks")
                await asyncio.sleep(0.05)
        finally:
            if not waiter_task.done():
                waiter_task.cancel()
            with suppress(asyncio.CancelledError):
                await waiter_task
            with suppress(Exception):
                await waiter.rollback()
            with suppress(Exception):
                await holder.rollback()


async def _blocked_update(conn: Any) -> None:
    try:
        await conn.execute("UPDATE autosre_lock_test SET value = value + 1 WHERE id = 1")
    except asyncio.CancelledError:
        with suppress(Exception):
            await conn.rollback()
        raise


@pytest.mark.asyncio
async def test_terminate_backend_kills_real_session(
    registry: ToolRegistry,
    context: SREContext,
    pg_pool: AsyncConnectionPool,
) -> None:
    """Open a non-superuser backend and terminate it via the tool."""
    victim = await pg_pool.getconn()
    victim_pid = victim.info.backend_pid

    try:
        await victim.set_autocommit(True)
        sleep_task = asyncio.create_task(_sleep_on_conn(victim))
        try:
            deadline = asyncio.get_running_loop().time() + 5.0
            while True:
                result = await registry.execute(
                    "get_active_queries",
                    {"min_duration_seconds": 0, "limit": 20},
                    context=context,
                )
                if any(
                    row["pid"] == victim_pid and "pg_sleep" in row["query"]
                    for row in result["queries"]
                ):
                    break
                if asyncio.get_running_loop().time() >= deadline:
                    raise AssertionError("victim session was not visible")
                await asyncio.sleep(0.05)

            result = await registry.execute(
                "terminate_backend",
                {"pid": victim_pid, "reason": "integration test"},
                context=context,
            )
            assert result["pid"] == victim_pid
            assert result["terminated"] is True
        finally:
            if not sleep_task.done():
                sleep_task.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await sleep_task
    finally:
        with suppress(Exception):
            await pg_pool.putconn(victim)


async def _sleep_on_conn(conn: Any) -> None:
    try:
        await conn.execute("SELECT pg_sleep(10)")
    except Exception:
        raise


@pytest.mark.asyncio
async def test_terminate_backend_refuses_own_backend(
    registry: ToolRegistry,
    pg_pool: AsyncConnectionPool,
) -> None:
    """The tool must refuse to kill the connection it's running on."""
    conn = await pg_pool.getconn()
    try:
        await conn.set_autocommit(True)

        class _StaticPool:
            @asynccontextmanager
            async def connection(self) -> AsyncIterator[Any]:
                yield conn

        from unittest.mock import AsyncMock

        test_context = SREContext(db_session=AsyncMock())  # type: ignore[arg-type]
        test_context.pg_pool = _StaticPool()  # type: ignore[attr-defined]

        test_registry = ToolRegistry()
        pg_tools.register(test_registry, test_context)

        with pytest.raises(ToolExecutionError, match="own connection"):
            await test_registry.execute(
                "terminate_backend",
                {"pid": conn.info.backend_pid, "reason": "should be rejected"},
                context=test_context,
            )
    finally:
        with suppress(Exception):
            await pg_pool.putconn(conn)
