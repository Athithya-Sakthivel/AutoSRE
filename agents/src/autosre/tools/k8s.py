"""Typed Kubernetes investigation and low-blast-radius remediation tools."""

from __future__ import annotations

import contextlib
import datetime as _dt
import re
from collections.abc import Mapping
from typing import Any

from pydantic import BaseModel, Field, field_validator

from autosre.core.state import SREContext
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)

_ALLOWED_NAMESPACES = frozenset({"rivulet", "sre"})
_DNS_LABEL_RE = re.compile(r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$")


class _NamespacedInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=63)

    @field_validator("namespace")
    @classmethod
    def validate_namespace(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("namespace must not be blank")
        if not _DNS_LABEL_RE.fullmatch(value):
            raise ValueError("namespace must be a valid RFC 1123 DNS label")
        return value


def _validate_resource_name(value: str, field_name: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError(f"{field_name} must not be blank")
    if len(value) > 253:
        raise ValueError(f"{field_name} exceeds the Kubernetes 253-character limit")

    labels = value.split(".")
    if any(len(label) > 63 or not _DNS_LABEL_RE.fullmatch(label) for label in labels):
        raise ValueError(f"{field_name} must be a valid RFC 1123 DNS subdomain name")

    return value


def _validate_reason(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("reason must not be blank")
    return value


class ListPodsInput(_NamespacedInput):
    label_selector: str = Field(
        default="",
        max_length=500,
        description="Optional Kubernetes label selector, e.g. 'app=api-gateway'",
    )
    limit: int = Field(default=50, ge=1, le=500)

    @field_validator("label_selector")
    @classmethod
    def validate_label_selector(cls, value: str) -> str:
        value = value.strip()
        if any(ord(char) < 32 for char in value):
            raise ValueError("label_selector must not contain control characters")
        return value


class PodSummary(BaseModel):
    name: str
    namespace: str
    phase: str
    ready: bool
    restarts: int
    node: str | None = None
    message: str | None = None


class ListPodsOutput(BaseModel):
    pods: list[PodSummary]
    total_returned: int


class GetPodEventsInput(_NamespacedInput):
    pod_name: str = Field(min_length=1, max_length=253)
    limit: int = Field(default=100, ge=1, le=1000)

    @field_validator("pod_name")
    @classmethod
    def validate_pod_name(cls, value: str) -> str:
        return _validate_resource_name(value, "pod_name")


class PodEvent(BaseModel):
    type: str
    reason: str
    message: str
    count: int
    last_timestamp: str


class GetPodEventsOutput(BaseModel):
    pod_name: str
    namespace: str
    events: list[PodEvent]


class GetDeploymentStatusInput(_NamespacedInput):
    name: str = Field(min_length=1, max_length=253)

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _validate_resource_name(value, "name")


class DeploymentStatus(BaseModel):
    name: str
    namespace: str
    replicas: int
    ready_replicas: int
    updated_replicas: int
    available_replicas: int
    unavailable_replicas: int
    image: str | None = None
    healthy: bool


class RestartDeploymentInput(_NamespacedInput):
    name: str = Field(min_length=1, max_length=253)
    reason: str = Field(min_length=1, max_length=500)

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        return _validate_resource_name(value, "name")

    @field_validator("reason")
    @classmethod
    def validate_restart_reason(cls, value: str) -> str:
        return _validate_reason(value)


class RestartDeploymentOutput(BaseModel):
    name: str
    namespace: str
    restarted: bool
    reason: str


def _assert_namespace(namespace: str) -> str:
    normalized = namespace.strip()

    if normalized not in _ALLOWED_NAMESPACES:
        raise ToolExecutionError(
            "k8s.namespace_check",
            ValueError(
                f"namespace '{namespace}' is not in allowed set: {sorted(_ALLOWED_NAMESPACES)}"
            ),
        )

    return normalized


def _raw_object(obj: Any) -> Mapping[str, Any]:
    raw = getattr(obj, "raw", None)
    if isinstance(raw, Mapping):
        return raw

    to_dict = getattr(obj, "to_dict", None)
    if callable(to_dict):
        value = to_dict()
        if isinstance(value, Mapping):
            return value

    try:
        value = dict(obj)
    except (TypeError, ValueError) as exc:
        raise ToolExecutionError(
            "k8s.object_normalize",
            RuntimeError("unable to normalise Kubernetes object"),
        ) from exc

    if not isinstance(value, Mapping):
        raise ToolExecutionError(
            "k8s.object_normalize",
            RuntimeError("Kubernetes object did not normalise to a mapping"),
        )

    return value


def _pod_message(status: Mapping[str, Any]) -> str | None:
    """Return the most useful waiting/termination message from pod status."""

    for container_status in status.get("containerStatuses") or []:
        if not isinstance(container_status, Mapping):
            continue

        state = container_status.get("state") or {}
        if not isinstance(state, Mapping):
            continue

        waiting = state.get("waiting")
        if isinstance(waiting, Mapping):
            reason = str(waiting.get("reason") or "")
            message = str(waiting.get("message") or "")
            value = f"{reason}: {message}".strip(": ").strip()
            if value:
                return value

        terminated = state.get("terminated")
        if isinstance(terminated, Mapping):
            reason = str(terminated.get("reason") or "")
            message = str(terminated.get("message") or "")
            value = f"{reason}: {message}".strip(": ").strip()
            if value:
                return value

    return None


def _event_timestamp_value(raw: Mapping[str, Any]) -> Any:
    series = raw.get("series") or {}
    metadata = raw.get("metadata") or {}

    if isinstance(series, Mapping) and series.get("lastObservedTime"):
        return series["lastObservedTime"]

    return (
        raw.get("eventTime")
        or raw.get("deprecatedLastTimestamp")
        or raw.get("lastTimestamp")
        or (metadata.get("creationTimestamp") if isinstance(metadata, Mapping) else None)
        or ""
    )


def _event_timestamp(raw: Mapping[str, Any]) -> str:
    value = _event_timestamp_value(raw)

    if value in (None, ""):
        return ""

    if isinstance(value, (int, float)):
        return (
            _dt.datetime.fromtimestamp(
                float(value) / 1_000_000,
                tz=_dt.UTC,
            )
            .isoformat()
            .replace("+00:00", "Z")
        )

    text = str(value)

    try:
        parsed = _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return text

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.UTC)

    return parsed.astimezone(_dt.UTC).isoformat().replace("+00:00", "Z")


async def _list_pods(
    args: ListPodsInput,
    _context: SREContext,
) -> ListPodsOutput:
    namespace = _assert_namespace(args.namespace)

    import kr8s.asyncio

    selector = args.label_selector or None
    summaries: list[PodSummary] = []

    # kr8s.asyncio.get() returns an async generator. Do not await it.
    async for pod in kr8s.asyncio.get(
        "pods",
        namespace=namespace,
        label_selector=selector,
    ):
        raw = _raw_object(pod)

        status = raw.get("status") or {}
        spec = raw.get("spec") or {}

        if not isinstance(status, Mapping):
            status = {}

        if not isinstance(spec, Mapping):
            spec = {}

        container_statuses = status.get("containerStatuses") or []

        if not isinstance(container_statuses, list):
            container_statuses = list(container_statuses) if container_statuses else []

        restarts = 0
        ready = bool(container_statuses)

        for container in container_statuses:
            if not isinstance(container, Mapping):
                ready = False
                continue

            # ruff SIM105: use contextlib.suppress instead of try/except/pass
            with contextlib.suppress(TypeError, ValueError):
                restarts += int(container.get("restartCount") or 0)

            ready = ready and bool(container.get("ready", False))

        metadata = raw.get("metadata") or {}

        if not isinstance(metadata, Mapping):
            metadata = {}

        summaries.append(
            PodSummary(
                name=str(metadata.get("name") or getattr(pod, "name", "")),
                namespace=str(metadata.get("namespace") or getattr(pod, "namespace", namespace)),
                phase=str(status.get("phase") or "Unknown"),
                ready=ready,
                restarts=restarts,
                node=(str(spec.get("nodeName")) if spec.get("nodeName") is not None else None),
                message=_pod_message(status),
            )
        )

        if len(summaries) >= args.limit:
            break

    return ListPodsOutput(
        pods=summaries,
        total_returned=len(summaries),
    )


async def _get_pod_events(
    args: GetPodEventsInput,
    _context: SREContext,
) -> GetPodEventsOutput:
    namespace = _assert_namespace(args.namespace)

    import kr8s.asyncio

    events_iter = kr8s.asyncio.get(
        "events",
        namespace=namespace,
        field_selector={
            "involvedObject.kind": "Pod",
            "involvedObject.name": args.pod_name,
        },
    )

    raw_events = [_raw_object(event) async for event in events_iter]

    raw_events.sort(key=_event_timestamp, reverse=True)

    pod_events: list[PodEvent] = []

    for raw in raw_events[: args.limit]:
        series = raw.get("series") or {}

        if not isinstance(series, Mapping):
            series = {}

        count_value = raw.get("count")

        if count_value is None:
            count_value = series.get("count", 1)

        try:
            count = max(1, int(count_value))
        except TypeError, ValueError:
            count = 1

        pod_events.append(
            PodEvent(
                type=str(raw.get("type") or "Normal"),
                reason=str(raw.get("reason") or ""),
                message=str(raw.get("message") or ""),
                count=count,
                last_timestamp=_event_timestamp(raw),
            )
        )

    return GetPodEventsOutput(
        pod_name=args.pod_name,
        namespace=namespace,
        events=pod_events,
    )


async def _get_deployment_status(
    args: GetDeploymentStatusInput,
    _context: SREContext,
) -> DeploymentStatus:
    namespace = _assert_namespace(args.namespace)

    from kr8s.asyncio.objects import Deployment

    dep = await Deployment.get(args.name, namespace=namespace)

    raw = _raw_object(dep)

    status = raw.get("status") or {}
    spec = raw.get("spec") or {}
    metadata = raw.get("metadata") or {}

    if not isinstance(status, Mapping):
        status = {}

    if not isinstance(spec, Mapping):
        spec = {}

    if not isinstance(metadata, Mapping):
        metadata = {}

    replicas = int(spec.get("replicas") or 0)
    ready = int(status.get("readyReplicas") or 0)
    updated = int(status.get("updatedReplicas") or 0)
    available = int(status.get("availableReplicas") or 0)
    unavailable = int(status.get("unavailableReplicas") or 0)

    template = spec.get("template") or {}

    template_spec = template.get("spec") if isinstance(template, Mapping) else {}

    containers = template_spec.get("containers") if isinstance(template_spec, Mapping) else []

    if not isinstance(containers, list):
        containers = list(containers) if containers else []

    image = None

    if containers and isinstance(containers[0], Mapping):
        image = containers[0].get("image")

    generation = int(metadata.get("generation") or 0)
    observed_generation = int(status.get("observedGeneration") or 0)

    generation_current = not generation or observed_generation >= generation

    healthy = replicas == ready == updated == available and unavailable == 0 and generation_current

    return DeploymentStatus(
        name=str(metadata.get("name") or getattr(dep, "name", args.name)),
        namespace=str(metadata.get("namespace") or getattr(dep, "namespace", namespace)),
        replicas=replicas,
        ready_replicas=ready,
        updated_replicas=updated,
        available_replicas=available,
        unavailable_replicas=unavailable,
        image=str(image) if image is not None else None,
        healthy=healthy,
    )


async def _restart_deployment(
    args: RestartDeploymentInput,
    _context: SREContext,
) -> RestartDeploymentOutput:
    namespace = _assert_namespace(args.namespace)

    from kr8s.asyncio.objects import Deployment

    dep = await Deployment.get(args.name, namespace=namespace)

    restarted_at = _dt.datetime.now(_dt.UTC).isoformat().replace("+00:00", "Z")

    patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "kubectl.kubernetes.io/restartedAt": restarted_at,
                        "autosre/restart-reason": args.reason,
                    }
                }
            }
        }
    }

    await dep.patch(patch)

    return RestartDeploymentOutput(
        name=args.name,
        namespace=namespace,
        restarted=True,
        reason=args.reason,
    )


def register(registry: ToolRegistry, context: SREContext) -> None:
    """Register all Kubernetes tools."""

    registry.register(
        Tool(
            name="list_pods",
            description=(
                "List pods in an allowed namespace with an optional label "
                "selector; returns phase, readiness, restarts, node, and a "
                "compact status message."
            ),
            input_model=ListPodsInput,
            output_model=ListPodsOutput,
            handler=_list_pods,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_pod_events",
            description=(
                "Return recent Kubernetes events for a specific pod, ordered newest first."
            ),
            input_model=GetPodEventsInput,
            output_model=GetPodEventsOutput,
            handler=_get_pod_events,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_deployment_status",
            description=(
                "Return current Deployment replica counts, image, and a conservative health flag."
            ),
            input_model=GetDeploymentStatusInput,
            output_model=DeploymentStatus,
            handler=_get_deployment_status,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="restart_deployment",
            description=(
                "Trigger a Deployment rollout restart by changing the "
                "pod-template restartedAt annotation. Tier-1 action; every "
                "invocation creates a new rollout."
            ),
            input_model=RestartDeploymentInput,
            output_model=RestartDeploymentOutput,
            handler=_restart_deployment,
            risk_tier=1,
        )
    )
