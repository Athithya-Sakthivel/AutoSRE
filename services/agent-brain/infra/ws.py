"""WebSocket manager for live state broadcasting (production‑ready)."""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from collections.abc import Mapping
from typing import Any

from fastapi import WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)

STATE_KEYS = frozenset(
    {
        "alert_id",
        "thread_id",
        "service_name",
        "resource_id",
        "severity",
        "status",
        "rate_limit_count",
        "rate_limit_threshold",
        "rate_limited",
        "retry_count",
        "max_retries",
        "investigation_logs",
        "trace_records",
        "log_records",
        "suspected_file_path",
        "suspected_line_number",
        "suspected_commit",
        "code_snippet",
        "proposed_action",
        "fix_confidence",
        "approval_status",
        "human_decision",
        "execution_result",
        "verification_result",
        "error_resolved",
        "last_error_message",
        "notes",
    }
)


class WebSocketManager:
    def __init__(self) -> None:
        self._connections: dict[str, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def connect(self, thread_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._connections[thread_id].add(websocket)

    async def disconnect(self, thread_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            sockets = self._connections.get(thread_id)
            if sockets is not None:
                sockets.discard(websocket)
                if not sockets:
                    self._connections.pop(thread_id, None)

    async def broadcast(self, thread_id: str, message: Mapping[str, Any]) -> None:
        sockets = list(self._connections.get(thread_id, set()))
        if not sockets:
            return
        dead: list[WebSocket] = []
        for socket in sockets:
            try:
                await socket.send_json(dict(message))
            except Exception:
                dead.append(socket)
        if dead:
            async with self._lock:
                current = self._connections.get(thread_id)
                if current is not None:
                    for socket in dead:
                        current.discard(socket)
                    if not current:
                        self._connections.pop(thread_id, None)

    async def publish_state(self, state: Mapping[str, Any]) -> None:
        thread_id = str(state.get("thread_id") or "")
        if not thread_id:
            return
        public_state = {key: state[key] for key in STATE_KEYS if key in state}
        await self.broadcast(
            thread_id, {"type": "state", "thread_id": thread_id, "state": public_state}
        )

    async def publish_event(
        self, thread_id: str, event_type: str, payload: Mapping[str, Any] | None = None
    ) -> None:
        message: dict[str, Any] = {"type": event_type, "thread_id": thread_id}
        if payload is not None:
            message["payload"] = dict(payload)
        await self.broadcast(thread_id, message)

    async def handle_socket(self, websocket: WebSocket, thread_id: str) -> None:
        await self.connect(thread_id, websocket)
        try:
            await self.publish_event(thread_id, "connected", {"thread_id": thread_id})
            while True:
                await websocket.receive_text()  # keep alive; decisions come via REST
        except WebSocketDisconnect:
            logger.debug("WebSocket disconnected for thread_id=%s", thread_id)
        finally:
            await self.disconnect(thread_id, websocket)


manager = WebSocketManager()
