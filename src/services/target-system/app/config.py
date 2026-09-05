"""Configuration loading for target-system.

Loads Application Insights connection string from environment variables or
Azure Key Vault, and exposes sampling configuration for telemetry.

In non‑development environments, the service refuses to start if no connection
string is available — telemetry is mandatory.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Final

logger = logging.getLogger(__name__)

_DEFAULT_SECRET_NAMES: Final[tuple[str, ...]] = (
    "appinsights-connection-string",
    "applicationinsights-connection-string",
)


@dataclass(slots=True)
class Settings:
    """Resolved runtime settings."""

    app_name: str = "target-system"
    app_version: str = "1.0.0"
    environment: str = field(default_factory=lambda: os.getenv("ENVIRONMENT", "development"))
    key_vault_name: str | None = field(default_factory=lambda: os.getenv("KEY_VAULT_NAME") or None)
    key_vault_secret_name: str | None = field(
        default_factory=lambda: (
            os.getenv("KEY_VAULT_SECRET_NAME") or os.getenv("APPINSIGHTS_SECRET_NAME") or None
        )
    )
    appinsights_connection_string: str | None = None

    # -- Sampling configuration --------------------------------------------
    # OTEL_SAMPLING_MODE: "rate", "ratio", or "off" (default: "rate")
    sampling_mode: str = field(
        default_factory=lambda: os.getenv("OTEL_SAMPLING_MODE", "rate").lower()
    )
    # OTEL_TRACES_PER_SECOND: used when mode=rate (default: 5)
    traces_per_second: float = field(
        default_factory=lambda: float(os.getenv("OTEL_TRACES_PER_SECOND", "5"))
    )
    # OTEL_SAMPLING_RATIO: used when mode=ratio (default: 0.1)
    sampling_ratio: float = field(
        default_factory=lambda: float(os.getenv("OTEL_SAMPLING_RATIO", "0.1"))
    )
    # OTEL_ENABLE_LIVE_METRICS: enable Live Metrics stream (default: false)
    enable_live_metrics: bool = field(
        default_factory=lambda: (
            os.getenv("OTEL_ENABLE_LIVE_METRICS", "false").lower() in ("true", "1", "yes")
        )
    )
    # ----------------------------------------------------------------------

    @property
    def telemetry_enabled(self) -> bool:
        return bool(self.appinsights_connection_string)


class ConfigLoader:
    """Load settings once per process, with explicit refresh support."""

    def __init__(self) -> None:
        self._settings = self._load()

    @property
    def settings(self) -> Settings:
        return self._settings

    def refresh(self) -> Settings:
        self._settings = self._load()
        return self._settings

    def _load(self) -> Settings:
        settings = Settings()

        # First preference: explicit environment variable.
        env_conn = self._read_connection_string_from_env()
        if env_conn:
            settings.appinsights_connection_string = env_conn
            return settings

        # Second preference: Azure Key Vault when configured.
        if settings.key_vault_name:
            try:
                conn = self._read_connection_string_from_key_vault(
                    settings.key_vault_name,
                    settings.key_vault_secret_name,
                )
                if conn:
                    settings.appinsights_connection_string = conn
                    logger.info(
                        "Loaded Application Insights connection string from Azure Key Vault"
                    )
                    return settings
                logger.warning(
                    "Key Vault configured but no connection-string secret found; "
                    "falling back to environment variables"
                )
            except Exception:
                logger.exception("Key Vault lookup failed; falling back to environment variables")

        # ------------------------------------------------------------------
        # FAIL FAST in any environment that is not "development".
        # Telemetry is required for staging / production / testing.
        # ------------------------------------------------------------------
        if settings.environment != "development":
            raise RuntimeError(
                "Telemetry is required but no Application Insights connection "
                "string was found. Set APPLICATIONINSIGHTS_CONNECTION_STRING "
                "or KEY_VAULT_NAME."
            )

        # Development only: console fallback with a clear warning.
        logger.warning(
            "Telemetry is disabled. Set APPLICATIONINSIGHTS_CONNECTION_STRING "
            "or configure KEY_VAULT_NAME to enable Azure Monitor export."
        )
        return settings

    @staticmethod
    def _read_connection_string_from_env() -> str | None:
        for name in (
            "APPLICATIONINSIGHTS_CONNECTION_STRING",
            "APPINSIGHTS_CONNECTION_STRING",
        ):
            value = os.getenv(name)
            if value:
                return value.strip()
        return None

    @staticmethod
    def _read_connection_string_from_key_vault(
        key_vault_name: str,
        secret_name: str | None,
    ) -> str | None:
        try:
            from azure.identity import DefaultAzureCredential
            from azure.keyvault.secrets import SecretClient
        except Exception as exc:
            raise RuntimeError(
                "Azure Key Vault support requires azure-identity and azure-keyvault-secrets"
            ) from exc

        credential = DefaultAzureCredential()
        client = SecretClient(
            vault_url=f"https://{key_vault_name}.vault.azure.net",
            credential=credential,
        )

        candidates = (secret_name,) if secret_name else _DEFAULT_SECRET_NAMES
        for candidate in candidates:
            if not candidate:
                continue
            try:
                secret = client.get_secret(candidate)
            except Exception:
                continue
            if secret.value:
                return secret.value.strip()
        return None


config = ConfigLoader().settings
