"""Kubernetes diagnostic and remediation tools using kr8s.

## Tools Registered

### Tier 0 — Read-Only Diagnostics (5 tools)
- `list_pods`: List pods with status, restarts, age, node
- `get_pod_events`: Kubernetes events for a specific pod
- `get_pod_logs`: Recent log lines from a pod (supports previous=True)
- `get_deployment_status`: Deployment replica counts and conditions
- `get_pod_metrics`: CPU (millicores) and memory (MiB) usage per pod

### Tier 1 — Reversible Remediation (2 tools)
- `restart_deployment`: Patch restartedAt annotation → rolling restart
- `delete_pod`: Delete a pod (grace_period=0 for force delete)

### Tier 2 — Requires Approval (1 tool)
- `scale_deployment`: Scale deployment replicas to target count

## Contracts

### Output Contract
Every Tier-1 tool output model includes:
- `success: bool` — True if the tool executed without error
- `verification_passed: bool | None` — True if output indicates root cause
  resolved, None if indeterminate

This is required by `verify_node` in graph_nodes.py. Tier-1 actions may
return `verification_passed=None` when the Kubernetes controller has not yet
reconciled the requested change; verification is then handled by the graph.

### SREContext Contract
The Kubernetes client is accessed via `context.k8s_client`. It must be a
`kr8s.asyncio.Api` instance (or API-compatible async client). If None,
tools raise ToolExecutionError.

### Error Handling Contract
All kr8s API calls are wrapped in try/except and re-raised as
ToolExecutionError with the tool name and original exception. This ensures
the graph node can catch and handle tool failures uniformly.

### Metrics API Contract
The `get_pod_metrics` tool queries `pods.metrics.k8s.io`. If the metrics
server is not installed or unavailable (returns 404/503/504), the tool returns
an empty metrics list with `reason="metrics_api_unavailable"` instead of
failing. This is a graceful degradation — the agent can still investigate
using other tools.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Mapping
from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any

from kr8s.asyncio.objects import Deployment, Pod
from pydantic import BaseModel, Field

from autosre.core.state import SREContext
from autosre.tools.registry import (
    Tool,
    ToolExecutionError,
    ToolInputModel,
    ToolRegistry,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Input / Output Models
# ---------------------------------------------------------------------------


class ListPodsInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=253)
    label_selector: str = Field(default="", max_length=500)


class PodInfo(BaseModel):
    name: str
    namespace: str
    status: str
    restarts: int
    age_seconds: float
    node: str | None = None


class ListPodsOutput(BaseModel):
    pods: list[PodInfo]
    total: int


class GetPodEventsInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=253)
    pod_name: str = Field(min_length=1, max_length=253)
    limit: int = Field(default=50, ge=1, le=200)


class EventInfo(BaseModel):
    type: str
    reason: str
    message: str
    count: int
    last_timestamp: str


class GetPodEventsOutput(BaseModel):
    events: list[EventInfo]
    total: int


class GetPodLogsInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=253)
    pod_name: str = Field(min_length=1, max_length=253)
    container: str | None = Field(default=None, min_length=1, max_length=253)
    tail_lines: int = Field(default=100, ge=1, le=1000)
    previous: bool = Field(default=False)


class GetPodLogsOutput(BaseModel):
    logs: str
    truncated: bool


class GetDeploymentStatusInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=253)
    name: str = Field(min_length=1, max_length=253)


class GetDeploymentStatusOutput(BaseModel):
    name: str
    namespace: str
    replicas: int
    ready_replicas: int
    updated_replicas: int
    available_replicas: int
    conditions: list[dict[str, Any]]


class GetPodMetricsInput(ToolInputModel):
    """Get CPU/memory metrics for pods in a namespace."""

    namespace: str = Field(min_length=1, max_length=253)
    label_selector: str = Field(default="", max_length=500)


class PodMetrics(BaseModel):
    name: str
    cpu_millicores: int
    memory_mb: int
    cpu_request_millicores: int
    memory_request_mb: int


class GetPodMetricsOutput(BaseModel):
    metrics: list[PodMetrics]
    total: int
    reason: str | None = None


class RestartDeploymentInput(ToolInputModel):
    namespace: str = Field(min_length=1, max_length=253)
    name: str = Field(min_length=1, max_length=253)
    reason: str = Field(min_length=1, max_length=500)


class RestartDeploymentOutput(BaseModel):
    name: str
    namespace: str
    restarted: bool
    reason: str
    success: bool = True
    verification_passed: bool | None = None


class ScaleDeploymentInput(ToolInputModel):
    """Scale deployment replicas (Tier 2; approval is handled by the graph)."""

    namespace: str = Field(min_length=1, max_length=253)
    name: str = Field(min_length=1, max_length=253)
    replicas: int = Field(
        ge=0,
        le=50,
        description="Target replica count; 0 requires approval",
    )
    reason: str = Field(min_length=1, max_length=500)


class ScaleDeploymentOutput(BaseModel):
    name: str
    namespace: str
    previous_replicas: int
    new_replicas: int
    scaled: bool
    reason: str
    success: bool = True
    verification_passed: bool | None = None


class DeletePodInput(ToolInputModel):
    """Delete a pod; grace_period_seconds=0 maps to kr8s force deletion."""

    namespace: str = Field(min_length=1, max_length=253)
    name: str = Field(min_length=1, max_length=253)
    grace_period_seconds: int = Field(default=0, ge=0, le=300)
    reason: str = Field(min_length=1, max_length=500)


class DeletePodOutput(BaseModel):
    name: str
    namespace: str
    deleted: bool
    reason: str
    success: bool = True
    verification_passed: bool | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _k8s_client(context: SREContext) -> Any:
    """Return the async kr8s client from SREContext.

    Raises:
        ToolExecutionError: If k8s_client is not initialized
    """
    client = getattr(context, "k8s_client", None)
    if client is None:
        raise ToolExecutionError(
            "k8s._k8s_client",
            RuntimeError("SREContext.k8s_client is not initialised"),
        )
    return client


async def _collect_async(iterable: Any, tool_name: str) -> list[Any]:
    """Materialise a kr8s async generator and wrap client failures."""
    try:
        return [item async for item in iterable]
    except Exception as exc:
        raise ToolExecutionError(tool_name, exc) from exc


async def _get_pod(
    client: Any,
    name: str,
    namespace: str,
    tool_name: str,
) -> Any:
    try:
        return await Pod.get(name, namespace=namespace, api=client)
    except Exception as exc:
        raise ToolExecutionError(tool_name, exc) from exc


def _is_not_found(exc: BaseException) -> bool:
    """Return True when a Kubernetes client exception represents HTTP 404."""
    status = getattr(exc, "status", None)
    if status == 404:
        return True

    response = getattr(exc, "response", None)
    response_status = getattr(response, "status_code", None)
    if response_status == 404:
        return True

    message = str(exc).lower()
    return "404" in message or "not found" in message


async def _get_deployment(
    client: Any,
    name: str,
    namespace: str,
    tool_name: str,
) -> Any:
    try:
        return await Deployment.get(name, namespace=namespace, api=client)
    except Exception as exc:
        raise ToolExecutionError(tool_name, exc) from exc


def _map_get(
    mapping: Mapping[Any, Any] | Any,
    key: str,
    default: Any = None,
) -> Any:
    """Read a string key from mappings that may use bytes keys."""
    if not isinstance(mapping, Mapping):
        return default

    if key in mapping:
        return mapping[key]

    byte_key = key.encode()
    if byte_key in mapping:
        return mapping[byte_key]

    return default


def _to_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default

        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")

        return int(value)
    except TypeError, ValueError:
        return default


def _to_text(value: Any, default: str = "") -> str:
    if value is None:
        return default

    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")

    return str(value)


def _event_timestamp(event: Mapping[str, Any]) -> str:
    """Return the newest available Kubernetes Event timestamp field."""
    for key in ("eventTime", "lastTimestamp", "firstTimestamp"):
        value = _map_get(event, key)
        if value:
            return _to_text(value)

    series = _map_get(event, "series", {})
    if isinstance(series, Mapping):
        value = _map_get(series, "lastObservedTime")
        if value:
            return _to_text(value)

    return ""


def _event_sort_key(event: Mapping[str, Any]) -> datetime:
    timestamp = _event_timestamp(event)

    if not timestamp:
        return datetime.min.replace(tzinfo=UTC)

    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)
    except TypeError, ValueError:
        return datetime.min.replace(tzinfo=UTC)


def _parse_quantity(value: Any) -> tuple[Decimal, str] | None:
    """Split a Kubernetes resource quantity into numeric part and suffix."""
    text = _to_text(value).strip()

    match = re.fullmatch(
        r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)([a-zA-Z]{0,2})",
        text,
    )

    if not match:
        return None

    try:
        return Decimal(match.group(1)), match.group(2)
    except InvalidOperation:
        return None


def _decimal_to_int(value: Decimal) -> int:
    return int(value.to_integral_value(rounding=ROUND_HALF_UP))


def _parse_cpu(value: Any) -> int:
    """Parse a Kubernetes CPU quantity into millicores."""
    parsed = _parse_quantity(value)

    if parsed is None:
        return 0

    number, suffix = parsed

    factors = {
        "": Decimal("1000"),
        "m": Decimal("1"),
        "u": Decimal("0.001"),
        "n": Decimal("0.000001"),
        "k": Decimal("1000000"),
    }

    factor = factors.get(suffix)

    if factor is None:
        return 0

    return max(0, _decimal_to_int(number * factor))


def _parse_memory_mb(value: Any) -> int:
    """Parse a Kubernetes memory quantity into MiB."""
    parsed = _parse_quantity(value)

    if parsed is None:
        return 0

    number, suffix = parsed

    # Kubernetes binary suffixes use powers of 1024; decimal suffixes use
    # powers of 1000. The public field is historically named *_mb but
    # represents MiB.
    bytes_per_unit = {
        "Ki": Decimal(1024),
        "Mi": Decimal(1024) ** 2,
        "Gi": Decimal(1024) ** 3,
        "Ti": Decimal(1024) ** 4,
        "Pi": Decimal(1024) ** 5,
        "Ei": Decimal(1024) ** 6,
        "K": Decimal(1000),
        "k": Decimal(1000),
        "M": Decimal(1000) ** 2,
        "G": Decimal(1000) ** 3,
        "T": Decimal(1000) ** 4,
        "P": Decimal(1000) ** 5,
        "E": Decimal(1000) ** 6,
        "": Decimal(1),
    }

    factor = bytes_per_unit.get(suffix)

    if factor is None:
        return 0

    mib = number * factor / (Decimal(1024) ** 2)
    return max(0, _decimal_to_int(mib))


def _metrics_api_unavailable(exc: Exception) -> bool:
    """Identify common absence/unavailability cases for metrics.k8s.io."""
    status = getattr(exc, "status", None)

    if status in {404, 503, 504}:
        return True

    message = str(exc).lower()

    return "metrics.k8s.io" in message and (
        "not found" in message
        or "no resource" in message
        or "unavailable" in message
        or "service unavailable" in message
    )


# ---------------------------------------------------------------------------
# Tier 0: Read-only diagnostics
# ---------------------------------------------------------------------------


async def _list_pods(
    args: ListPodsInput,
    context: SREContext,
) -> ListPodsOutput:
    client = _k8s_client(context)
    selector = args.label_selector or None

    try:
        raw_iter = client.get(
            "pods",
            namespace=args.namespace,
            label_selector=selector,
            raw=True,
        )
    except Exception as exc:
        raise ToolExecutionError("list_pods", exc) from exc

    pods_raw = await _collect_async(raw_iter, "list_pods")

    pods: list[PodInfo] = []

    for raw in pods_raw:
        if not isinstance(raw, Mapping):
            continue

        metadata = _map_get(raw, "metadata", {})
        status_raw = _map_get(raw, "status", {})
        spec = _map_get(raw, "spec", {})
        container_statuses = _map_get(status_raw, "containerStatuses", [])

        if not isinstance(container_statuses, list):
            container_statuses = []

        restarts = sum(
            _to_int(_map_get(container_status, "restartCount", 0))
            for container_status in container_statuses
            if isinstance(container_status, Mapping)
        )

        creation = _to_text(_map_get(metadata, "creationTimestamp", ""))
        age_seconds = 0.0

        if creation:
            try:
                created = datetime.fromisoformat(creation.replace("Z", "+00:00"))
                age_seconds = max(
                    0.0,
                    (datetime.now(UTC) - created).total_seconds(),
                )
            except TypeError, ValueError:
                age_seconds = 0.0

        node_raw = _map_get(spec, "nodeName")

        pods.append(
            PodInfo(
                name=_to_text(_map_get(metadata, "name", "")),
                namespace=_to_text(
                    _map_get(metadata, "namespace", args.namespace),
                    args.namespace,
                ),
                status=_to_text(
                    _map_get(status_raw, "phase", "Unknown"),
                    "Unknown",
                ),
                restarts=restarts,
                age_seconds=round(age_seconds, 2),
                node=_to_text(node_raw) if node_raw is not None else None,
            )
        )

    return ListPodsOutput(
        pods=pods,
        total=len(pods),
    )


async def _get_pod_events(
    args: GetPodEventsInput,
    context: SREContext,
) -> GetPodEventsOutput:
    client = _k8s_client(context)

    try:
        raw_iter = client.get(
            "events",
            namespace=args.namespace,
            field_selector=f"involvedObject.name={args.pod_name}",
            raw=True,
        )
    except Exception as exc:
        raise ToolExecutionError("get_pod_events", exc) from exc

    events_raw = await _collect_async(
        raw_iter,
        "get_pod_events",
    )

    candidates = [event for event in events_raw if isinstance(event, Mapping)]
    candidates.sort(
        key=_event_sort_key,
        reverse=True,
    )

    events: list[EventInfo] = []

    for event in candidates[: args.limit]:
        events.append(
            EventInfo(
                type=_to_text(
                    _map_get(event, "type", "Normal"),
                    "Normal",
                ),
                reason=_to_text(_map_get(event, "reason", "")),
                message=_to_text(_map_get(event, "message", "")),
                count=_to_int(
                    _map_get(event, "count", 1),
                    1,
                ),
                last_timestamp=_event_timestamp(event),
            )
        )

    return GetPodEventsOutput(
        events=events,
        total=len(events),
    )


async def _get_pod_logs(
    args: GetPodLogsInput,
    context: SREContext,
) -> GetPodLogsOutput:
    client = _k8s_client(context)

    pod = await _get_pod(
        client,
        args.pod_name,
        args.namespace,
        "get_pod_logs",
    )

    try:
        log_iter = pod.logs(
            container=args.container,
            tail_lines=args.tail_lines,
            previous=args.previous,
            follow=False,
        )
        chunks = [chunk async for chunk in log_iter]
    except Exception as exc:
        raise ToolExecutionError(
            "get_pod_logs",
            exc,
        ) from exc

    log_text = "\n".join(_to_text(chunk).rstrip("\n") for chunk in chunks)

    max_chars = 20_000
    truncated = len(log_text) > max_chars

    if truncated:
        log_text = log_text[:max_chars]

    return GetPodLogsOutput(
        logs=log_text,
        truncated=truncated,
    )


async def _get_deployment_status(
    args: GetDeploymentStatusInput,
    context: SREContext,
) -> GetDeploymentStatusOutput:
    client = _k8s_client(context)

    dep = await _get_deployment(
        client,
        args.name,
        args.namespace,
        "get_deployment_status",
    )

    raw = dep.to_dict()

    status = raw.get("status") if isinstance(raw, Mapping) else {}

    if not isinstance(status, Mapping):
        status = {}

    conditions_raw = status.get("conditions", [])

    if not isinstance(conditions_raw, list):
        conditions_raw = []

    conditions = [
        {
            "type": _to_text(_map_get(condition, "type", "")),
            "status": _to_text(_map_get(condition, "status", "")),
            "reason": _to_text(_map_get(condition, "reason", "")),
            "message": _to_text(_map_get(condition, "message", "")),
        }
        for condition in conditions_raw
        if isinstance(condition, Mapping)
    ]

    return GetDeploymentStatusOutput(
        name=dep.name,
        namespace=dep.namespace,
        replicas=_to_int(status.get("replicas", 0)),
        ready_replicas=_to_int(status.get("readyReplicas", 0)),
        updated_replicas=_to_int(status.get("updatedReplicas", 0)),
        available_replicas=_to_int(status.get("availableReplicas", 0)),
        conditions=conditions,
    )


async def _get_pod_metrics(
    args: GetPodMetricsInput,
    context: SREContext,
) -> GetPodMetricsOutput:
    """Get Pod CPU/memory usage and configured resource requests.

    Pod specs are read before the Metrics API to minimise mismatches caused by
    pods being created or deleted between the two reads. If metrics.k8s.io is
    unavailable, the tool degrades gracefully and identifies the reason.
    """
    client = _k8s_client(context)
    selector = args.label_selector or None

    # Read Pod specs first so resource requests are anchored to the same
    # namespace/selector before taking the usage snapshot.
    try:
        pods_iter = client.get(
            "pods",
            namespace=args.namespace,
            label_selector=selector,
            raw=True,
        )
        pods_raw = await _collect_async(
            pods_iter,
            "get_pod_metrics",
        )
    except Exception as exc:
        raise ToolExecutionError(
            "get_pod_metrics",
            exc,
        ) from exc

    requests_by_pod: dict[str, tuple[int, int]] = {}

    for raw_pod in pods_raw:
        if not isinstance(raw_pod, Mapping):
            continue

        metadata = _map_get(raw_pod, "metadata", {})
        spec = _map_get(raw_pod, "spec", {})
        containers = _map_get(spec, "containers", [])
        pod_name = _to_text(_map_get(metadata, "name", ""))

        if not pod_name or not isinstance(containers, list):
            continue

        cpu_request = 0
        memory_request = 0

        for container in containers:
            if not isinstance(container, Mapping):
                continue

            resources = _map_get(container, "resources", {})
            requests = _map_get(resources, "requests", {})

            if isinstance(requests, Mapping):
                cpu_request += _parse_cpu(_map_get(requests, "cpu", "0"))
                memory_request += _parse_memory_mb(_map_get(requests, "memory", "0"))

        requests_by_pod[pod_name] = (
            cpu_request,
            memory_request,
        )

    try:
        metrics_iter = client.get(
            "pods.metrics.k8s.io",
            namespace=args.namespace,
            label_selector=selector,
            raw=True,
        )
        metrics_raw = [item async for item in metrics_iter]
    except Exception as exc:
        if _metrics_api_unavailable(exc):
            logger.warning("metrics.k8s.io unavailable; returning empty metrics")
            return GetPodMetricsOutput(
                metrics=[],
                total=0,
                reason="metrics_api_unavailable",
            )

        raise ToolExecutionError(
            "get_pod_metrics",
            exc,
        ) from exc

    metrics: list[PodMetrics] = []

    for metric in metrics_raw:
        if not isinstance(metric, Mapping):
            continue

        metadata = _map_get(metric, "metadata", {})
        containers = _map_get(metric, "containers", [])

        if not isinstance(containers, list):
            containers = []

        total_cpu = 0
        total_memory = 0

        for container in containers:
            if not isinstance(container, Mapping):
                continue

            usage = _map_get(container, "usage", {})

            if isinstance(usage, Mapping):
                total_cpu += _parse_cpu(_map_get(usage, "cpu", "0"))
                total_memory += _parse_memory_mb(_map_get(usage, "memory", "0"))

        pod_name = _to_text(_map_get(metadata, "name", ""))
        cpu_request, memory_request = requests_by_pod.get(
            pod_name,
            (0, 0),
        )

        metrics.append(
            PodMetrics(
                name=pod_name,
                cpu_millicores=total_cpu,
                memory_mb=total_memory,
                cpu_request_millicores=cpu_request,
                memory_request_mb=memory_request,
            )
        )

    return GetPodMetricsOutput(
        metrics=metrics,
        total=len(metrics),
    )


# ---------------------------------------------------------------------------
# Tier 1: Targeted remediation
# ---------------------------------------------------------------------------


async def _restart_deployment(
    args: RestartDeploymentInput,
    context: SREContext,
) -> RestartDeploymentOutput:
    """Trigger a rolling restart by updating the pod-template annotation.

    The Kubernetes API accepts the patch synchronously, but the rollout itself
    is asynchronous. Therefore verification_passed remains None and is left to
    the graph's verification step.
    """
    client = _k8s_client(context)

    dep = await _get_deployment(
        client,
        args.name,
        args.namespace,
        "restart_deployment",
    )

    restart_patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "kubectl.kubernetes.io/restartedAt": (datetime.now(UTC).isoformat())
                    }
                }
            }
        }
    }

    try:
        await dep.patch(restart_patch)
        logger.info(
            "Deployment %s/%s restart initiated",
            args.namespace,
            args.name,
        )

        return RestartDeploymentOutput(
            name=args.name,
            namespace=args.namespace,
            restarted=True,
            reason=args.reason,
            success=True,
            verification_passed=None,
        )
    except Exception as exc:
        raise ToolExecutionError(
            "restart_deployment",
            exc,
        ) from exc


async def _delete_pod(
    args: DeletePodInput,
    context: SREContext,
) -> DeletePodOutput:
    """Delete a pod, optionally with force (grace_period=0).

    A pod that is already absent is treated as success because the desired
    post-condition has already been reached. A successful DELETE request does
    not prove that termination has completed, so verification is deferred.
    """
    client = _k8s_client(context)

    try:
        pod = await _get_pod(
            client,
            args.name,
            args.namespace,
            "delete_pod",
        )
    except ToolExecutionError as exc:
        if _is_not_found(exc.original):
            logger.info(
                "Pod %s/%s already absent",
                args.namespace,
                args.name,
            )

            return DeletePodOutput(
                name=args.name,
                namespace=args.namespace,
                deleted=True,
                reason=args.reason,
                success=True,
                verification_passed=True,
            )

        raise

    delete_kwargs: dict[str, Any] = {}

    if args.grace_period_seconds == 0:
        delete_kwargs["grace_period_seconds"] = 0

    try:
        await pod.delete(**delete_kwargs)
    except Exception as exc:
        if _is_not_found(exc):
            logger.info(
                "Pod %s/%s became absent during deletion",
                args.namespace,
                args.name,
            )

            return DeletePodOutput(
                name=args.name,
                namespace=args.namespace,
                deleted=True,
                reason=args.reason,
                success=True,
                verification_passed=True,
            )

        raise ToolExecutionError(
            "delete_pod",
            exc,
        ) from exc

    logger.info(
        "Pod %s/%s deletion requested (grace=%ds)",
        args.namespace,
        args.name,
        args.grace_period_seconds,
    )

    return DeletePodOutput(
        name=args.name,
        namespace=args.namespace,
        deleted=True,
        reason=args.reason,
        success=True,
        verification_passed=None,
    )


# ---------------------------------------------------------------------------
# Tier 2: Requires approval
# ---------------------------------------------------------------------------


async def _scale_deployment(
    args: ScaleDeploymentInput,
    context: SREContext,
) -> ScaleDeploymentOutput:
    """Scale a deployment to a target replica count.

    This action requires approval at the graph/policy layer. Scaling is
    asynchronous, so verification_passed remains None after a successful patch.
    If the deployment is already at the requested replica count, the tool treats
    the desired state as already achieved and returns verification_passed=True.
    """
    client = _k8s_client(context)

    dep = await _get_deployment(
        client,
        args.name,
        args.namespace,
        "scale_deployment",
    )

    raw = dep.to_dict()

    spec = raw.get("spec", {}) if isinstance(raw, Mapping) else {}

    previous_replicas = _to_int(spec.get("replicas", 0) if isinstance(spec, Mapping) else 0)

    if previous_replicas == args.replicas:
        logger.info(
            "Deployment %s/%s already at %d replicas",
            args.namespace,
            args.name,
            args.replicas,
        )

        return ScaleDeploymentOutput(
            name=args.name,
            namespace=args.namespace,
            previous_replicas=previous_replicas,
            new_replicas=args.replicas,
            scaled=False,
            reason=args.reason,
            success=True,
            verification_passed=True,
        )

    scale_patch = {"spec": {"replicas": args.replicas}}

    try:
        await dep.patch(scale_patch)

        logger.info(
            "Deployment %s/%s scaled from %d to %d replicas",
            args.namespace,
            args.name,
            previous_replicas,
            args.replicas,
        )

        return ScaleDeploymentOutput(
            name=args.name,
            namespace=args.namespace,
            previous_replicas=previous_replicas,
            new_replicas=args.replicas,
            scaled=True,
            reason=args.reason,
            success=True,
            verification_passed=None,
        )
    except Exception as exc:
        raise ToolExecutionError(
            "scale_deployment",
            exc,
        ) from exc


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def register(
    registry: ToolRegistry,
    context: SREContext,
) -> None:
    """Register all Kubernetes tools with the given registry.

    Called by build_default_registry() in registry.py.

    Args:
        registry: ToolRegistry to register tools with
        context: SREContext (passed to handlers at execution time, not stored)
    """
    # Tier 0: Read-only diagnostics
    registry.register(
        Tool(
            name="list_pods",
            description=(
                "List pods in a namespace with status, restart count, age, and node assignment"
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
                "Get Kubernetes events for a specific pod, including "
                "CrashLoopBackOff, OOMKilled, and scheduling events"
            ),
            input_model=GetPodEventsInput,
            output_model=GetPodEventsOutput,
            handler=_get_pod_events,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_pod_logs",
            description=(
                "Get recent log lines from a pod. Use previous=True to "
                "get logs from the last crashed container"
            ),
            input_model=GetPodLogsInput,
            output_model=GetPodLogsOutput,
            handler=_get_pod_logs,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_deployment_status",
            description=(
                "Get deployment replica counts and conditions (ready, updated, available)"
            ),
            input_model=GetDeploymentStatusInput,
            output_model=GetDeploymentStatusOutput,
            handler=_get_deployment_status,
            risk_tier=0,
        )
    )

    registry.register(
        Tool(
            name="get_pod_metrics",
            description=(
                "Get CPU (millicores) and memory (MiB) usage for pods. "
                "Returns empty with reason if metrics-server is unavailable"
            ),
            input_model=GetPodMetricsInput,
            output_model=GetPodMetricsOutput,
            handler=_get_pod_metrics,
            risk_tier=0,
        )
    )

    # Tier 1: Reversible remediation
    registry.register(
        Tool(
            name="restart_deployment",
            description=(
                "Restart a deployment by patching the restartedAt annotation (rolling restart)"
            ),
            input_model=RestartDeploymentInput,
            output_model=RestartDeploymentOutput,
            handler=_restart_deployment,
            risk_tier=1,
        )
    )

    registry.register(
        Tool(
            name="delete_pod",
            description=(
                "Delete a pod. Use grace_period_seconds=0 to force delete stuck Terminating pods"
            ),
            input_model=DeletePodInput,
            output_model=DeletePodOutput,
            handler=_delete_pod,
            risk_tier=1,
        )
    )

    # Tier 2: Requires approval
    registry.register(
        Tool(
            name="scale_deployment",
            description=(
                "Scale a deployment to a target replica count. "
                "Requires human approval before execution"
            ),
            input_model=ScaleDeploymentInput,
            output_model=ScaleDeploymentOutput,
            handler=_scale_deployment,
            risk_tier=2,
        )
    )
