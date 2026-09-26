"""Validation and asynchronous processing for Slack approval interactions."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from typing import Any

from slack_sdk.signature import SignatureVerifier

from autosre.config import SlackConfig
from autosre.runner_protocol import RunnerProtocol
from autosre.slack.client import SlackClient

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ApprovalDecision:
    """Validated identity and message context for one approval action."""

    incident_id: str
    approved: bool
    user_id: str
    channel_id: str
    message_ts: str


class SlackHandler:
    """Verify Slack requests and dispatch validated approval decisions."""

    def __init__(
        self,
        config: SlackConfig,
        runner: RunnerProtocol,
        client: SlackClient,
        approver_user_ids: Collection[str] | None = None,
    ) -> None:
        """Initialize the transport-independent Slack interaction handler."""
        self._runner = runner
        self._client = client
        self._verifier: SignatureVerifier | None = None
        self._tasks: set[asyncio.Task[None]] = set()
        self._inflight_incidents: set[str] = set()
        self._approver_user_ids = frozenset(approver_user_ids or ())

        if config.signing_secret is not None:
            self._verifier = SignatureVerifier(
                signing_secret=config.signing_secret.get_secret_value()
            )

    def verify_request(
        self,
        body: str | bytes,
        headers: Mapping[str, str],
    ) -> bool:
        """Verify an HTTP request using Slack's signing secret."""
        verifier = self._verifier

        if verifier is None:
            return False

        try:
            return bool(verifier.is_valid_request(body, headers))
        except TypeError, ValueError:
            logger.warning("Slack request signature validation failed due to invalid headers")
            return False

    def schedule_interactivity(
        self,
        payload: Mapping[str, Any],
    ) -> bool:
        """Validate and schedule a decision without blocking Slack."""
        decision = self._parse_approval_decision(payload)

        if decision is None:
            return False

        if decision.incident_id in self._inflight_incidents:
            logger.info(
                "Ignoring duplicate in-flight Slack decision for incident %s",
                decision.incident_id,
            )
            return True

        self._inflight_incidents.add(decision.incident_id)

        try:
            task = asyncio.create_task(
                self._process_decision(decision),
                name=(f"autosre-slack-approval-{decision.incident_id}"),
            )
        except Exception:
            self._inflight_incidents.discard(decision.incident_id)
            raise

        self._tasks.add(task)

        task.add_done_callback(self._tasks.discard)
        task.add_done_callback(lambda _task: self._inflight_incidents.discard(decision.incident_id))

        return True

    async def close(self, timeout: float = 15.0) -> None:
        """Wait for in-flight approval decisions, then cancel pending work."""
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")

        tasks = tuple(self._tasks)
        if not tasks:
            return

        done, pending = await asyncio.wait(
            tasks,
            timeout=timeout,
        )

        for task in pending:
            task.cancel()

        if pending:
            await asyncio.gather(
                *pending,
                return_exceptions=True,
            )

        if done:
            await asyncio.gather(
                *done,
                return_exceptions=True,
            )

        self._inflight_incidents.clear()

    def _parse_approval_decision(
        self,
        payload: Mapping[str, Any],
    ) -> ApprovalDecision | None:
        if payload.get("type") != "block_actions":
            return None

        actions = payload.get("actions")

        if not isinstance(actions, list) or not actions:
            logger.warning("Ignoring Slack interaction without actions")
            return None

        action = actions[0]

        if not isinstance(action, Mapping):
            logger.warning("Ignoring malformed Slack action payload")
            return None

        action_id = action.get("action_id")
        incident_value = action.get("value")

        if not isinstance(action_id, str) or not isinstance(
            incident_value,
            str,
        ):
            logger.warning("Ignoring Slack action with missing action_id/value")
            return None

        if action_id.startswith("approve_"):
            approved = True
            prefix = "approve_"
        elif action_id.startswith("reject_"):
            approved = False
            prefix = "reject_"
        else:
            logger.warning(
                "Ignoring unsupported Slack action_id %r",
                action_id,
            )
            return None

        incident_id = action_id[len(prefix) :]

        if not incident_id or incident_id != incident_value:
            logger.warning("Ignoring Slack action with inconsistent incident identifiers")
            return None

        user = payload.get("user")

        if not isinstance(user, Mapping):
            logger.warning("Ignoring Slack action without user identity")
            return None

        user_id = user.get("id")

        if not isinstance(user_id, str) or not user_id:
            logger.warning("Ignoring Slack action without user ID")
            return None

        if self._approver_user_ids and user_id not in self._approver_user_ids:
            logger.warning(
                "Rejecting unauthorized Slack approver %s",
                user_id,
            )
            return None

        channel_id = self._extract_channel_id(payload)
        message_ts = self._extract_message_ts(payload)

        if channel_id is None or message_ts is None:
            logger.warning("Ignoring Slack action without message channel/timestamp")
            return None

        return ApprovalDecision(
            incident_id=incident_id,
            approved=approved,
            user_id=user_id,
            channel_id=channel_id,
            message_ts=message_ts,
        )

    @staticmethod
    def _extract_channel_id(
        payload: Mapping[str, Any],
    ) -> str | None:
        channel = payload.get("channel")

        if isinstance(channel, Mapping):
            channel_id = channel.get("id")
            if isinstance(channel_id, str) and channel_id:
                return channel_id

        container = payload.get("container")

        if isinstance(container, Mapping):
            channel_id = container.get("channel_id")
            if isinstance(channel_id, str) and channel_id:
                return channel_id

        return None

    @staticmethod
    def _extract_message_ts(
        payload: Mapping[str, Any],
    ) -> str | None:
        message = payload.get("message")

        if isinstance(message, Mapping):
            message_ts = message.get("ts")
            if isinstance(message_ts, str) and message_ts:
                return message_ts

        container = payload.get("container")

        if isinstance(container, Mapping):
            message_ts = container.get("message_ts")
            if isinstance(message_ts, str) and message_ts:
                return message_ts

        return None

    async def _process_decision(
        self,
        decision: ApprovalDecision,
    ) -> None:
        status = "APPROVED" if decision.approved else "REJECTED"
        detail = f"Decision recorded by Slack user {decision.user_id}."

        try:
            success = await self._runner.approve_incident(
                incident_id=decision.incident_id,
                approved=decision.approved,
                comment=(f"{status.title()} by Slack user {decision.user_id}"),
            )

        except asyncio.CancelledError:
            raise

        except Exception:
            logger.exception(
                "Unexpected error while recording Slack decision for incident %s",
                decision.incident_id,
            )

            await self._client.update_approval_message(
                channel=decision.channel_id,
                ts=decision.message_ts,
                status="DECISION PROCESSING FAILED",
                detail=(
                    "The decision was not confirmed by AutoSRE. "
                    "Check the incident state before taking "
                    "further action."
                ),
            )
            return

        if success:
            await self._client.update_approval_message(
                channel=decision.channel_id,
                ts=decision.message_ts,
                status=status,
                detail=detail,
            )

            logger.info(
                "Recorded Slack approval decision for incident %s by %s",
                decision.incident_id,
                decision.user_id,
            )
            return

        await self._client.update_approval_message(
            channel=decision.channel_id,
            ts=decision.message_ts,
            status="DECISION NOT ACCEPTED",
            detail=(
                "AutoSRE did not accept this decision. "
                "The incident may already have been decided "
                "or may no longer exist."
            ),
        )

        logger.warning(
            "Runner rejected Slack decision for incident %s by %s",
            decision.incident_id,
            decision.user_id,
        )
