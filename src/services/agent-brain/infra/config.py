"""Fail‑fast configuration with Azure Key Vault for all secrets.

Set KEY_VAULT_NAME to load secrets from Key Vault.  Each secret can
have its name overridden via *_AKV_SECRET_NAME environment variables.
Non‑secret configuration still comes from plain environment variables.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from functools import lru_cache
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
    """Return a secret value from Azure Key Vault, or None if not found."""
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
        logger.debug("Secret '%s' not found in vault '%s'.", secret_name, vault_name)
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
    1. If key_vault_name is set → fetch from Key Vault (fail if required).
    2. Otherwise → use environment variable.
    """
    if key_vault_name:
        value = _load_key_vault_secret(key_vault_name, secret_name)
        if value is not None:
            return value
        if secret_required:
            raise ConfigError(
                f"Secret '{secret_name}' not found in Key Vault '{key_vault_name}' (required)."
            )
        return default

    value = os.getenv(env_var, default)
    if secret_required and not value:
        raise ConfigError(f"{env_var} is required. Set it or configure KEY_VAULT_NAME.")
    return value


# ------------------------------------------------------------ Settings --


@dataclass(frozen=True, slots=True)
class Settings:
    service_name: str = "agent-brain"
    service_version: str = "1.0.0"
    environment: str = "production"
    log_level: str = "INFO"
    port: int = 8000

    # MCP tools
    mcp_tools_url: str = "http://localhost:8000/mcp"

    # Cosmos DB
    cosmos_endpoint: str = ""
    cosmos_key: str = ""
    cosmos_database: str = "agent_state_db"
    cosmos_container: str = "checkpoints"
    rate_limit_container: str = "rate_limits"
    rate_limit_threshold: int = 10
    rate_limit_window_minutes: int = 60
    rate_limit_ttl_seconds: int = 7200

    # Observability
    applicationinsights_connection_string: str = ""
    enable_live_metrics: bool = True

    # LLM endpoints – no API keys (authentication uses DefaultAzureCredential)
    cohere_base_url: str = "https://api.cohere.ai/compatibility/v1"
    cohere_model: str = "command-a-plus-05-2026"
    phi4_base_url: str = ""
    phi4_model: str = "phi-4-reasoning"

    # GitHub
    github_repo: str = ""

    # Workflow behaviour
    wait_after_deploy_seconds: int = 30
    max_retries: int = 3
    human_approval_timeout_seconds: int = 3600
    request_timeout_seconds: float = 30.0
    query_limit: int = 25

    # Auth – shared API key for mcp-tools and agent-brain REST endpoints
    mcp_api_key: str = ""
    require_auth: bool = False

    # Key Vault reference (not a secret itself)
    key_vault_name: str | None = None

    def preflight(self) -> None:
        """Validate that all critical production settings are present."""
        if self.environment == "development":
            return
        if not self.mcp_tools_url:
            raise ConfigError("MCP_TOOLS_URL is required")
        if not self.cosmos_endpoint:
            raise ConfigError("COSMOS_ENDPOINT is required")
        if not self.cosmos_key:
            raise ConfigError("COSMOS_KEY is required")
        if not self.phi4_base_url:
            raise ConfigError("PHI4_BASE_URL is required")


@lru_cache(maxsize=1)
def load_settings() -> Settings:
    key_vault_name = os.getenv("KEY_VAULT_NAME") or None

    # Resolve secrets with independent Key Vault secret names
    applicationinsights_connection_string = _resolve_secret(
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        os.getenv("APPINSIGHTS_AKV_SECRET_NAME", "appinsights-connection-string"),
        key_vault_name,
        secret_required=False,
    )

    cosmos_key = _resolve_secret(
        "COSMOS_KEY",
        os.getenv("COSMOS_KEY_AKV_SECRET_NAME", "cosmos-key"),
        key_vault_name,
        secret_required=True,
    )

    mcp_api_key = _resolve_secret(
        "MCP_API_KEY",
        os.getenv("MCP_API_KEY_AKV_SECRET_NAME", "mcp-api-key"),
        key_vault_name,
        secret_required=False,
    )

    settings = Settings(
        service_name=_env("SERVICE_NAME", "agent-brain"),
        service_version=_env("SERVICE_VERSION", "1.0.0"),
        environment=_env("ENVIRONMENT", "production").lower(),
        log_level=_env("LOG_LEVEL", "INFO").upper(),
        port=_env_int("PORT", 8000),
        mcp_tools_url=_env("MCP_TOOLS_URL", "http://localhost:8000/mcp"),
        cosmos_endpoint=_env("COSMOS_ENDPOINT"),
        cosmos_key=cosmos_key,
        cosmos_database=_env("COSMOS_DATABASE", "agent_state_db"),
        cosmos_container=_env("COSMOS_CONTAINER", "checkpoints"),
        rate_limit_container=_env("RATE_LIMIT_CONTAINER", "rate_limits"),
        rate_limit_threshold=_env_int("RATE_LIMIT_THRESHOLD", 10),
        rate_limit_window_minutes=_env_int("RATE_LIMIT_WINDOW_MINUTES", 60),
        rate_limit_ttl_seconds=_env_int("RATE_LIMIT_TTL_SECONDS", 7200),
        applicationinsights_connection_string=applicationinsights_connection_string,
        enable_live_metrics=_truthy(os.getenv("AZURE_MONITOR_ENABLE_LIVE_METRICS", "true")),
        cohere_base_url=_env("COHERE_BASE_URL", "https://api.cohere.ai/compatibility/v1"),
        cohere_model=_env("COHERE_MODEL", "command-a-plus-05-2026"),
        phi4_base_url=_env("PHI4_BASE_URL"),
        phi4_model=_env("PHI4_MODEL", "phi-4-reasoning"),
        github_repo=_env("GITHUB_REPO", _env("GITHUB_REPOSITORY", "")),
        wait_after_deploy_seconds=_env_int("WAIT_AFTER_DEPLOY_SECONDS", 30),
        max_retries=_env_int("MAX_RETRIES", 3),
        human_approval_timeout_seconds=_env_int("HUMAN_APPROVAL_TIMEOUT_SECONDS", 3600),
        request_timeout_seconds=_env_float("REQUEST_TIMEOUT_SECONDS", 30.0),
        query_limit=_env_int("QUERY_LIMIT", 25),
        mcp_api_key=mcp_api_key,
        require_auth=_truthy(os.getenv("REQUIRE_AUTH")),
        key_vault_name=key_vault_name,
    )
    settings.preflight()
    return settings


__all__ = ["Settings", "ConfigError", "load_settings"]
