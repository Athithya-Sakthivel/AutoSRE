"""Async Slack Web API client for human-in-the-loop approvals."""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from typing import Any

from slack_sdk.errors import SlackApiError
from slack_sdk.http_retry.builtin_async_handlers import (
    AsyncConnectionErrorRetryHandler,
    AsyncRateLimitErrorRetryHandler,
    AsyncServerErrorRetryHandler,
)
from slack_sdk.web.async_client import AsyncWebClient

from autosre.config import SlackConfig

logger = logging.getLogger(__name__)

_MAX_BLOCK_TEXT = 3000
_MAX_FIELD_TEXT = 2000
_MAX_ACTION_TEXT = 900
_MAX_RATIONALE_TEXT = 2500

_SENSITIVE_KEY_FRAGMENTS = (
    "password",
    "passwd",
    "secret",
    "token",
    "api_key",
    "apikey",
    "authorization",
    "credential",
)


def _truncate(value: str, limit: int) -> str:
    """Truncate text without exceeding the requested limit."""
    if len(value) <= limit:
        return value
    if limit <= 3:
        return value[:limit]
    return f"{value[: limit - 3]}..."


def _escape_mrkdwn(value: str) -> str:
    """Escape characters that have special meaning in Slack mrkdwn."""
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _redact_value(key: str, value: Any) -> Any:
    """Redact values under keys that commonly contain credentials."""
    key_lower = key.lower()

    if any(fragment in key_lower for fragment in _SENSITIVE_KEY_FRAGMENTS):
        return "[REDACTED]"

    if isinstance(value, Mapping):
        return {str(k): _redact_value(str(k), v) for k, v in value.items()}

    if isinstance(value, list):
        return [_redact_value(key, item) for item in value]

    return value


def _format_tool_args(tool_args: Mapping[str, Any]) -> str:
    """Serialize tool arguments compactly and redact common secret fields."""
    redacted = {str(key): _redact_value(str(key), value) for key, value in tool_args.items()}

    try:
        encoded = json.dumps(
            redacted,
            sort_keys=True,
            separators=(",", ":"),
            default=repr,
        )
    except TypeError, ValueError:
        encoded = repr(redacted)

    return _truncate(encoded, _MAX_ACTION_TEXT)


