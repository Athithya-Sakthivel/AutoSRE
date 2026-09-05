"""Restart an Azure Container Apps revision."""

from __future__ import annotations

from typing import Any

from opentelemetry import trace

from ..config import ConfigError
from ..helpers import utc_now_iso
from ..runtime import get_runtime


async def _latest_revision_name(subscription_id: str, resource_group: str, app_name: str) -> str:
    runtime = get_runtime()
    token = await runtime.get_token("https://management.azure.com/.default")
    url = (
        f"{runtime.settings.azure_management_endpoint}/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.App/containerApps/{app_name}/revisions"
        f"?api-version={runtime.settings.azure_container_apps_api_version}"
    )
    response = await runtime.http.get(url, headers={"Authorization": f"Bearer {token}"})
    response.raise_for_status()
    payload = response.json()
    revisions = payload.get("value") or []
    if not revisions:
        raise ConfigError("No revisions returned by Azure Container Apps")

    def _score(item: dict[str, Any]) -> tuple[int, str]:
        props = item.get("properties") or {}
        active = 1 if str(props.get("active", "")).lower() == "true" else 0
        name = str(item.get("name") or props.get("revisionName") or "")
        return (active, name)

    revisions.sort(key=_score, reverse=True)
    chosen = revisions[0]
    return str(chosen.get("name") or chosen.get("properties", {}).get("revisionName") or "")


async def restart_aca_revision(service_name: str) -> dict[str, Any]:
    """Restart the latest (or configured) revision of the target Container App."""
    runtime = get_runtime()
    settings = runtime.settings
    subscription_id, resource_group, app_name = settings.require_aca()

    if service_name.strip() != app_name:
        raise ConfigError(
            f"service_name '{service_name}' does not match configured AZURE_CONTAINER_APP_NAME '{app_name}'"
        )

    tracer = trace.get_tracer(settings.service_name)
    with tracer.start_as_current_span("restart_aca_revision") as span:
        revision_name = settings.azure_container_app_revision.strip()
        if not revision_name:
            revision_name = await _latest_revision_name(subscription_id, resource_group, app_name)

        token = await runtime.get_token("https://management.azure.com/.default")
        url = (
            f"{settings.azure_management_endpoint}/subscriptions/{subscription_id}"
            f"/resourceGroups/{resource_group}/providers/Microsoft.App/containerApps/{app_name}"
            f"/revisions/{revision_name}/restart"
            f"?api-version={settings.azure_container_apps_api_version}"
        )
        response = await runtime.http.post(url, headers={"Authorization": f"Bearer {token}"})
        if response.status_code >= 400:
            raise RuntimeError(
                f"Container Apps restart failed: {response.status_code} {response.text}"
            )

        span.set_attribute("mcp.tool", "restart_aca_revision")
        span.set_attribute("aca.revision_name", revision_name)
        return {
            "service_name": service_name,
            "subscription_id": subscription_id,
            "resource_group": resource_group,
            "container_app_name": app_name,
            "revision_name": revision_name,
            "message": "revision restart accepted",
            "timestamp": utc_now_iso(),
        }
