"""Runtime state – token cache (thread‑safe), HTTP client, validated git root."""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from .config import ConfigError, Settings

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class Runtime:
    settings: Settings
    http: httpx.AsyncClient
    credential: Any
    git_repo_root: Path
    _token_cache: dict[str, tuple[str, float]] = field(default_factory=dict)
    _token_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def get_token(self, scope: str) -> str:
        """Return a valid token, reusing cached entries with 60s margin."""
        now = time.time()
        async with self._token_lock:
            cached = self._token_cache.get(scope)
            if cached:
                token_str, expires = cached
                if expires - now > 60:
                    return token_str

        # Token missing or near expiry – fetch new one (blocking call offloaded)
        token_obj = await asyncio.to_thread(self.credential.get_token, scope)
        expires = token_obj.expires_on
        token_str = str(token_obj.token)
        async with self._token_lock:
            self._token_cache[scope] = (token_str, expires)
        return token_str


_runtime: Runtime | None = None


def set_runtime(runtime: Runtime) -> None:
    global _runtime
    if _runtime is not None:
        raise ConfigError("Runtime already initialised")
    _runtime = runtime


def get_runtime() -> Runtime:
    if _runtime is None:
        raise ConfigError("Runtime not initialised – lifespan did not run")
    return _runtime


def clear_runtime() -> None:
    global _runtime
    _runtime = None
