"""FastAPI application factory and lifecycle management.

## Lifespan

Startup opens resources in this order:

    1. Telemetry (OTel TracerProvider + instrumentors)
    2. Postgres connection pool (diagnostic tools)
    3. Valkey client (cache diagnostics)
    4. OpenObserve client (log/metric queries)
    5. K8s client (optional; failures are non-fatal)
    6. LangGraph AsyncPostgresSaver (state persistence)
    7. SREContext (aggregates 2-5)
    8. Tool registry
    9. Policy engine + SafeExecutor
   10. Context eviction middleware
   11. GraphContext (aggregates 1, 8, 9, 10)
   12. Compiled graph
   13. LangGraphRunner (aggregates 12, 6, 7, 11)

Shutdown unwinds in reverse via AsyncExitStack. Telemetry is registered
first so it is torn down last, capturing traces of every other shutdown.

## Application state

Every resource that a route needs is stored on `app.state`:

    settings            Explicit Settings object (never the cache)
    paused              Boolean; True blocks new /alerts dispatches
    pause_reason        Optional reason string surfaced by /admin/status
    pg_pool             psycopg AsyncConnectionPool
    valkey_client       redis.asyncio.Redis
    openobserve_client  OpenObserveClient
    sre_context         SREContext
    registry            ToolRegistry
    policy_engine       PolicyEngine
    executor            SafeExecutor
    runner              LangGraphRunner
    checkpointer        AsyncPostgresSaver

## Static file serving

When `ui/dist` exists, SPA assets and index.html are served for any path
that is not a reserved API prefix. The reservation list must stay in
sync with the routers registered below. A missing or incomplete
`ui/dist` degrades gracefully to API-only mode.

## Version

Single source of truth is `autosre.__version__`. If the package is
imported without that attribute (e.g., before the first patch), the
fallback is `"0.0.0+unknown"` and a warning is logged at startup.
"""

from __future__ import annotations

import logging
import os
from collections.abc import AsyncIterator, Iterable
from contextlib import AsyncExitStack, asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from psycopg_pool import AsyncConnectionPool
from redis.asyncio import Redis

from autosre import __version__ as _pkg_version
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

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Path prefixes that must never fall through to the SPA fallback. Keep
# in sync with the routers registered in create_app().
_RESERVED_PREFIXES: tuple[str, ...] = (
    "healthz",
    "readyz",
    "alerts",
    "incidents",
    "metrics",
    "admin",
    "api/",
    "slack",
    "docs",
    "openapi.json",
    "redoc",
)

# Default CORS origins for local development. Override with
# AUTOSRE_CORS_ORIGINS as a comma-separated list.
_DEFAULT_CORS_ORIGINS: tuple[str, ...] = (
    "http://localhost:5173",
    "http://127.0.0.1:5173",
)


# ---------------------------------------------------------------------------
# CORS resolution
# ---------------------------------------------------------------------------


