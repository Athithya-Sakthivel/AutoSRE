"""FastMCP client for the mcp‑tools server with Bearer auth."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any, Self

from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport
from infra.config import load_settings

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 60.0


class MCPToolsError(RuntimeError):
    pass


@dataclass(slots=True)
class MCPToolsClient:
    """Long‑lived client for the mcp‑tools server with API key auth."""

    url: str
    api_key: str | None = None
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS

    _client: Client | None = field(init=False, default=None)
    _connected: bool = field(init=False, default=False)
    _connect_lock: asyncio.Lock = field(init=False, default_factory=asyncio.Lock)

    async def __aenter__(self) -> Self:
        await self.connect()
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: object,
    ) -> None:
        await self.close()

    async def connect(self) -> None:
        if self._connected:
            return
        async with self._connect_lock:
            if self._connected:
                return
            transport = StreamableHttpTransport(self.url, auth=self.api_key)
            self._client = Client(transport)
            await self._client.__aenter__()
            self._connected = True
            logger.info("Connected to mcp‑tools at %s", self.url)

    async def close(self) -> None:
        if not self._connected or self._client is None:
            return
        async with self._connect_lock:
            if not self._connected or self._client is None:
                return
            await self._client.__aexit__(None, None, None)
            self._client = None
            self._connected = False
            logger.info("Disconnected from mcp‑tools")

    async def _ensure_connected(self) -> None:
        if not self._connected:
            await self.connect()

    def _normalize_result(self, result: Any) -> Any:
        data = getattr(result, "data", None)
        if data is not None:
            return data
        structured = getattr(result, "structured_content", None)
        if structured is not None:
            return structured
        content = getattr(result, "content", None)
        if content is not None:
            if isinstance(content, list):
                parts = []
                for item in content:
                    if isinstance(item, str):
                        parts.append(item)
                    elif isinstance(item, Mapping):
                        text = item.get("text")
                        if isinstance(text, str):
                            parts.append(text)
                if len(parts) == 1:
                    return parts[0]
                return "".join(parts)
            return content
        return result

    async def call_tool(self, tool_name: str, arguments: Mapping[str, Any] | None = None) -> Any:
        await self._ensure_connected()
        if self._client is None:
            raise MCPToolsError("Client is not connected")
        payload = dict(arguments or {})
        result = await self._client.call_tool(tool_name, payload)
        return self._normalize_result(result)

    async def query_traces(self, *, service_name: str, time_range_minutes: int) -> Any:
        return await self.call_tool(
            "query_traces",
            {"service_name": service_name, "time_range_minutes": time_range_minutes},
        )

    async def query_logs(self, *, service_name: str, time_range_minutes: int) -> Any:
        return await self.call_tool(
            "query_logs",
            {"service_name": service_name, "time_range_minutes": time_range_minutes},
        )

    async def git_blame(self, *, file_path: str, line_number: int) -> Any:
        return await self.call_tool(
            "git_blame",
            {"file_path": file_path, "line_number": line_number},
        )

    async def get_code_snippet(self, *, file_path: str, line_start: int, line_end: int) -> Any:
        return await self.call_tool(
            "get_code_snippet",
            {"file_path": file_path, "line_start": line_start, "line_end": line_end},
        )

    async def create_pr(self, *, repo: str, title: str, description: str, diff: str) -> Any:
        return await self.call_tool(
            "create_pr",
            {"repo": repo, "title": title, "description": description, "diff": diff},
        )

    async def restart_aca_revision(self, *, service_name: str) -> Any:
        return await self.call_tool(
            "restart_aca_revision",
            {"service_name": service_name},
        )


@lru_cache(maxsize=1)
def get_tools_client() -> MCPToolsClient:
    settings = load_settings()
    return MCPToolsClient(url=settings.mcp_tools_url, api_key=settings.mcp_api_key or None)


async def close_tools_client() -> None:
    client = get_tools_client()
    await client.close()
    get_tools_client.cache_clear()


async def async_query_traces(service_name: str, time_range_minutes: int) -> Any:
    return await get_tools_client().query_traces(
        service_name=service_name,
        time_range_minutes=time_range_minutes,
    )


async def async_query_logs(service_name: str, time_range_minutes: int) -> Any:
    return await get_tools_client().query_logs(
        service_name=service_name,
        time_range_minutes=time_range_minutes,
    )


async def async_git_blame(file_path: str, line_number: int) -> Any:
    return await get_tools_client().git_blame(file_path=file_path, line_number=line_number)


async def async_get_code_snippet(file_path: str, line_start: int, line_end: int) -> Any:
    return await get_tools_client().get_code_snippet(
        file_path=file_path,
        line_start=line_start,
        line_end=line_end,
    )


async def async_create_pr(repo: str, title: str, description: str, diff: str) -> Any:
    return await get_tools_client().create_pr(
        repo=repo,
        title=title,
        description=description,
        diff=diff,
    )


async def async_restart_aca_revision(service_name: str) -> Any:
    return await get_tools_client().restart_aca_revision(service_name=service_name)


__all__ = [
    "MCPToolsClient",
    "MCPToolsError",
    "async_create_pr",
    "async_get_code_snippet",
    "async_git_blame",
    "async_query_logs",
    "async_query_traces",
    "async_restart_aca_revision",
    "close_tools_client",
    "get_tools_client",
]
