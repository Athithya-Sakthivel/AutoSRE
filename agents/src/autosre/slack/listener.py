"""Background polling for incidents that require human approval."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping, Sequence
from typing import Any

from autosre.runner_protocol import RunnerProtocol
from autosre.slack.client import SlackClient

logger = logging.getLogger(__name__)

POLL_INTERVAL_SECONDS = 5.0


def _as_mapping(value: Any) -> Mapping[str, Any] | None:
    if isinstance(value, Mapping):
        return value
    return None


def _as_nonempty_string(
    value: Any,
    default: str,
) -> str:
    return value if isinstance(value, str) and value else default


def _as_int(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default

    if isinstance(value, int):
        return value

    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return default

    return default


class ApprovalListener:
    """Poll runner state and post pending approvals to Slack."""

    def __init__(
        self,
        runner: RunnerProtocol,
        slack_client: SlackClient,
        poll_interval: float = POLL_INTERVAL_SECONDS,
    ) -> None:
        if poll_interval <= 0:
            raise ValueError("poll_interval must be greater than zero")

        self._runner = runner
        self._slack = slack_client
        self._poll_interval = poll_interval
        self._stop_event = asyncio.Event()
        self._task: asyncio.Task[None] | None = None

        # Process-local only. Use a persistent atomic claim
        # for multi-replica HA.
        self._notified: set[str] = set()

    @property
    def running(self) -> bool:
        """Return whether the polling task is running."""
        return self._task is not None and not self._task.done()

    async def start(self) -> None:
        """Start the background polling task."""
        if not self._slack.enabled:
            logger.info("Slack disabled; approval listener not started")
            return

        if self.running:
            return

        self._stop_event.clear()

        self._task = asyncio.create_task(
            self._poll_loop(),
            name="autosre-slack-approval-listener",
        )

        logger.info(
            "Slack approval listener started with %.1fs polling interval",
            self._poll_interval,
        )

    async def stop(self, timeout: float = 10.0) -> None:
        """Stop the polling task and wait briefly for shutdown."""
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")

        task = self._task

        if task is None:
            return

        self._stop_event.set()

        try:
            await asyncio.wait_for(
                asyncio.shield(task),
                timeout=timeout,
            )

        except TimeoutError:
            logger.warning("Slack approval listener exceeded shutdown timeout; cancelling")
            task.cancel()
            await asyncio.gather(
                task,
                return_exceptions=True,
            )

        except asyncio.CancelledError:
            await asyncio.gather(
                task,
                return_exceptions=True,
            )

        finally:
            self._task = None
            logger.info("Slack approval listener stopped")

    async def _poll_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                await self._check_pending_approvals()

            except asyncio.CancelledError:
                raise

            except Exception:
                logger.exception("Error during Slack approval polling cycle")

            try:
                await asyncio.wait_for(
                    self._stop_event.wait(),
                    timeout=self._poll_interval,
                )

            except TimeoutError:
                continue

    async def _check_pending_approvals(self) -> None:
        incidents = await self._runner.list_incidents(limit=100)
        posted = 0

        for incident_id, state in incidents:
            if not isinstance(incident_id, str) or not incident_id:
                continue

            values = self._extract_values(state)

            if values is None:
                continue

            if values.get("requires_human_approval") is not True:
                continue

            if values.get("approval_granted") is not None:
                continue

            if incident_id in self._notified:
                continue

            if await self._post_approval(
                incident_id,
                values,
            ):
                self._notified.add(incident_id)
                posted += 1

        if posted:
            logger.info(
                "Posted %d new Slack approval request(s)",
                posted,
            )

    @staticmethod
    def _extract_values(
        state: Any,
    ) -> dict[str, Any] | None:
        if state is None:
            return None

        values = getattr(state, "values", state)

        if not isinstance(values, Mapping):
            return None

        return dict(values)

    async def _post_approval(
        self,
        incident_id: str,
        values: Mapping[str, Any],
    ) -> bool:
        metadata = _as_mapping(values.get("incident_metadata")) or {}

        proposed_actions = values.get("proposed_actions")

        if not isinstance(
            proposed_actions,
            Sequence,
        ) or isinstance(
            proposed_actions,
            (str, bytes, bytearray),
        ):
            logger.warning(
                "Incident %s has no usable proposed actions",
                incident_id,
            )
            return False

        if not proposed_actions:
            logger.warning(
                "Incident %s has an empty proposed action list",
                incident_id,
            )
            return False

        last_action = _as_mapping(proposed_actions[-1])

        if last_action is None:
            logger.warning(
                "Incident %s has a malformed proposed action",
                incident_id,
            )
            return False

        tool_args_value = last_action.get("tool_args")

        tool_args = tool_args_value if isinstance(tool_args_value, Mapping) else {}

        risk_tier = _as_int(
            last_action.get("risk_tier"),
            2,
        )

        if risk_tier < 2:
            risk_tier = 2

        ts = await self._slack.post_approval_request(
            incident_id=incident_id,
            alert_name=_as_nonempty_string(
                metadata.get("alert_name"),
                "Unknown",
            ),
            service=_as_nonempty_string(
                metadata.get("service"),
                "unknown",
            ),
            namespace=_as_nonempty_string(
                metadata.get("namespace"),
                "unknown",
            ),
            tool_name=_as_nonempty_string(
                last_action.get("tool_name"),
                "unknown",
            ),
            tool_args=tool_args,
            risk_tier=risk_tier,
            rationale=_as_nonempty_string(
                last_action.get("rationale"),
                "No rationale provided",
            ),
        )

        return ts is not None

    def clear_notified(self) -> None:
        """Clear process-local notification state, primarily for tests."""
        self._notified.clear()