def _resolve_cors_origins() -> list[str]:
    """Return the list of allowed CORS origins.

    Reads AUTOSRE_CORS_ORIGINS (comma-separated) or falls back to the
    local development defaults. Wildcard origin "*" is never returned
    because allow_credentials=True is incompatible with it.
    """
    raw = os.getenv("AUTOSRE_CORS_ORIGINS", "").strip()
    if not raw:
        return list(_DEFAULT_CORS_ORIGINS)

    origins = [item.strip() for item in raw.split(",") if item.strip()]

    if "*" in origins:
        logger.warning(
            "Ignoring wildcard '*' in AUTOSRE_CORS_ORIGINS; "
            "allow_credentials is incompatible with wildcards"
        )
        origins = [o for o in origins if o != "*"]

    return origins or list(_DEFAULT_CORS_ORIGINS)


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Open every resource at startup, close in reverse at shutdown.

    Telemetry is registered first so its shutdown callback runs last,
    capturing traces from every other cleanup. This ordering is
    deliberate; do not reorder without understanding the tradeoff.
    """
    settings: Settings = app.state.settings

    async with AsyncExitStack() as stack:
        # ----------------------------------------------------------
        # 1. Telemetry — registered first so it shuts down last.
        # ----------------------------------------------------------
        shutdown_telemetry = init_telemetry(settings)
        stack.callback(shutdown_telemetry)
        instrument_fastapi(app)
        logger.info("OpenTelemetry initialized and FastAPI instrumented")

        # ----------------------------------------------------------
        # 2. Postgres diagnostic pool.
        # ----------------------------------------------------------
        raw_dsn = settings.postgres.raw_dsn
        pg_pool = AsyncConnectionPool(
            conninfo=raw_dsn,
            min_size=2,
            max_size=10,
            open=False,
        )
        stack.push_async_callback(pg_pool.close)
        await pg_pool.open()
        logger.info("Postgres diagnostic pool opened (min=2 max=10)")

        # ----------------------------------------------------------
        # 3. Valkey client.
        # ----------------------------------------------------------
        valkey_client = Redis(
            host=os.getenv("AUTOSRE_VALKEY__HOST", "localhost"),
            port=int(os.getenv("AUTOSRE_VALKEY__PORT", "6379")),
            password=os.getenv("AUTOSRE_VALKEY__PASSWORD") or None,
            ssl=os.getenv("AUTOSRE_VALKEY__TLS", "false").lower() == "true",
            decode_responses=True,
        )
        stack.push_async_callback(valkey_client.aclose)
        logger.info("Valkey client created")

        # ----------------------------------------------------------
        # 4. OpenObserve client.
        # ----------------------------------------------------------
        o11y_client = OpenObserveClient(settings)
        stack.push_async_callback(o11y_client.close)
        logger.info("OpenObserve client created")

        # ----------------------------------------------------------
        # 5. K8s client (optional; failure is non-fatal).
        # ----------------------------------------------------------
        k8s_client_instance = None
        try:
            import kr8s.asyncio

            k8s_client_instance = await kr8s.asyncio.api()
            await k8s_client_instance.version()
            logger.info("kr8s client initialized")
        except Exception as exc:
            logger.warning(
                "kr8s unavailable; K8s-backed tools will raise on use: %s",
                exc,
            )

        # ----------------------------------------------------------
        # 6. LangGraph AsyncPostgresSaver.
        # ----------------------------------------------------------
        os.environ.setdefault("LANGGRAPH_STRICT_MSGPACK", "true")
        checkpointer = await stack.enter_async_context(AsyncPostgresSaver.from_conn_string(raw_dsn))
        await checkpointer.setup()
        logger.info("LangGraph AsyncPostgresSaver initialized and setup")

        # ----------------------------------------------------------
        # 7. SREContext.
        # ----------------------------------------------------------
        llm_router = TokenVelocityRouter(settings.llm, threshold_tokens=6000)

        sre_context = SREContext(
            db_session=None,
            llm_config=settings.llm,
            k8s_client=k8s_client_instance,
            llm_router=llm_router,
            openobserve_client=o11y_client,
            pg_pool=pg_pool,
            valkey_client=valkey_client,
        )
        logger.info("SREContext assembled")

        # ----------------------------------------------------------
        # 8. Tool registry.
        # ----------------------------------------------------------
        registry = build_default_registry(settings, sre_context)
        logger.info("Tool registry built with %d tools", len(registry.list_tools()))

        # ----------------------------------------------------------
        # 9. Policy engine + SafeExecutor.
        # ----------------------------------------------------------
        policy_engine = PolicyEngine(
            max_autonomous_tier=RiskTier.REVERSIBLE_LOW,
        )
        executor = SafeExecutor(registry, policy_engine)
        logger.info("Policy engine and SafeExecutor initialized")

        # ----------------------------------------------------------
        # 10. Context eviction.
        # ----------------------------------------------------------
        context_eviction = ContextEviction()

        # ----------------------------------------------------------
        # 11. GraphContext.
        # ----------------------------------------------------------
        graph_context = GraphContext(
            llm_router=llm_router,
            registry=registry,
            executor=executor,
            policy_engine=policy_engine,
            context_eviction=context_eviction,
        )
        logger.info("GraphContext assembled")

        # ----------------------------------------------------------
        # 12. Compiled graph.
        # ----------------------------------------------------------
        graph = compile_graph(checkpointer=checkpointer)
        logger.info("LangGraph compiled")

        # ----------------------------------------------------------
        # 13. Runner.
        # ----------------------------------------------------------
        runner = LangGraphRunner(
            graph=graph,
            checkpointer=checkpointer,
            sre_context=sre_context,
            graph_context=graph_context,
            max_wall_clock_seconds=settings.safety.max_wall_clock_seconds,
        )
        logger.info(
            "LangGraphRunner initialized (max_wall_clock_seconds=%d)",
            settings.safety.max_wall_clock_seconds,
        )

        # ----------------------------------------------------------
        # Expose on app.state.
        # ----------------------------------------------------------
        app.state.pg_pool = pg_pool
        app.state.valkey_client = valkey_client
        app.state.openobserve_client = o11y_client
        app.state.sre_context = sre_context
        app.state.registry = registry
        app.state.policy_engine = policy_engine
        app.state.executor = executor
        app.state.runner = runner
        app.state.checkpointer = checkpointer

        # ----------------------------------------------------------
        # Admin secret posture. Warn if unset so operators know the
        # kill switch is disabled.
        # ----------------------------------------------------------
        admin_secret = getattr(getattr(settings, "admin", None), "secret", None)
        if admin_secret is None:
            logger.warning(
                "Admin endpoints are disabled: AUTOSRE_ADMIN__SECRET is unset. "
                "Set it to enable /admin/pause, /admin/resume, /admin/status."
            )

        logger.info("AutoSRE agent ready to receive alerts")

        try:
            yield
        finally:
            logger.info("AutoSRE agent shutting down...")

    logger.info("AutoSRE agent shutdown complete")


# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create and configure the FastAPI application."""
    if settings is None:
        settings = get_settings()

    app = FastAPI(
        title="AutoSRE Agent",
        description=(
            "Autonomous SRE investigation and remediation agent. See /docs for the interactive API."
        ),
        version=_pkg_version,
        lifespan=lifespan,
    )

    # ---------------------------------------------------------------
    # Application state seeding (lifespan overwrites some of these).
    # ---------------------------------------------------------------
    app.state.settings = settings
    app.state.paused = False
    app.state.pause_reason = None

    # ---------------------------------------------------------------
    # CORS.
    # ---------------------------------------------------------------
    cors_origins = _resolve_cors_origins()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    logger.info("CORS origins: %s", cors_origins)

    # ---------------------------------------------------------------
    # Routers. Order matters only for path-shadowing; the reserved
    # prefix list in _RESERVED_PREFIXES must be a superset of every
    # path these routers serve.
    # ---------------------------------------------------------------
    app.include_router(router)
    app.include_router(webhook_router)

    # ---------------------------------------------------------------
    # SPA serving.
    # ---------------------------------------------------------------
    _mount_spa_if_available(app)

    return app


