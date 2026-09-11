"""FastAPI application – agent‑brain service entrypoint."""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Any

from agent.graph import build_graph
from agent.llm import close_llm_client, init_llm_client
from agent.state import SREState
from agent.tools_client import close_tools_client, get_tools_client
from fastapi import FastAPI, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from infra.auth import require_auth
from infra.config import load_settings
from infra.telemetry import setup_telemetry
from infra.ws import manager
from starlette.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _build_checkpointer(settings: Any) -> Any:
    """Return a LangGraph checkpointer backed by Cosmos DB."""
    try:
        from langgraph.checkpoint.cosmosdb import AsyncCosmosDBSaver
    except ImportError as exc:
        raise RuntimeError("LangGraph CosmosDB checkpointer not installed") from exc

    from azure.cosmos.aio import CosmosClient as AsyncCosmosClient

    client = AsyncCosmosClient(settings.cosmos_endpoint, credential=settings.cosmos_key)
    database = client.get_database_client(settings.cosmos_database)
    container = database.get_container_client(settings.cosmos_container)
    return AsyncCosmosDBSaver(client=client, database=database, container=container)


async def _close_checkpointer(checkpointer: Any) -> None:
    if hasattr(checkpointer, "client"):
        await checkpointer.client.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    settings.preflight()
    setup_telemetry(settings)

    await init_llm_client()
    logger.info("LLM client initialised")

    tools_client = get_tools_client()
    try:
        await asyncio.wait_for(tools_client.connect(), timeout=10)
    except Exception:
        logger.warning("Could not connect to mcp‑tools at startup; will retry later")

    checkpointer = _build_checkpointer(settings)
    graph = build_graph(checkpointer)
    app.state.graph = graph
    app.state.settings = settings
    logger.info("Agent workflow graph compiled")

    try:
        yield
    finally:
        await close_llm_client()
        await close_tools_client()
        if checkpointer:
            await _close_checkpointer(checkpointer)
        logger.info("agent‑brain shut down cleanly")


app = FastAPI(
    title="agent‑brain",
    version=load_settings().service_version,
    lifespan=lifespan,
)

FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend", "dist")
if os.path.isdir(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")


@app.get("/health", tags=["system"])
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok", "service": "agent-brain"})


@app.get("/ready", tags=["system"])
async def ready(request: Request) -> JSONResponse:
    graph = getattr(request.app.state, "graph", None)
    if graph is None:
        return JSONResponse({"status": "not ready"}, status_code=503)
    return JSONResponse({"status": "ready"})


@app.post("/alert", tags=["workflow"])
@require_auth
async def create_alert(request: Request) -> JSONResponse:
    payload = await request.json()
    thread_id = str(uuid.uuid4())
    initial_state: SREState = {
        "alert": payload,
        "thread_id": thread_id,
        "status": "new",
        "started_at": _now_iso(),
        "max_retries": request.app.state.settings.max_retries,
    }

    graph = request.app.state.graph
    asyncio.create_task(_run_workflow(graph, initial_state, thread_id))
    return JSONResponse({"thread_id": thread_id, "status": "started"}, status_code=202)


@app.post("/decision/{thread_id}", tags=["workflow"])
@require_auth
async def human_decision(thread_id: str, request: Request) -> JSONResponse:
    graph = request.app.state.graph
    decision_data = await request.json()
    command = {"command": "continue", "update": {"human_decision": decision_data.get("decision")}}
    try:
        final_state = await graph.ainvoke(
            command, config={"configurable": {"thread_id": thread_id}}
        )
        return JSONResponse({"status": "resumed", "final_state": final_state.get("status")})
    except Exception as exc:
        logger.exception("Failed to resume workflow %s", thread_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/state/{thread_id}", tags=["workflow"])
@require_auth
async def get_state(thread_id: str, request: Request) -> JSONResponse:
    graph = request.app.state.graph
    try:
        state = await graph.aget_state(config={"configurable": {"thread_id": thread_id}})
        if state is None:
            raise HTTPException(status_code=404, detail="Workflow not found")
        public_state = {k: v for k, v in state.items() if not k.startswith("_")}
        return JSONResponse({"thread_id": thread_id, "state": public_state})
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Failed to read state for %s", thread_id)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.websocket("/ws/{thread_id}")
async def websocket_endpoint(websocket: Any, thread_id: str) -> None:
    await manager.handle_socket(websocket, thread_id)


async def _run_workflow(graph: Any, initial_state: SREState, thread_id: str) -> None:
    try:
        final = await graph.ainvoke(
            initial_state, config={"configurable": {"thread_id": thread_id}}
        )
        logger.info("Workflow %s completed with status %s", thread_id, final.get("status"))
        await manager.publish_state(final)
    except Exception as exc:
        logger.exception("Workflow %s failed", thread_id)
        await manager.publish_event(thread_id, "error", {"message": str(exc)})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=int(os.getenv("PORT", "8000")), reload=False)
