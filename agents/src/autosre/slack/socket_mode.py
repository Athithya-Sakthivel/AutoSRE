"""Async Slack Socket Mode transport."""

from __future__ import annotations

import logging

from slack_sdk.socket_mode.aiohttp import SocketModeClient
from slack_sdk.socket_mode.async_client import AsyncBaseSocketModeClient
from slack_sdk.socket_mode.request import SocketModeRequest
from slack_sdk.socket_mode.response import SocketModeResponse

from autosre.config import SlackConfig
from autosre.slack.client import SlackClient
from autosre.slack.handler import SlackHandler

logger = logging.getLogger(__name__)


class SlackSocketMode:
    """Maintain a Slack WebSocket connection and route interactions."""

    def __init__(
        self,
        config: SlackConfig,
        handler: SlackHandler,
        client: SlackClient,
    ) -> None:
        """Initialize the Socket Mode transport."""
        self._handler = handler
        self._client = client
        self._socket: SocketModeClient | None = None

        self._app_token = (
            config.app_token.get_secret_value() if config.app_token is not None else None
        )

    @property
    def running(self) -> bool:
        """Return whether the Socket Mode connection is open."""
        return self._socket is not None and not self._socket.closed

    async def start(self) -> None:
        """Connect to Slack using the app-level token."""
        if self.running:
            return

        if self._app_token is None:
            raise ValueError("Socket Mode requires a Slack app_token")

        web_client = self._client.web_client

        if web_client is None:
            raise RuntimeError("Slack Web API client is not available")

        socket = SocketModeClient(
            app_token=self._app_token,
            web_client=web_client,
            auto_reconnect_enabled=True,
        )

        socket.socket_mode_request_listeners.append(self._handle_request)
        self._socket = socket

        try:
            await socket.connect()
        except Exception:
            self._socket = None

            try:
                await socket.close()
            except Exception:
                logger.exception("Failed to clean up a failed Slack Socket Mode startup")

            raise

        logger.info("Slack Socket Mode connection established")

    async def stop(self) -> None:
        """Close the Socket Mode connection."""
        socket = self._socket
        self._socket = None

        if socket is None:
            return

        try:
            await socket.close()
        except Exception:
            logger.exception("Failed to close Slack Socket Mode connection cleanly")

    async def _handle_request(
        self,
        client: AsyncBaseSocketModeClient,
        request: SocketModeRequest,
    ) -> None:
        """Acknowledge envelopes immediately and dispatch interactions."""
        try:
            await client.send_socket_mode_response(
                SocketModeResponse(
                    envelope_id=request.envelope_id,
                )
            )
        except Exception:
            logger.exception("Failed to acknowledge Slack Socket Mode envelope")
            return

        if request.type != "interactive":
            return

        payload = request.payload

        if payload.get("type") != "block_actions":
            return

        try:
            scheduled = self._handler.schedule_interactivity(payload)

            if not scheduled:
                logger.warning("Slack block action was acknowledged but not scheduled")

        except Exception:
            logger.exception("Failed to schedule Slack block action")
