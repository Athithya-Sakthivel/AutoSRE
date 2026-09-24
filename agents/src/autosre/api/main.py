"""FastAPI application factory and lifecycle management."""

from __future__ import annotations

import logging
import os
from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from psycopg_pool import AsyncConnectionPool
from redis.asyncio import Redis

from autosre.api.routes import router, webhook_router
from autosre.api.runner import LangGraphRunner
from autosre.config import Settings, get_settings
from autosre.core.context import ContextEviction
from autosre.core.graph import compile_graph
from autosre.core.graph_helpers import GraphContext
from autosre.core.router import TokenVelocityRouter
from autosre.core.state import SREContext
from autosre.safety import PolicyEngine, SafeExecutor
from autosre.safety.policy import RiskTier
from autosre.telemetry import init_telemetry, instrument_fastapi
from autosre.tools import build_default_registry
from autosre.tools.observability import OpenObserveClient

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Initialize application resources and clean them up safely."""
    settings: Settings = app.state.settings

    async with AsyncExitStack() as stack:
        # 1. Telemetry
        shutdown_telemetry_fn = init_telemetry(settings)
        stack.callback(shutdown_telemetry_fn)
        instrument_fastapi(app)
        logger.info("FastAPI instrumented with OpenTelemetry")

        # 2. LLM router
        llm_router = TokenVelocityRouter(settings.llm, threshold_tokens=6000)

        # 3. Postgres diagnostic pool
        raw_dsn = settings.postgres.raw_dsn
        pg_pool = AsyncConnectionPool(conninfo=raw_dsn, min_size=2, max_size=10, open=False)
        stack.push_async_callback(pg_pool.close)
        await pg_pool.open()
        logger.info("Postgres diagnostic pool opened")

        # 4. Valkey client
        valkey_client = Redis(
            host=os.getenv("AUTOSRE_VALKEY__HOST", "localhost"),
            port=int(os.getenv("AUTOSRE_VALKEY__PORT", "6379")),
            password=os.getenv("AUTOSRE_VALKEY__PASSWORD"),
            ssl=(os.getenv("AUTOSRE_VALKEY__TLS", "false").lower() == "true"),
            decode_responses=True,
        )
        stack.push_async_callback(valkey_client.aclose)
        logger.info("Valkey client created")

        # 5. OpenObserve client
        o11y_client = OpenObserveClient(settings)
        stack.push_async_callback(o11y_client.close)
        logger.info("OpenObserve client created")

        # 6. LangGraph checkpointer
        os.environ.setdefault("LANGGRAPH_STRICT_MSGPACK", "true")
        checkpointer = await stack.enter_async_context(AsyncPostgresSaver.from_conn_string(raw_dsn))
        await checkpointer.setup()
        logger.info("LangGraph AsyncPostgresSaver initialized")

        # 7. K8s client (optional)
        k8s_client_instance = None
        try:
            import kr8s.asyncio

            k8s_client_instance = await kr8s.asyncio.api()
            await k8s_client_instance.version()
            logger.info("kr8s client initialized")
        except Exception as exc:
            logger.warning("kr8s client unavailable (K8s tools disabled): %s", exc)

        # 8. SREContext
        sre_context = SREContext(
            db_session=None,
            llm_config=settings.llm,
            k8s_client=k8s_client_instance,
            llm_router=llm_router,
            openobserve_client=o11y_client,
            pg_pool=pg_pool,
            valkey_client=valkey_client,
        )

        # 9. Tool registry
        registry = build_default_registry(settings, sre_context)
        logger.info("Tool registry built with %d tools", len(registry.list_tools()))

        # 10. Safety layer
        policy_engine = PolicyEngine(max_autonomous_tier=RiskTier.REVERSIBLE_LOW)
        executor = SafeExecutor(registry, policy_engine)
        logger.info("Policy engine and safe executor initialized")

        # 11. Context eviction middleware
        context_eviction = ContextEviction()

        # 12. Graph context
        graph_context = GraphContext(
            llm_router=llm_router,
            registry=registry,
            executor=executor,
            policy_engine=policy_engine,
            context_eviction=context_eviction,
        )

        # 13. Compile graph
        graph = compile_graph(checkpointer=checkpointer)

        # 14. Runner — pass all 4 args: graph, checkpointer, sre_context, graph_context
        runner = LangGraphRunner(
            graph=graph,
            checkpointer=checkpointer,
            sre_context=sre_context,
            graph_context=graph_context,
        )
        logger.info("LangGraph runner initialized")

        # 15. Store in app.state
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


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create and configure the FastAPI application."""
    if settings is None:
        settings = get_settings()

    app = FastAPI(
        title="AutoSRE Agent",
        description="Autonomous SRE investigation and remediation agent",
        version="0.1.0",
        lifespan=lifespan,
    )

    # CORS for development (Vite dev server on :5173)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.state.settings = settings

    app.include_router(router)
    app.include_router(webhook_router)

    # Serve UI static files if built
    _project_root = Path(__file__).resolve().parent.parent.parent.parent
    ui_dist = _project_root / "ui" / "dist"

    if ui_dist.exists() and ui_dist.is_dir():
        from fastapi.responses import FileResponse
        from fastapi.staticfiles import StaticFiles

        assets_dir = ui_dist / "assets"
        if assets_dir.exists():
            app.mount(
                "/assets",
                StaticFiles(directory=str(assets_dir)),
                name="static-assets",
            )

        @app.get("/{full_path:path}")
        async def spa_fallback(full_path: str) -> FileResponse:
            if full_path.startswith("api/") or full_path.startswith("slack/"):
                raise HTTPException(status_code=404, detail="Not found")
            return FileResponse(str(ui_dist / "index.html"))

        logger.info("Serving React UI from %s", ui_dist)
    else:
        logger.warning("UI dist not found at %s; API-only mode", ui_dist)

    return app


def create_app_factory() -> FastAPI:
    """Zero-argument factory for ``uvicorn --factory``."""
    return create_app()
