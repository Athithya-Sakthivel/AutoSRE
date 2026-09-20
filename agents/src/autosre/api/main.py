"""FastAPI application factory and lifecycle management."""

from __future__ import annotations

import logging
import os
from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager

from fastapi import FastAPI
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from psycopg_pool import AsyncConnectionPool
from redis.asyncio import Redis
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from autosre.api.routes import router, webhook_router
from autosre.api.runner import StubIncidentRunner
from autosre.config import Settings
from autosre.core.state import SREContext
from autosre.safety import PolicyEngine, SafeExecutor
from autosre.safety.policy import RiskTier
from autosre.telemetry import (
    init_telemetry,
    instrument_fastapi,
)
from autosre.tools import build_default_registry
from autosre.tools.observability import OpenObserveClient

logger = logging.getLogger(__name__)


def _render_postgres_dsn(dsn: str) -> str:
    """Normalize a PostgreSQL URL for direct psycopg connections."""
    try:
        url = make_url(dsn)
    except Exception as exc:
        raise RuntimeError("Invalid PostgreSQL DSN in settings.postgres.dsn") from exc

    if url.get_backend_name() != "postgresql":
        raise RuntimeError("settings.postgres.dsn must use a PostgreSQL SQLAlchemy URL")

    return url.set(drivername="postgresql").render_as_string(hide_password=False)


def _render_sqlalchemy_async_dsn(dsn: str) -> str:
    """Normalize a PostgreSQL URL for SQLAlchemy's async psycopg dialect."""
    try:
        url = make_url(dsn)
    except Exception as exc:
        raise RuntimeError("Invalid PostgreSQL DSN in settings.postgres.dsn") from exc

    if url.get_backend_name() != "postgresql":
        raise RuntimeError("settings.postgres.dsn must use a PostgreSQL SQLAlchemy URL")

    # SQLAlchemy 2.x supports the psycopg dialect directly with
    # create_async_engine(); no asyncpg translation is required.
    return url.set(drivername="postgresql+psycopg").render_as_string(hide_password=False)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Initialize application resources and clean them up safely."""
    settings: Settings = app.state.settings

    raw_postgres_dsn = _render_postgres_dsn(settings.postgres.dsn)
    sqlalchemy_postgres_dsn = _render_sqlalchemy_async_dsn(settings.postgres.dsn)

    async with AsyncExitStack() as stack:
        # Register telemetry shutdown first so AsyncExitStack executes it last.
        shutdown_telemetry_fn = init_telemetry(settings)
        stack.callback(shutdown_telemetry_fn)

        instrument_fastapi(app)
        logger.info("FastAPI instrumented with OpenTelemetry")

        engine = create_async_engine(
            sqlalchemy_postgres_dsn,
            pool_size=5,
            max_overflow=10,
            echo=False,
        )
        stack.push_async_callback(engine.dispose)

        async_session_factory = async_sessionmaker(
            engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )

        pg_pool = AsyncConnectionPool(
            conninfo=raw_postgres_dsn,
            min_size=2,
            max_size=10,
            open=False,
        )
        stack.push_async_callback(pg_pool.close)

        await pg_pool.open()
        logger.info("Postgres diagnostic pool opened")

        valkey_client = Redis(
            host=os.getenv(
                "VALKEY_HOST",
                "localhost",
            ),
            port=int(
                os.getenv(
                    "VALKEY_PORT",
                    "6379",
                )
            ),
            password=os.getenv("VALKEY_PASSWORD"),
            ssl=(
                os.getenv(
                    "VALKEY_TLS",
                    "false",
                ).lower()
                == "true"
            ),
            decode_responses=True,
        )
        stack.push_async_callback(valkey_client.aclose)
        logger.info("Valkey client created")

        o11y_client = OpenObserveClient(settings)
        stack.push_async_callback(o11y_client.close)
        logger.info("OpenObserve client created")

        # LangGraph explicitly recommends strict checkpoint deserialization
        # for new applications to prevent unsafe msgpack type loading.
        os.environ.setdefault(
            "LANGGRAPH_STRICT_MSGPACK",
            "true",
        )

        # AsyncPostgresSaver.from_conn_string() is an async context manager.
        # Its context owns the underlying psycopg AsyncConnection.
        checkpointer = await stack.enter_async_context(
            AsyncPostgresSaver.from_conn_string(raw_postgres_dsn)
        )

        # Required the first time the saver is used; the operation is
        # migration-aware and safe to call again.
        await checkpointer.setup()

        logger.info("LangGraph AsyncPostgresSaver initialized and setup")

        # Preserve the existing SREContext constructor contract.
        db_session = await stack.enter_async_context(async_session_factory())

        sre_context = SREContext(
            db_session=db_session,
            k8s_client=None,
            llm_router=None,
            openobserve_client=o11y_client,
            pg_pool=pg_pool,
            valkey_client=valkey_client,
        )

        registry = build_default_registry(
            settings,
            sre_context,
        )

        logger.info(
            "Tool registry built with %d tools",
            len(registry.list_tools()),
        )

        policy_engine = PolicyEngine(
            max_autonomous_tier=RiskTier.REVERSIBLE_LOW,
        )

        executor = SafeExecutor(
            registry,
            policy_engine,
        )

        logger.info("Policy engine and safe executor initialized")

        runner = StubIncidentRunner()

        logger.info("Incident runner initialized (Phase 8 stub)")

        # Store resources in app.state for dependency injection.
        app.state.db_engine = engine
        app.state.db_session_factory = async_session_factory
        app.state.db_session = db_session
        app.state.pg_pool = pg_pool
        app.state.valkey_client = valkey_client
        app.state.openobserve_client = o11y_client
        app.state.sre_context = sre_context
        app.state.registry = registry
        app.state.policy_engine = policy_engine
        app.state.executor = executor
        app.state.runner = runner
        app.state.checkpointer = checkpointer

        logger.info("AutoSRE agent ready to receive alerts")

        try:
            yield
        finally:
            logger.info("Shutting down AutoSRE agent...")

    logger.info("AutoSRE agent shutdown complete")


def create_app(settings: Settings) -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(
        title="AutoSRE Agent",
        description=("Autonomous SRE investigation and remediation agent"),
        version="0.1.0",
        lifespan=lifespan,
    )

    app.state.settings = settings

    app.include_router(router)
    app.include_router(webhook_router)

    logger.info("FastAPI app created (OTel instrumentation deferred to lifespan)")

    return app
