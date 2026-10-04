"""Configuration models for AutoSRE using Pydantic Settings.

## Environment convention

    AUTOSRE_<SECTION>__<FIELD>       (double underscore = nested delimiter)

Section prefixes:
    AUTOSRE_LLM__                    LLMConfig
    AUTOSRE_EVAL__                   EvalConfig
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

## Provider-agnostic model naming

Model IDs use the LiteLLM canonical form: ``<provider>/<model>``.

    gemini/gemini-3.8-flash
    openai/gpt-4o-mini
    anthropic/claude-3-5-sonnet

The application passes these strings through to LiteLLM without
modification. LiteLLM infers the provider from the prefix and routes
to the correct endpoint. Do not set ``base_url`` unless you are routing
through a LiteLLM proxy or a self-hosted gateway.

## Deployment environment sync

Two fields carry the deployment environment:

    Settings.deployment_environment         top-level, read by telemetry
    OTelConfig.deployment_environment       nested, read by OTel exporters

A model_validator keeps them in sync.

## Cost defaults

Per-1K-token rates default to 0.0 to reflect free-tier usage. Override
via AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR etc. when using a paid
tier or a different provider. The evaluation harness uses the
configured values to project production costs.
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
    """LLM provider and per-model pricing.

    Provider-agnostic: the model ID carries the provider prefix
    (e.g. ``gemini/gemini-3.8-flash``) and LiteLLM routes accordingly.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_LLM__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    api_key: SecretStr = Field(
        ...,
        description="API key for the LLM provider",
    )
    base_url: str | None = Field(
        default=None,
        description=(
            "Optional base URL override for LiteLLM proxy or self-hosted "
            "gateway. Leave unset for standard provider endpoints."
        ),
    )

    model_coordinator: str = Field(
        default="gemini/gemini-3.8-flash",
        description="Fast model for coordinator-tier calls (triage, propose)",
    )
    model_worker: str = Field(
        default="gemini/gemini-3.8-flash",
        description="Heavy-context model for worker-tier calls (investigate, hypothesize)",
    )

    # Per-1K-token pricing. Defaults to 0.0 for free-tier usage.
    # Override via env vars when using a paid tier.
    input_cost_per_1k_coordinator: float = Field(
        default=0.0,
        ge=0.0,
        description="USD per 1K input tokens on the coordinator model",
    )
    output_cost_per_1k_coordinator: float = Field(
        default=0.0,
        ge=0.0,
        description="USD per 1K output tokens on the coordinator model",
    )
    input_cost_per_1k_worker: float = Field(
        default=0.0,
        ge=0.0,
        description="USD per 1K input tokens on the worker model",
    )
    output_cost_per_1k_worker: float = Field(
        default=0.0,
        ge=0.0,
        description="USD per 1K output tokens on the worker model",
    )

    # Retry and backoff configuration.
    max_retries: int = Field(
        default=5,
        ge=0,
        le=20,
        description="Maximum retry attempts per LLM call on transient errors",
    )
    initial_backoff_seconds: float = Field(
        default=2.0,
        ge=0.1,
        le=60.0,
        description="Starting backoff interval for exponential retry",
    )
    max_backoff_seconds: float = Field(
        default=60.0,
        ge=1.0,
        le=600.0,
        description="Maximum backoff interval cap",
    )


# ---------------------------------------------------------------------------
# Eval judge
# ---------------------------------------------------------------------------


