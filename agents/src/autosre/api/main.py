"""FastAPI application factory and lifecycle management.

## Lifespan

Startup opens resources in order. Shutdown unwinds in reverse via
AsyncExitStack. Telemetry is registered first so it is torn down last.

    1. Telemetry (OTel TracerProvider + instrumentors)
    2. Postgres connection pool
    3. Valkey client
    4. OpenObserve client
    5. K8s client (optional; failures are non-fatal)
    6. LangGraph AsyncPostgresSaver
    7. SREContext
    8. Tool registry
    9. Policy engine + SafeExecutor
   10. Context eviction
   11. GraphContext
   12. Compiled graph
   13. LangGraphRunner
   14. Slack integration (optional; failures are non-fatal)

## Slack integration

Slack is enabled only when ``settings.slack.is_enabled`` is True, which
requires the credential set matching ``settings.slack.mode``:

    mode="socket"   bot_token + app_token
    mode="http"     bot_token + signing_secret

When enabled, the lifespan constructs:

    SlackClient         HTTP client for post_message / update_message
    SlackHandler        Verifies inbound interactions; dispatches approvals
    ApprovalListener    Polls for HITL-pending incidents; posts to Slack
    SlackSocketMode     WebSocket transport for interactions (socket mode)

Socket Mode startup is fail-soft: if the WebSocket cannot connect, the
listener still posts approval requests to Slack. Operators can approve
via the UI; the socket only carries button clicks. Losing the socket
degrades, not kills.

Every Slack constructor is wrapped in try/except so a Slack config error
does not prevent the agent from starting. When Slack fails to initialize,
``app.state.slack_*`` are set to None and the approval flow falls back
to the UI.

## Static file serving

When ``ui/dist`` exists, SPA assets and index.html are served for any
path that is not a reserved API prefix. The reservation list must stay
in sync with the routers registered below.
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

# Path prefixes that must never fall through to the SPA fallback. Keep in
# sync with the routers registered in create_app().
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
# Slack lifecycle helpers
# ---------------------------------------------------------------------------


async def _start_slack(
    app: FastAPI,
    stack: AsyncExitStack,
    settings: Settings,
    runner: LangGraphRunner,
) -> None:
    """Construct and start the Slack integration when enabled.

    Every failure path is caught and logged; the agent starts regardless.
    The four components are pushed onto the exit stack in reverse
    shutdown order:

        socket.stop   -> listener.stop   -> handler.close   -> client.close

    Registration order is the reverse of construction order because
    AsyncExitStack runs callbacks in LIFO order.
    """
    # Seed None defaults so app.state always has the attributes.
    app.state.slack_client = None
    app.state.slack_handler = None
    app.state.slack_socket = None
    app.state.slack_listener = None

    if not settings.slack.is_enabled:
        logger.info("Slack integration disabled (set AUTOSRE_SLACK__BOT_TOKEN to enable)")
        return

    try:
        from autosre.slack import (
            ApprovalListener,
            SlackClient,
            SlackHandler,
            SlackSocketMode,
        )
    except Exception:
        logger.exception("Slack package failed to import; continuing without Slack")
        return

    try:
        slack_client = SlackClient(settings.slack)
    except Exception:
        logger.exception("SlackClient construction failed; continuing without Slack")
        return

    stack.push_async_callback(slack_client.close)

    try:
        slack_handler = SlackHandler(
            config=settings.slack,
            runner=runner,
            client=slack_client,
            approver_user_ids=settings.slack.approver_user_ids,
        )
    except Exception:
        logger.exception("SlackHandler construction failed; continuing without Slack")
        return

    stack.push_async_callback(slack_handler.close)

    try:
        slack_listener = ApprovalListener(
            runner=runner,
            slack_client=slack_client,
        )
    except Exception:
        logger.exception("ApprovalListener construction failed; continuing without Slack")
        return

    stack.push_async_callback(slack_listener.stop)

    slack_socket = None

    if settings.slack.mode == "socket":
        try:
            slack_socket = SlackSocketMode(
                config=settings.slack,
                handler=slack_handler,
                client=slack_client,
            )
        except Exception:
            logger.exception(
                "SlackSocketMode construction failed; "
                "button clicks will not be delivered. "
                "Approve via the UI instead."
            )
            slack_socket = None

        if slack_socket is not None:
            stack.push_async_callback(slack_socket.stop)

            try:
                await slack_socket.start()
            except Exception:
                logger.exception(
                    "Slack Socket Mode failed to connect; "
                    "button clicks will not be delivered. "
                    "Approve via the UI instead."
                )
                slack_socket = None

    # The listener polls for HITL-pending incidents and posts them to
    # Slack. It runs regardless of socket availability: the request
    # still reaches the channel; only the callback path degrades.
    try:
        await slack_listener.start()
    except Exception:
        logger.exception(
            "ApprovalListener failed to start; Slack approval requests will not be sent"
        )
        app.state.slack_client = slack_client
        app.state.slack_handler = slack_handler
        app.state.slack_listener = None
        app.state.slack_socket = slack_socket
        return

    app.state.slack_client = slack_client
    app.state.slack_handler = slack_handler
    app.state.slack_listener = slack_listener
    app.state.slack_socket = slack_socket

    logger.info(
        "Slack integration enabled (mode=%s channel=%s socket=%s)",
        settings.slack.mode,
        settings.slack.approval_channel,
        "connected" if slack_socket is not None else "unavailable",
    )


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Open every resource at startup; close in reverse at shutdown."""
    settings: Settings = app.state.settings

    async with AsyncExitStack() as stack:
        # ==============================================================
        # 1. Telemetry — registered first so it shuts down last.
        # ==============================================================
        shutdown_telemetry = init_telemetry(settings)
        stack.callback(shutdown_telemetry)
        instrument_fastapi(app)
        logger.info("OpenTelemetry initialized and FastAPI instrumented")

        # ==============================================================
        # 2. Postgres diagnostic pool.
        # ==============================================================
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

        # ==============================================================
        # 3. Valkey client.
        # ==============================================================
        valkey_client = Redis(
            host=os.getenv("AUTOSRE_VALKEY__HOST", "localhost"),
            port=int(os.getenv("AUTOSRE_VALKEY__PORT", "6379")),
            password=os.getenv("AUTOSRE_VALKEY__PASSWORD") or None,
            ssl=os.getenv("AUTOSRE_VALKEY__TLS", "false").lower() == "true",
            decode_responses=True,
        )
        stack.push_async_callback(valkey_client.aclose)
        logger.info("Valkey client created")

        # ==============================================================
        # 4. OpenObserve client.
        # ==============================================================
        o11y_client = OpenObserveClient(settings)
        stack.push_async_callback(o11y_client.close)
        logger.info("OpenObserve client created")

        # ==============================================================
        # 5. K8s client (optional; failure is non-fatal).
        # ==============================================================
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

        # ==============================================================
        # 6. LangGraph AsyncPostgresSaver.
        # ==============================================================
        os.environ.setdefault("LANGGRAPH_STRICT_MSGPACK", "true")
        checkpointer = await stack.enter_async_context(AsyncPostgresSaver.from_conn_string(raw_dsn))
        await checkpointer.setup()
        logger.info("LangGraph AsyncPostgresSaver initialized and setup")

        # ==============================================================
        # 7. SREContext.
        # ==============================================================
        llm_router = TokenVelocityRouter(
            settings.llm,
            threshold_tokens=6000,
            max_llm_calls_per_incident=settings.safety.max_llm_calls_per_incident,
        )

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

        # ==============================================================
        # 8. Tool registry.
        # ==============================================================
        registry = build_default_registry(settings, sre_context)
        logger.info("Tool registry built with %d tools", len(registry.list_tools()))

        # ==============================================================
        # 9. Policy engine + SafeExecutor.
        # ==============================================================
        policy_engine = PolicyEngine(
            max_autonomous_tier=RiskTier.REVERSIBLE_LOW,
        )
        executor = SafeExecutor(registry, policy_engine)
        logger.info("Policy engine and SafeExecutor initialized")

        # ==============================================================
        # 10. Context eviction.
        # ==============================================================
        context_eviction = ContextEviction()

        # ==============================================================
        # 11. GraphContext.
        # ==============================================================
        graph_context = GraphContext(
            llm_router=llm_router,
            registry=registry,
            executor=executor,
            policy_engine=policy_engine,
            context_eviction=context_eviction,
            confidence_propose=settings.safety.confidence_propose,
            confidence_fast_path=settings.safety.confidence_fast_path,
            confidence_give_up=settings.safety.confidence_give_up,
        )

        logger.info("GraphContext assembled")

        # ==============================================================
        # 12. Compiled graph.
        # ==============================================================
        graph = compile_graph(checkpointer=checkpointer)
        logger.info("LangGraph compiled")

        # ==============================================================
        # 13. Runner.
        # ==============================================================
        runner = LangGraphRunner(
            graph=graph,
            checkpointer=checkpointer,
            sre_context=sre_context,
            graph_context=graph_context,
            max_wall_clock_seconds=settings.safety.max_wall_clock_seconds,
        )
        stack.push_async_callback(runner.shutdown, 30.0)
        logger.info(
            "LangGraphRunner initialized (max_wall_clock_seconds=%d)",
            settings.safety.max_wall_clock_seconds,
        )

        # ==============================================================
        # 14. Slack (optional).
        # ==============================================================
        await _start_slack(app, stack, settings, runner)

        # ==============================================================
        # Expose on app.state.
        # ==============================================================
        app.state.pg_pool = pg_pool
        app.state.valkey_client = valkey_client
        app.state.openobserve_client = o11y_client
        app.state.sre_context = sre_context
        app.state.registry = registry
        app.state.policy_engine = policy_engine
        app.state.executor = executor
        app.state.runner = runner
        app.state.checkpointer = checkpointer

        # Admin secret posture. Warn if unset so operators know the
        # kill switch is disabled.
        admin_secret = getattr(getattr(settings, "admin", None), "secret", None)
        if admin_secret is None:
            logger.warning(
                "Admin endpoints are disabled: AUTOSRE_ADMIN__SECRET is "
                "unset. Set it to enable /admin/pause, /admin/resume, "
                "/admin/status."
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

    # Seed application state before the lifespan runs.
    app.state.settings = settings
    app.state.paused = False
    app.state.pause_reason = None
    app.state.slack_client = None
    app.state.slack_handler = None
    app.state.slack_socket = None
    app.state.slack_listener = None

    # CORS.
    cors_origins = _resolve_cors_origins()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    logger.info("CORS origins: %s", cors_origins)

    # Routers.
    app.include_router(router)
    app.include_router(webhook_router)

    # Slack HTTP interactivity routes are only mounted when the configured
    # transport is HTTP. Socket Mode delivers interactions over the
    # WebSocket, so exposing HTTP routes would be dead surface.
    # Slack HTTP interactivity routes are only mounted when the configured
    # transport is HTTP. Socket Mode delivers interactions over the
    # WebSocket, so exposing HTTP routes would be dead surface.
    #
    # Note: the router lives at autosre.slack.slack_routes, not
    # autosre.api.slack_routes. The api/ package contains only the
    # HTTP surface for the agent, not per-integration routers.
    if settings.slack.is_enabled and settings.slack.mode == "http":
        try:
            from autosre.slack.slack_routes import slack_router

            app.include_router(slack_router)
            logger.info("Slack HTTP interactivity routes mounted at /slack/*")
        except Exception:
            logger.exception("Failed to mount Slack HTTP routes; approvals fall back to the UI")
    elif settings.slack.is_enabled:
        logger.info(
            "Slack mode=%s: HTTP interactivity routes not mounted",
            settings.slack.mode,
        )

    # SPA serving.
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
        """Serve the SPA index for any non-API path."""
        if _is_reserved_path(full_path):
            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(str(index_html))

    logger.info("Serving React UI from %s", ui_dist)


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------


def _iter_registered_paths(app: FastAPI) -> Iterable[str]:
    """Yield every registered route path."""
    for route in app.routes:
        path = getattr(route, "path", None)
        if isinstance(path, str):
            yield path


__all__ = [
    "create_app",
    "create_app_factory",
    "lifespan",
]
