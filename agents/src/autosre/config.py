"""Configuration models for AutoSRE using Pydantic Settings.

## Environment convention

    AUTOSRE_<SECTION>__<FIELD>       (double underscore = nested delimiter)

Section prefixes:
    AUTOSRE_LLM__                    LLMConfig
    AUTOSRE_POSTGRES__               PostgresConfig
    AUTOSRE_ALERT__                  AlertConfig
    AUTOSRE_OPENOBSERVE__            OpenObserveConfig
    AUTOSRE_OTEL__                   OTelConfig
    AUTOSRE_SAFETY__                 SafetyConfig
    AUTOSRE_SLACK__                  SlackConfig
    AUTOSRE_ADMIN__                  AdminConfig
    AUTOSRE_<top_level>              Settings (e.g. AUTOSRE_DEPLOYMENT_ENVIRONMENT)

Secrets use SecretStr so they never appear in logs, tracebacks, or reprs.

## Required vs. optional

The following fields are REQUIRED (no default, raise ValidationError when
missing). Their absence fails fast at Settings() construction:

    AUTOSRE_LLM__API_KEY
    AUTOSRE_POSTGRES__PASSWORD
    AUTOSRE_ALERT__WEBHOOK_SECRET
    AUTOSRE_OPENOBSERVE__EMAIL
    AUTOSRE_OPENOBSERVE__PASSWORD

Everything else has a safe default.

## Deployment environment sync

Two fields carry the deployment environment:

    Settings.deployment_environment         top-level, read by telemetry
    OTelConfig.deployment_environment       nested, read by OTel exporters

A model_validator keeps them in sync. The rule is: an explicitly-set
value wins; an unset side (equal to "development") follows the set side.
This means either env var works:

    AUTOSRE_DEPLOYMENT_ENVIRONMENT=staging
    AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT=staging

## Cost defaults

Per-1K-token rates match Groq's public pricing for the default models.
Override via AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR etc. when using
a different provider.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal
from urllib.parse import quote_plus

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_DEFAULT_DEPLOYMENT_ENVIRONMENT = "development"

# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------


class LLMConfig(BaseSettings):
    """LLM provider and per-model pricing."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_LLM__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    api_key: SecretStr = Field(
        ...,
        description="API key for the LLM provider",
    )
    provider: str = Field(
        default="groq",
        description="Provider name (groq, openai, anthropic, ...)",
    )
    base_url: str = Field(
        default="https://api.groq.com/openai/v1",
        description="Base URL for the provider's OpenAI-compatible endpoint",
    )

    # Model identifiers. The router normalizes both forms at runtime:
    # a native Groq ID (openai/gpt-oss-20b) becomes groq/openai/gpt-oss-20b
    # for LiteLLM dispatch. Defaults match the canonical form the router
    # sends on the wire so logs are unambiguous.
    model_coordinator: str = Field(
        default="qwen/qwen3.8-27b",
        description="Fast model for coordinator-tier calls",
    )
    model_worker: str = Field(
        default="groq/openai/gpt-oss-20b",
        description="Heavy-context model for worker-tier calls",
    )

    # Per-1K-token pricing used by core.cost.calculate_cost.
    input_cost_per_1k_coordinator: float = Field(
        default=0.0008,
        ge=0.0,
        description="USD per 1K input tokens on the coordinator model",
    )
    output_cost_per_1k_coordinator: float = Field(
        default=0.004,
        ge=0.0,
        description="USD per 1K output tokens on the coordinator model",
    )
    input_cost_per_1k_worker: float = Field(
        default=0.000075,
        ge=0.0,
        description="USD per 1K input tokens on the worker model",
    )
    output_cost_per_1k_worker: float = Field(
        default=0.0003,
        ge=0.0,
        description="USD per 1K output tokens on the worker model",
    )


# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------


class PostgresConfig(BaseSettings):
    """PostgreSQL connection parameters."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_POSTGRES__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    # Required — no default. Fails fast if not provided.
    password: SecretStr = Field(
        ...,
        description="Database password",
    )

    host: str = Field(default="localhost", description="Database host")
    port: int = Field(
        default=5432,
        ge=1,
        le=65535,
        description="Database port",
    )
    db: str = Field(default="app", description="Database name")
    user: str = Field(default="app", description="Database user")

    def _encoded_password(self) -> str:
        """URL-encode the password for embedding in a DSN.

        Special characters (``@``, ``:``, ``/``, ``?``, ``#``) in a raw
        password would otherwise truncate or corrupt the DSN when the
        driver parses the userinfo section.
        """
        return quote_plus(self.password.get_secret_value())

    @property
    def dsn(self) -> str:
        """SQLAlchemy-compatible DSN using the psycopg (v3) driver."""
        return (
            f"postgresql+psycopg://{self.user}:{self._encoded_password()}"
            f"@{self.host}:{self.port}/{self.db}"
        )

    @property
    def raw_dsn(self) -> str:
        """Plain libpq DSN for psycopg, psycopg_pool, and AsyncPostgresSaver."""
        return (
            f"postgresql://{self.user}:{self._encoded_password()}@{self.host}:{self.port}/{self.db}"
        )


# ---------------------------------------------------------------------------
# Alert webhook
# ---------------------------------------------------------------------------


class AlertConfig(BaseSettings):
    """HMAC signing secret for webhook ingress."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_ALERT__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    webhook_secret: SecretStr = Field(
        ...,
        description="HMAC-SHA256 secret for webhook signature verification",
    )