class EvalConfig(BaseSettings):
    """DeepEval judge configuration.

    The judge is a separate LiteLLM call from the agent's own LLM calls.
    It is constructed by DeepEval's LiteLLMModel and passed to LiteLLM.
    The model ID must use the canonical ``<provider>/<model>`` form.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_EVAL__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    judge_model: str = Field(
        default="gemini/gemini-3.5-flash-lite",
        description=(
            "LiteLLM model ID for the DeepEval judge. Defaults to "
            "gemini-3.5-flash-lite (500 RPD free tier) to avoid competing "
            "with the agent for the gemini-3.8-flash quota (20 RPD)."
        ),
    )
    judge_base_url: str | None = Field(
        default=None,
        description=(
            "Optional base URL override for the judge endpoint. "
            "Environment: AUTOSRE_EVAL__JUDGE_BASE_URL"
        ),
    )
    judge_api_key: SecretStr | None = Field(
        default=None,
        description=(
            "Judge API key. When unset, settings.llm.api_key is used. "
            "Environment: AUTOSRE_EVAL__JUDGE_API_KEY"
        ),
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
        """URL-encode the password for embedding in a DSN."""
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
    """OpenObserve credentials and endpoint."""

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
        description="OTel deployment.environment.name resource attribute",
    )
    exporter_headers: str = Field(
        default="",
        description="OTLP headers as comma-separated key=value pairs",
    )

    @property
    def parsed_headers(self) -> dict[str, str]:
        """Parse ``exporter_headers`` into a dict."""
        if not self.exporter_headers:
            return {}

        headers: dict[str, str] = {}
        for pair in self.exporter_headers.split(","):
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = value.strip()
        return headers


# ---------------------------------------------------------------------------
# Safety limits and agent behaviour thresholds
# ---------------------------------------------------------------------------


class SafetyConfig(BaseSettings):
    """Graph-level safety limits and investigation-control thresholds.

    All thresholds are configurable via ``AUTOSRE_SAFETY__*`` env vars.
    Defaults are tuned for demo incidents (intentionally triggered with
    clear signals). For production, raise confidence thresholds.
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_SAFETY__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    # -- Policy enforcement -------------------------------------------------

    max_risk_tier_autonomous: int = Field(
        default=1,
        ge=0,
        le=4,
        description="Maximum risk tier executable without HITL approval",
    )
    max_actions_per_incident: int = Field(
        default=10,
        ge=1,
        lt=100,
        description="Maximum number of executed remediation actions per incident",
    )
    max_wall_clock_seconds: int = Field(
        default=600,
        ge=60,
        le=3600,
        description="Hard wall-clock budget per incident, in seconds",
    )

    # -- Investigation loop control ----------------------------------------

    initial_iteration_budget: int = Field(
        default=3,
        ge=1,
        le=10,
        description=(
            "Starting iteration budget for the investigate/hypothesize loop. "
            "Each loop iteration decrements this; when it hits 0 the agent "
            "must decide (propose if confident, no_action otherwise)."
        ),
    )
    stagnation_limit: int = Field(
        default=2,
        ge=1,
        le=5,
        description=(
            "Maximum consecutive stagnant rounds (confidence improvement "
            "below min_confidence_improvement) before forcing a decision."
        ),
    )
    max_action_attempts: int = Field(
        default=2,
        ge=1,
        le=5,
        description=(
            "Maximum times the agent can attempt to propose a remediation "
            "action before completing with status=failed."
        ),
    )

    # -- Confidence thresholds ---------------------------------------------

    confidence_propose: float = Field(
        default=0.55,
        ge=0.0,
        le=1.0,
        description=(
            "Minimum hypothesis confidence to propose a remediation action. "
            "Lowered from the prior 0.70 because demo incidents have clear "
            "deterministic signals; raise to 0.70+ for production."
        ),
    )
    confidence_fast_path: float = Field(
        default=0.80,
        ge=0.0,
        le=1.0,
        description=(
            "Confidence threshold to skip further investigation and proceed "
            "directly to propose. Only triggered on iteration 1 with evidence "
            "from multiple independent tools."
        ),
    )
    confidence_give_up: float = Field(
        default=0.40,
        ge=0.0,
        le=1.0,
        description=(
            "Confidence below which the agent gives up after stagnation or "
            "budget exhaustion and completes with status=no_action."
        ),
    )
    min_confidence_improvement: float = Field(
        default=0.05,
        ge=0.0,
        le=0.5,
        description=(
            "Minimum confidence delta between hypothesize rounds to count as "
            "progress. Below this, stagnation_count increments."
        ),
    )

    # -- LLM call budget ----------------------------------------------------

    max_llm_calls_per_incident: int = Field(
        default=15,
        ge=1,
        le=100,
        description=(
            "Hard budget on LLM API calls per incident. The router raises "
            "LLMBudgetExhaustedError when this is exceeded, preventing "
            "runaway loops from burning through provider quotas."
        ),
    )


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------


class SlackConfig(BaseSettings):
    """Slack integration credentials, split by transport."""

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
        if not self.approver_user_ids:
            raise ValueError(
                "Slack is enabled but approver_user_ids is empty; "
                "an unrestricted approval channel is unsafe"
            )
        return self


# ---------------------------------------------------------------------------
# Admin
# ---------------------------------------------------------------------------


class AdminConfig(BaseSettings):
    """Admin control-plane credentials."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_ADMIN__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    secret: SecretStr | None = Field(
        default=None,
        description="Bearer secret required by /admin/* endpoints",
    )


# ---------------------------------------------------------------------------
# Root Settings
# ---------------------------------------------------------------------------


class Settings(BaseSettings):
    """Aggregated application settings."""

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_",
        env_nested_delimiter="__",
        extra="ignore",
        case_sensitive=False,
    )

    llm: LLMConfig = Field(default_factory=LLMConfig)
    eval: EvalConfig = Field(default_factory=EvalConfig)
    postgres: PostgresConfig = Field(default_factory=PostgresConfig)
    alert: AlertConfig = Field(default_factory=AlertConfig)
    openobserve: OpenObserveConfig = Field(default_factory=OpenObserveConfig)
    otel: OTelConfig = Field(default_factory=OTelConfig)
    safety: SafetyConfig = Field(default_factory=SafetyConfig)
    slack: SlackConfig = Field(default_factory=SlackConfig)
    admin: AdminConfig = Field(default_factory=AdminConfig)

    deployment_environment: str = Field(
        default=_DEFAULT_DEPLOYMENT_ENVIRONMENT,
        description="Deployment environment name",
    )

    @model_validator(mode="after")
    def _sync_deployment_environment(self) -> Settings:
        """Keep the two deployment_environment fields consistent."""
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
    """Return the process-wide Settings singleton."""
    return Settings()


def reset_settings_cache() -> None:
    """Clear the settings cache. Required by test fixtures."""
    get_settings.cache_clear()


__all__ = [
    "AdminConfig",
    "AlertConfig",
    "EvalConfig",
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
