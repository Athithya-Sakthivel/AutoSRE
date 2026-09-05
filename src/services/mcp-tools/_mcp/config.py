"""Strict configuration – secrets via Azure Key Vault, config via env vars.

Set KEY_VAULT_NAME to enable Key Vault lookups.  Secret names can be
overridden with *_AKV_SECRET_NAME variables.  No secret values should
ever be placed in environment variables when Key Vault is in use.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Final

logger = logging.getLogger(__name__)


class ConfigError(RuntimeError):
    """Raised when required configuration is missing or invalid."""


_VALID_SAMPLING_MODES: Final = {"rate", "ratio", "off"}

# ----------------------------------------------------------------- helpers --


def _env(name: str, default: str | None = None) -> str:
    value = os.getenv(name)
    if value is None or value == "":
        if default is None:
            raise ConfigError(f"Missing required environment variable: {name}")
        return default
    return value


def _env_float(name: str, default: float) -> float:
    value = os.getenv(name)
    if value in (None, ""):
        return default
    try:
        return float(value)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number") from exc


def _env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if value in (None, ""):
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc


def _env_path(name: str, default: str) -> Path:
    return Path(os.getenv(name, default)).expanduser()


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def _load_key_vault_secret(vault_name: str, secret_name: str) -> str | None:
    """Return the secret value or None if not found / not accessible."""
    try:
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient
    except ImportError:
        logger.warning("Azure SDK not installed – cannot load secrets from Key Vault.")
        return None

    try:
        credential = DefaultAzureCredential()
        client = SecretClient(
            vault_url=f"https://{vault_name}.vault.azure.net",
            credential=credential,
        )
        secret = client.get_secret(secret_name)
        if secret.value:
            return str(secret.value).strip()
    except Exception:
        logger.debug("Secret not found in vault")
    return None


def _resolve_secret(
    env_var: str,
    secret_name: str,
    key_vault_name: str | None,
    *,
    default: str = "",
    secret_required: bool = False,
) -> str:
    """
    Resolve a secret value:
    1. If key_vault_name is set → fetch from Key Vault (fail if required).
    2. Otherwise → use environment variable.
    """
    if key_vault_name:
        # In Key Vault mode we never look at env var for the secret value.
        value = _load_key_vault_secret(key_vault_name, secret_name)
        if value is not None:
            return value
        if secret_required:
            raise ConfigError(
                f"Secret '{secret_name}' not found in Key Vault '{key_vault_name}' "
                f"(required). Create it or adjust the secret name."
            )
        # If not required and not found, fall back to default (empty).
        return default

    # No Key Vault configured – use environment variable.
    value = os.getenv(env_var, default)
    if secret_required and not value:
        raise ConfigError(f"{env_var} is required. Set it or configure KEY_VAULT_NAME.")
    return value


# ------------------------------------------------------------ Settings --


@dataclass(frozen=True, slots=True)
class Settings:
    service_name: str = "mcp-tools"
    service_version: str = "1.0.0"
    environment: str = "production"
    mode: str = "production"
    battle_test: bool = False
    log_level: str = "INFO"

    # Observability
    applicationinsights_connection_string: str = ""
    sampling_mode: str = "rate"
    sampling_ratio: float = 0.1
    traces_per_second: float = 5.0
    enable_live_metrics: bool = True

    # Log Analytics
    log_analytics_workspace_id: str = ""
    log_analytics_endpoint: str = "https://api.loganalytics.azure.com"

    # Git
    git_repo_root: Path = Path(".")

    # GitHub
    github_token: str = ""
    github_repository: str = ""
    github_base_branch: str = "main"
    github_head_branch: str = ""
    github_api_version: str = "2026-03-10"

    # Azure Container Apps
    azure_subscription_id: str = ""
    azure_resource_group: str = ""
    azure_container_app_name: str = ""
    azure_container_app_revision: str = ""
    azure_management_endpoint: str = "https://management.azure.com"
    azure_container_apps_api_version: str = "2026-01-01"

    # MCP API Key
    mcp_api_key: str = ""

    # Key Vault (for reference)
    key_vault_name: str | None = None

    # Runtime
    request_timeout_seconds: float = 30.0
    query_limit: int = 25

    def preflight(self) -> None:
        if self.mode != "production":
            return

        self.require_observability()
        self.require_workspace()

        if not self.battle_test:
            self.require_git()
            self.require_github()
            self.require_aca()

        if not self.mcp_api_key.strip():
            raise ConfigError(
                "MCP_API_KEY is required in production mode. "
                "Place it in Key Vault or set the env var."
            )

    def require_observability(self) -> None:
        if not self.applicationinsights_connection_string.strip():
            raise ConfigError("APPLICATIONINSIGHTS_CONNECTION_STRING is required")
        if self.sampling_mode not in _VALID_SAMPLING_MODES:
            raise ConfigError(f"OTEL_SAMPLING_MODE must be one of {sorted(_VALID_SAMPLING_MODES)}")
        if self.sampling_mode == "ratio" and not (0.0 <= self.sampling_ratio <= 1.0):
            raise ConfigError("OTEL_SAMPLING_RATIO must be between 0 and 1")
        if self.sampling_mode == "rate" and self.traces_per_second <= 0:
            raise ConfigError("OTEL_TRACES_PER_SECOND must be > 0")

    def require_workspace(self) -> None:
        if not self.log_analytics_workspace_id.strip():
            raise ConfigError("LOG_ANALYTICS_WORKSPACE_ID is required")

    def require_git(self) -> Path:
        root = self.git_repo_root.expanduser().resolve()
        if not root.exists():
            raise ConfigError(f"GIT_REPO_ROOT does not exist: {root}")
        if not root.is_dir():
            raise ConfigError(f"GIT_REPO_ROOT is not a directory: {root}")
        if not (root / ".git").exists():
            raise ConfigError(f"GIT_REPO_ROOT is not a git repository: {root}")
        return root

    def require_github(self) -> tuple[str, str, str]:
        if not self.github_token.strip():
            raise ConfigError("GITHUB_TOKEN is required")
        repo = self.github_repository.strip()
        if not repo or "/" not in repo:
            raise ConfigError("GITHUB_REPOSITORY must be in owner/repo format")
        head = self.github_head_branch.strip()
        if not head:
            raise ConfigError("GITHUB_HEAD_BRANCH is required")
        return self.github_token.strip(), repo, head

    def require_aca(self) -> tuple[str, str, str]:
        if not self.azure_subscription_id.strip():
            raise ConfigError("AZURE_SUBSCRIPTION_ID is required")
        if not self.azure_resource_group.strip():
            raise ConfigError("AZURE_RESOURCE_GROUP is required")
        if not self.azure_container_app_name.strip():
            raise ConfigError("AZURE_CONTAINER_APP_NAME is required")
        return (
            self.azure_subscription_id.strip(),
            self.azure_resource_group.strip(),
            self.azure_container_app_name.strip(),
        )


# -------------------------------------------------------- loader --


def load_settings() -> Settings:
    """Load and validate all configuration once per process.

    Secrets are fetched from Azure Key Vault when KEY_VAULT_NAME is set.
    Otherwise environment variables are used directly (local dev without Azure).
    """
    key_vault_name = os.getenv("KEY_VAULT_NAME") or None
    mode = os.getenv("MCP_TOOLS_MODE", "production").strip().lower()
    is_production = mode == "production"

    # --- secrets ---------------------------------------------------------

    appinsights_connection_string = _resolve_secret(
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        os.getenv("APPINSIGHTS_AKV_SECRET_NAME", "appinsights-connection-string"),
        key_vault_name,
        secret_required=is_production,
    )

    mcp_api_key = _resolve_secret(
        "MCP_API_KEY",
        os.getenv("MCP_API_KEY_SECRET_NAME", "mcp-api-key"),
        key_vault_name,
        secret_required=is_production,
    )

    github_token = _resolve_secret(
        "GITHUB_TOKEN",
        os.getenv("GITHUB_TOKEN_AKV_SECRET_NAME", "github-token"),
        key_vault_name,
        secret_required=False,  # not required in battle_test mode
    )

    azure_subscription_id = _resolve_secret(
        "AZURE_SUBSCRIPTION_ID",
        os.getenv("AZURE_SUBSCRIPTION_ID_AKV_SECRET_NAME", "azure-subscription-id"),
        key_vault_name,
        secret_required=False,  # may be fetched by the user anyway
    )

    # --- non‑secret config -----------------------------------------------

    settings = Settings(
        mode=mode,
        battle_test=_truthy(os.getenv("MCP_TOOLS_BATTLE_TEST")),
        service_name=os.getenv("SERVICE_NAME", "mcp-tools"),
        service_version=os.getenv("SERVICE_VERSION", "1.0.0"),
        environment=os.getenv("ENVIRONMENT", "production"),
        log_level=os.getenv("LOG_LEVEL", "INFO"),
        applicationinsights_connection_string=appinsights_connection_string,
        sampling_mode=os.getenv("OTEL_SAMPLING_MODE", "rate").strip().lower(),
        sampling_ratio=_env_float("OTEL_SAMPLING_RATIO", 0.1),
        traces_per_second=_env_float("OTEL_TRACES_PER_SECOND", 5.0),
        enable_live_metrics=_truthy(os.getenv("OTEL_ENABLE_LIVE_METRICS", "true")),
        log_analytics_workspace_id=os.getenv("LOG_ANALYTICS_WORKSPACE_ID", ""),
        log_analytics_endpoint=os.getenv(
            "LOG_ANALYTICS_ENDPOINT", "https://api.loganalytics.azure.com"
        ).rstrip("/"),
        git_repo_root=_env_path("GIT_REPO_ROOT", "."),
        github_token=github_token,
        github_repository=os.getenv("GITHUB_REPOSITORY", ""),
        github_base_branch=os.getenv("GITHUB_BASE_BRANCH", "main"),
        github_head_branch=os.getenv("GITHUB_HEAD_BRANCH", ""),
        github_api_version=os.getenv("GITHUB_API_VERSION", "2026-03-10"),
        azure_subscription_id=azure_subscription_id,
        azure_resource_group=os.getenv("AZURE_RESOURCE_GROUP", ""),
        azure_container_app_name=os.getenv("AZURE_CONTAINER_APP_NAME", ""),
        azure_container_app_revision=os.getenv("AZURE_CONTAINER_APP_REVISION", ""),
        azure_management_endpoint=os.getenv(
            "AZURE_MANAGEMENT_ENDPOINT", "https://management.azure.com"
        ).rstrip("/"),
        azure_container_apps_api_version=os.getenv(
            "AZURE_CONTAINER_APPS_API_VERSION", "2026-01-01"
        ),
        mcp_api_key=mcp_api_key,
        key_vault_name=key_vault_name,
        request_timeout_seconds=_env_float("REQUEST_TIMEOUT_SECONDS", 30.0),
        query_limit=_env_int("QUERY_LIMIT", 25),
    )

    settings.preflight()
    return settings


# Global singleton – safe to import
settings = load_settings()