class SlackClient:
    """Async wrapper around Slack's Web API used by the approval workflow."""

    def __init__(self, config: SlackConfig) -> None:
        """Initialize the client from Slack configuration."""
        self._enabled = bool(config.is_enabled)
        self._channel = config.approval_channel
        self._client: AsyncWebClient | None = None

        if not self._enabled:
            logger.info("Slack integration disabled")
            return

        if config.bot_token is None:
            raise ValueError("Slack is enabled but bot_token is not configured")

        if not self._channel:
            raise ValueError("Slack is enabled but approval_channel is not configured")

        self._client = AsyncWebClient(
            token=config.bot_token.get_secret_value(),
            retry_handlers=[
                AsyncConnectionErrorRetryHandler(max_retry_count=1),
                AsyncRateLimitErrorRetryHandler(max_retry_count=2),
                AsyncServerErrorRetryHandler(max_retry_count=2),
            ],
        )

        logger.info(
            "Slack Web API client initialized for approval channel %s",
            self._channel,
        )

    @property
    def enabled(self) -> bool:
        """Return whether the Slack client is configured and open."""
        return self._enabled and self._client is not None

    @property
    def web_client(self) -> AsyncWebClient | None:
        """Return the underlying async Web API client."""
        return self._client

    async def post_approval_request(
        self,
        incident_id: str,
        alert_name: str,
        service: str,
        namespace: str,
        tool_name: str,
        tool_args: Mapping[str, Any],
        risk_tier: int,
        rationale: str,
    ) -> str | None:
        """Post a Block Kit approval request and return its message timestamp."""
        client = self._client
        channel = self._channel

        if not self.enabled or client is None or channel is None:
            logger.warning("Cannot post approval request because Slack is not enabled")
            return None

        safe_alert = _truncate(
            _escape_mrkdwn(alert_name),
            _MAX_FIELD_TEXT,
        )
        safe_service = _truncate(
            _escape_mrkdwn(service),
            700,
        )
        safe_namespace = _truncate(
            _escape_mrkdwn(namespace),
            700,
        )
        safe_tool = _truncate(
            _escape_mrkdwn(tool_name),
            500,
        )
        safe_rationale = _truncate(
            _escape_mrkdwn(rationale),
            _MAX_RATIONALE_TEXT,
        )
        safe_args = _escape_mrkdwn(_format_tool_args(tool_args))
        short_incident_id = _truncate(incident_id, 40)

        blocks: list[dict[str, Any]] = [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": _truncate(
                        f"Tier {risk_tier} approval required",
                        150,
                    ),
                },
            },
            {
                "type": "section",
                "fields": [
                    {
                        "type": "mrkdwn",
                        "text": _truncate(
                            f"*Alert:*\n{safe_alert}",
                            _MAX_FIELD_TEXT,
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": _truncate(
                            f"*Service:*\n{safe_service}/{safe_namespace}",
                            _MAX_FIELD_TEXT,
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": _truncate(
                            f"*Action:*\n`{safe_tool}({safe_args})`",
                            _MAX_FIELD_TEXT,
                        ),
                    },
                    {
                        "type": "mrkdwn",
                        "text": _truncate(
                            f"*Risk tier:*\n{risk_tier}",
                            _MAX_FIELD_TEXT,
                        ),
                    },
                ],
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": _truncate(
                        f"*Rationale:*\n{safe_rationale}",
                        _MAX_BLOCK_TEXT,
                    ),
                },
            },
            {"type": "divider"},
            {
                "type": "actions",
                "block_id": f"approval_actions_{incident_id}",
                "elements": [
                    {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Approve",
                        },
                        "style": "primary",
                        "action_id": f"approve_{incident_id}",
                        "value": incident_id,
                        "confirm": {
                            "title": {
                                "type": "plain_text",
                                "text": "Approve action",
                            },
                            "text": {
                                "type": "mrkdwn",
                                "text": (
                                    "This records your approval and allows "
                                    "the pending remediation to continue."
                                ),
                            },
                            "confirm": {
                                "type": "plain_text",
                                "text": "Approve",
                            },
                            "deny": {
                                "type": "plain_text",
                                "text": "Cancel",
                            },
                        },
                    },
                    {
                        "type": "button",
                        "text": {
                            "type": "plain_text",
                            "text": "Reject",
                        },
                        "style": "danger",
                        "action_id": f"reject_{incident_id}",
                        "value": incident_id,
                        "confirm": {
                            "title": {
                                "type": "plain_text",
                                "text": "Reject action",
                            },
                            "text": {
                                "type": "mrkdwn",
                                "text": (
                                    "This records your rejection and "
                                    "prevents the pending remediation "
                                    "from continuing."
                                ),
                            },
                            "confirm": {
                                "type": "plain_text",
                                "text": "Reject",
                            },
                            "deny": {
                                "type": "plain_text",
                                "text": "Cancel",
                            },
                        },
                    },
                ],
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": (f"Incident ID: `{_escape_mrkdwn(short_incident_id)}`"),
                    }
                ],
            },
        ]

        fallback_text = _truncate(
            f"Approval required for {alert_name} on {service}/{namespace}.",
            4000,
        )

        try:
            response = await client.chat_postMessage(
                channel=channel,
                text=fallback_text,
                blocks=blocks,
                unfurl_links=False,
                unfurl_media=False,
                mrkdwn=False,
            )

            ts = response.get("ts")
            if not isinstance(ts, str) or not ts:
                logger.error(
                    "Slack returned no message timestamp for incident %s",
                    incident_id,
                )
                return None

            logger.info(
                "Posted approval request for incident %s",
                incident_id,
            )
            return ts

        except SlackApiError as exc:
            logger.error(
                "Slack API error while posting approval request for incident %s: %s",
                incident_id,
                exc,
            )
            return None

        except Exception:
            logger.exception(
                "Unexpected error while posting approval request for incident %s",
                incident_id,
            )
            return None

    async def update_approval_message(
        self,
        channel: str,
        ts: str,
        status: str,
        detail: str,
    ) -> bool:
        """Replace an approval message's controls with terminal status."""
        client = self._client

        if not self.enabled or client is None:
            return False

        safe_status = _truncate(
            _escape_mrkdwn(status),
            150,
        )
        safe_detail = _truncate(
            _escape_mrkdwn(detail),
            _MAX_BLOCK_TEXT,
        )

        blocks: list[dict[str, Any]] = [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*{safe_status}*",
                },
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": safe_detail,
                    },
                ],
            },
        ]

        try:
            await client.chat_update(
                channel=channel,
                ts=ts,
                text=_truncate(
                    f"{status}: {detail}",
                    4000,
                ),
                blocks=blocks,
                unfurl_links=False,
                unfurl_media=False,
                mrkdwn=False,
            )

            logger.info(
                "Updated Slack approval message %s to %s",
                ts,
                status,
            )
            return True

        except SlackApiError as exc:
            logger.error(
                "Slack API error while updating approval message %s: %s",
                ts,
                exc,
            )
            return False

        except Exception:
            logger.exception(
                "Unexpected error while updating approval message %s",
                ts,
            )
            return False

    async def close(self) -> None:
        """Close the underlying async HTTP client."""
        client = self._client
        self._client = None

        if client is None:
            return

        session = client.session
        if session is None:
            return

        try:
            await session.close()
        except Exception:
            logger.exception("Failed to close Slack Web API client cleanly")