# ---------------------------------------------------------------------------
# OpenObserve
# ---------------------------------------------------------------------------


class OpenObserveConfig(BaseSettings):
    """OpenObserve credentials and endpoint.

    Both ``email`` and ``password`` are required because every OpenObserve
    API request uses Basic authentication. A service-account token can be
    used as the password.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_OPENOBSERVE__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    email: str = Field(
        ...,
        description="OpenObserve user email or service-account email",
    )
    password: SecretStr = Field(
        ...,
        description="OpenObserve user password or service-account token",
    )
    url: str = Field(
        default="http://localhost:5080",
        description="OpenObserve base URL",
    )


# ---------------------------------------------------------------------------
# OpenTelemetry
# ---------------------------------------------------------------------------


class OTelConfig(BaseSettings):
    """OpenTelemetry exporter configuration."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_OTEL__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    exporter_otlp_endpoint: str = Field(
        default="http://localhost:4318",
        description="OTLP/HTTP endpoint; /v1/traces is appended if absent",
    )
    service_name: str = Field(
        default="autosre-agent",
        description="OTel service.name resource attribute",
    )
    deployment_environment: str = Field(
        default=_DEFAULT_DEPLOYMENT_ENVIRONMENT,
        description=(
            "OTel deployment.environment.name resource attribute. Kept in "
            "sync with the top-level Settings.deployment_environment by a "
            "model validator."
        ),
    )

    # The field name is `exporter_headers` (not the OTel-canonical
    # `exporter_otlp_headers`) because this application scopes the field
    # under AUTOSRE_OTEL__; the OTLP endpoint is supplied separately.
    exporter_headers: str = Field(
        default="",
        description=(
            "OTLP headers as comma-separated key=value pairs. "
            "Format: 'key1=value1,key2=value2'. "
            "Environment: AUTOSRE_OTEL__EXPORTER_HEADERS"
        ),
    )

    @property
    def parsed_headers(self) -> dict[str, str]:
        """Parse ``exporter_headers`` into a dict.

        Format: ``key1=value1,key2=value2``. Malformed pairs (no ``=``)
        are silently skipped so a single bad entry does not crash
        exporter construction.
        """
        if not self.exporter_headers:
            return {}

        headers: dict[str, str] = {}
        for pair in self.exporter_headers.split(","):
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = value.strip()
        return headers


# ---------------------------------------------------------------------------
# Safety limits
# ---------------------------------------------------------------------------


class SafetyConfig(BaseSettings):
    """Graph-level safety limits.

    ``max_actions_per_incident`` is bounded by ``lt=100`` (exclusive):
    values 1-99 are accepted, 100 is not. The bound exists to reject
    typo-driven misconfigurations such as a digit accidentally added
    (10 -> 100).

    ``max_wall_clock_seconds`` is enforced by asyncio.wait_for in the
    runner. The bound 60-3600 excludes both accidentally short budgets
    (which would abort every incident) and accidentally long ones
    (which would let a stuck incident run unbounded).
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_SAFETY__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    max_risk_tier_autonomous: int = Field(
        default=1,
        ge=0,
        le=4,
        description="Maximum risk tier executable without HITL",
    )
    max_actions_per_incident: int = Field(
        default=10,
        ge=1,
        lt=100,
        description=("Maximum number of executed actions per incident (exclusive upper bound)"),
    )
    max_wall_clock_seconds: int = Field(
        default=600,
        ge=60,
        le=3600,
        description="Hard wall-clock budget per incident, in seconds",
    )


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------


class SlackConfig(BaseSettings):
    """Slack integration credentials, split by transport.

    Socket Mode:  bot_token + app_token. No signing_secret required.
    HTTP mode:    bot_token + signing_secret. No app_token required.

    The `mode` field selects which credential set is validated.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_SLACK__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    mode: Literal["socket", "http"] = Field(default="socket")
    bot_token: SecretStr | None = Field(default=None)
    app_token: SecretStr | None = Field(default=None)
    signing_secret: SecretStr | None = Field(default=None)
    approval_channel: str | None = Field(default=None)
    approver_user_ids: set[str] = Field(default_factory=set)

    @property
    def is_enabled(self) -> bool:
        """True when the selected transport has all required credentials."""
        if self.bot_token is None:
            return False
        if self.mode == "socket":
            return self.app_token is not None
        return self.signing_secret is not None

    @model_validator(mode="after")
    def _validate_mode_credentials(self) -> SlackConfig:
        """Reject half-configured states that would fail at runtime."""
        if self.bot_token is None:
            return self

        if self.mode == "socket" and self.app_token is None:
            raise ValueError("Slack mode=socket requires bot_token and app_token")
        if self.mode == "http" and self.signing_secret is None:
            raise ValueError("Slack mode=http requires bot_token and signing_secret")
        return self


