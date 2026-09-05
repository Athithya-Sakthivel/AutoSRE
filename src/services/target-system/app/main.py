"""FastAPI application entrypoint for target-system."""

from __future__ import annotations

import asyncio
import logging
import random
from contextlib import asynccontextmanager
from typing import Any

from fastapi import APIRouter, FastAPI, HTTPException, Query, status
from opentelemetry import trace

from .chaos import chaos_state
from .config import config
from .telemetry import init_telemetry

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize telemetry *before* the app starts. If it fails, the process
    # will exit because we are not in "development" (fail-fast).
    init_telemetry(service_name=config.app_name, service_version=config.app_version)
    logger.info("target-system started")
    yield
    logger.info("target-system stopping")


app = FastAPI(
    title="target-system",
    version=config.app_version,
    lifespan=lifespan,
)

api_router = APIRouter(prefix="/api", tags=["business"])
chaos_router = APIRouter(prefix="/chaos", tags=["chaos"])


@app.get("/health", tags=["system"])
async def health() -> dict[str, Any]:
    snapshot = chaos_state.snapshot()
    return {
        "status": "ok",
        "service": config.app_name,
        "version": config.app_version,
        "telemetry_enabled": config.telemetry_enabled,
        "chaos": {
            "active": snapshot["active"],
            **snapshot,
        },
    }


@app.get("/ready", tags=["system"])
async def ready() -> dict[str, str]:
    return {"status": "ready"}


@api_router.post("/process", status_code=status.HTTP_200_OK)
async def process() -> dict[str, Any]:
    with trace.get_tracer(__name__).start_as_current_span("api.process"):
        await _apply_latency(chaos_state.maybe_latency_ms())
        _maybe_raise_random_error(chaos_state.maybe_error_rate())
        _maybe_raise_flagged_failure()
        return {
            "status": "ok",
            "message": "transaction processed successfully",
        }


@api_router.get("/query", status_code=status.HTTP_200_OK)
async def query() -> dict[str, Any]:
    with trace.get_tracer(__name__).start_as_current_span("api.query"):
        await _apply_latency(chaos_state.maybe_latency_ms())
        return {
            "status": "ok",
            "items": [
                {"id": 1, "name": "sample"},
                {"id": 2, "name": "sample-2"},
            ],
        }


@chaos_router.post("/oom", status_code=status.HTTP_200_OK)
async def enable_oom() -> dict[str, Any]:
    chaos_state.enable_oom(True)
    return {"status": "ok", "chaos": chaos_state.snapshot()}


@chaos_router.post("/db-deadlock", status_code=status.HTTP_200_OK)
async def enable_db_deadlock() -> dict[str, Any]:
    chaos_state.enable_db_deadlock(True)
    return {"status": "ok", "chaos": chaos_state.snapshot()}


@chaos_router.post("/latency", status_code=status.HTTP_200_OK)
async def set_latency(
    ms: int = Query(
        default=5000, ge=0, le=300000, description="Artificial latency in milliseconds"
    ),
) -> dict[str, Any]:
    chaos_state.set_latency_ms(ms)
    return {"status": "ok", "chaos": chaos_state.snapshot()}


@chaos_router.post("/cpu-spike", status_code=status.HTTP_200_OK)
async def cpu_spike(
    seconds: int = Query(
        default=30, ge=1, le=3600, description="Duration of the CPU spike in seconds"
    ),
) -> dict[str, Any]:
    snapshot = chaos_state.start_cpu_spike(seconds)
    return {"status": "ok", "chaos": snapshot}


@chaos_router.post("/error-rate", status_code=status.HTTP_200_OK)
async def set_error_rate(
    rate: float = Query(default=0.8, ge=0.0, le=1.0, description="Probability of injected failure"),
) -> dict[str, Any]:
    chaos_state.set_error_rate(rate)
    return {"status": "ok", "chaos": chaos_state.snapshot()}


@chaos_router.post("/reset", status_code=status.HTTP_200_OK)
async def reset_chaos() -> dict[str, Any]:
    chaos_state.reset()
    return {"status": "ok", "chaos": chaos_state.snapshot()}


@chaos_router.get("/state", status_code=status.HTTP_200_OK)
async def get_state() -> dict[str, Any]:
    return {"status": "ok", "chaos": chaos_state.snapshot()}


app.include_router(api_router)
app.include_router(chaos_router)


async def _apply_latency(latency_ms: int) -> None:
    if latency_ms > 0:
        await asyncio.sleep(latency_ms / 1000.0)


def _maybe_raise_random_error(rate: float) -> None:
    if rate > 0.0 and random.random() < rate:
        raise HTTPException(status_code=500, detail="Chaos: random error injected")


def _maybe_raise_flagged_failure() -> None:
    if chaos_state.is_oom():
        raise HTTPException(status_code=500, detail="Chaos: simulated OOM")
    if chaos_state.is_db_deadlock():
        raise HTTPException(status_code=500, detail="Chaos: simulated database deadlock")


__all__ = ["app", "create_app"]


def create_app() -> FastAPI:
    """Factory for tests and process managers."""
    return app