def create_app_factory() -> FastAPI:
    """Zero-argument factory for ``uvicorn --factory``."""
    return create_app()


# ---------------------------------------------------------------------------
# SPA mounting
# ---------------------------------------------------------------------------


def _is_reserved_path(full_path: str) -> bool:
    """Return True when the path is an API route, not an SPA route."""
    if not full_path:
        return False
    for prefix in _RESERVED_PREFIXES:
        if full_path == prefix or full_path.startswith(prefix + "/"):
            return True
        # Support multi-segment prefixes like "api/" already ending in "/".
        if prefix.endswith("/") and full_path.startswith(prefix):
            return True
    return False


def _mount_spa_if_available(app: FastAPI) -> None:
    """Mount the built SPA when ui/dist exists; otherwise log and skip."""
    project_root = Path(__file__).resolve().parent.parent.parent.parent
    ui_dist = project_root / "ui" / "dist"

    if not (ui_dist.exists() and ui_dist.is_dir()):
        logger.warning("UI dist not found at %s; running in API-only mode", ui_dist)
        return

    index_html = ui_dist / "index.html"
    if not index_html.is_file():
        logger.warning(
            "UI dist found but index.html missing at %s; API-only mode",
            index_html,
        )
        return

    from fastapi.responses import FileResponse
    from fastapi.staticfiles import StaticFiles

    assets_dir = ui_dist / "assets"
    if assets_dir.is_dir():
        app.mount(
            "/assets",
            StaticFiles(directory=str(assets_dir)),
            name="static-assets",
        )

    @app.get("/{full_path:path}")
    async def spa_fallback(full_path: str) -> FileResponse:
        """Serve the SPA index for any non-API path.

        Reserved prefixes are guarded so that a missing route under
        /incidents, /metrics, /admin, etc. does not accidentally return
        HTML to an API client.
        """
        if _is_reserved_path(full_path):
            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(str(index_html))

    logger.info("Serving React UI from %s", ui_dist)


# ---------------------------------------------------------------------------
# Entrypoint shim
# ---------------------------------------------------------------------------


def _iter_registered_paths(app: FastAPI) -> Iterable[str]:
    """Yield every registered route path for logging/diagnostics."""
    for route in app.routes:
        path = getattr(route, "path", None)
        if isinstance(path, str):
            yield path


__all__ = [
    "create_app",
    "create_app_factory",
    "lifespan",
]