# ---------------------------------------------------------------------------
# Admin
# ---------------------------------------------------------------------------


class AdminConfig(BaseSettings):
    """Admin control-plane credentials.

    When ``secret`` is unset, ``/admin/*`` endpoints return 503. This is
    the fail-safe default: an operator who forgets to set the secret
    cannot accidentally expose pause/resume controls.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_ADMIN__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    secret: SecretStr | None = Field(
        default=None,
        description=(
            "Bearer secret required by /admin/* endpoints. Unset disables "
            "them. Environment: AUTOSRE_ADMIN__SECRET"
        ),
    )


# ---------------------------------------------------------------------------
# Root Settings
# ---------------------------------------------------------------------------


class Settings(BaseSettings):
    """Aggregated application settings.

    Constructs every nested config from AUTOSRE_* environment variables.
    Missing required fields raise ValidationError at construction.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_",
        env_nested_delimiter="__",
        extra="ignore",
        case_sensitive=False,
    )

    llm: LLMConfig = Field(default_factory=LLMConfig)
    postgres: PostgresConfig = Field(default_factory=PostgresConfig)
    alert: AlertConfig = Field(default_factory=AlertConfig)
    openobserve: OpenObserveConfig = Field(default_factory=OpenObserveConfig)
    otel: OTelConfig = Field(default_factory=OTelConfig)
    safety: SafetyConfig = Field(default_factory=SafetyConfig)
    slack: SlackConfig = Field(default_factory=SlackConfig)
    admin: AdminConfig = Field(default_factory=AdminConfig)

    # Top-level deployment environment. Read by telemetry/otel.py to set
    # the OTel resource attribute. Kept in sync with the nested field on
    # OTelConfig by the model validator below.
    deployment_environment: str = Field(
        default=_DEFAULT_DEPLOYMENT_ENVIRONMENT,
        description=(
            "Deployment environment name. Either this field "
            "(AUTOSRE_DEPLOYMENT_ENVIRONMENT) or the nested field "
            "(AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT) may be set; both "
            "converge to the same value."
        ),
    )

    @model_validator(mode="after")
    def _sync_deployment_environment(self) -> Settings:
        """Keep the two deployment_environment fields consistent.

        Precedence:
            * If the top-level field is explicitly set (non-default),
              the nested field is overwritten to match.
            * Otherwise, if the nested field is explicitly set, the
              top-level field is overwritten to match.
            * If both are at the default, no change is made.

        Mutates ``self`` in place. Both fields remain independently
        readable; downstream code can use either.
        """
        top = self.deployment_environment
        otel = self.otel.deployment_environment

        if top != _DEFAULT_DEPLOYMENT_ENVIRONMENT:
            self.otel.deployment_environment = top
        elif otel != _DEFAULT_DEPLOYMENT_ENVIRONMENT:
            self.deployment_environment = otel

        return self


# ---------------------------------------------------------------------------
# Singleton access
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process-wide Settings singleton.

    Cached so env-var reads happen once. Tests must call
    ``reset_settings_cache()`` after monkeypatching env vars.
    """
    return Settings()


def reset_settings_cache() -> None:
    """Clear the settings cache.

    Required by test fixtures that monkeypatch AUTOSRE_* env vars.
    Without this call, ``get_settings()`` returns the stale instance
    constructed with the pre-monkeypatch environment.
    """
    get_settings.cache_clear()


__all__ = [
    "AdminConfig",
    "AlertConfig",
    "LLMConfig",
    "OTelConfig",
    "OpenObserveConfig",
    "PostgresConfig",
    "SafetyConfig",
    "Settings",
    "SlackConfig",
    "get_settings",
    "reset_settings_cache",
]
