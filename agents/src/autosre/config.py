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
    AUTOSRE_<top_level>              Settings

Secrets use SecretStr so they never appear in logs, tracebacks, or reprs.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal
from urllib.parse import quote_plus

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_DEFAULT_DEPLOYMENT_ENVIRONMENT = "development"


# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------


class LLMConfig(BaseSettings):
    """LLM provider, per-model pricing, retry, and fallback rotation.

    Provider-agnostic: the model ID carries the provider prefix
    (e.g. ``gemini/gemini-3.8-flash``) and LiteLLM routes accordingly.

    Error classification:
        Every LLM error is classified into one of five categories:
        QUOTA_EXHAUSTED, CAPACITY_EXHAUSTED, TRANSIENT, AUTHENTICATION,
        VALIDATION. Patterns are case-insensitive regex substrings matched
        against the full error string.
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

    fallback_models: list[str] = Field(
        default_factory=lambda: [
            "gemini/gemini-3.5-flash-lite",
            "gemini/gemini-2.0-flash",
            "gemini/gemini-1.5-flash",
        ],
        description=(
            "Ordered list of fallback models. Router tries these when "
            "primary model hits quota or capacity."
        ),
    )

    # Per-1K-token pricing for paid tier projection.
    input_cost_per_1k_coordinator: float = Field(
        default=0.00075,
        ge=0.0,
        description="USD per 1K input tokens on coordinator model",
    )
    output_cost_per_1k_coordinator: float = Field(
        default=0.00375,
        ge=0.0,
        description="USD per 1K output tokens on coordinator model",
    )
    input_cost_per_1k_worker: float = Field(
        default=0.00075,
        ge=0.0,
        description="USD per 1K input tokens on worker model",
    )
    output_cost_per_1k_worker: float = Field(
        default=0.00375,
        ge=0.0,
        description="USD per 1K output tokens on worker model",
    )

    # Retry and backoff
    max_retries: int = Field(
        default=3,
        ge=0,
        le=20,
        description="Maximum retry attempts per LLM call on transient errors.",
    )
    initial_backoff_seconds: float = Field(
        default=1.0,
        ge=0.1,
        le=60.0,
        description="Starting backoff interval for exponential retry.",
    )
    max_backoff_seconds: float = Field(
        default=30.0,
        ge=1.0,
        le=600.0,
        description="Maximum backoff interval cap.",
    )
    absolute_backoff_cap_seconds: float = Field(
        default=30.0,
        ge=1.0,
        le=300.0,
        description="Hard ceiling on any single backoff sleep.",
    )

    # Circuit breaker
    circuit_breaker_enabled: bool = Field(
        default=True,
        description="Whether the circuit breaker is active.",
    )
    circuit_breaker_threshold: int = Field(
        default=5,
        ge=1,
        le=50,
        description="Failures within timeout window that open the circuit.",
    )
    circuit_breaker_timeout_seconds: float = Field(
        default=60.0,
        ge=10.0,
        le=1800.0,
        description="Sliding window (seconds) for counting failures.",
    )

    # Error classification patterns (regex, case-insensitive)
    quota_exhausted_patterns: list[str] = Field(
        default_factory=lambda: [
            r"quota exceeded",
            r"daily.*limit",
            r"\bRPD\b",
            r"requests per day",
            r"resource has been exhausted",
            r"exceeded your current quota",
            r"rate limit.*daily",
        ],
    )
    capacity_exhausted_patterns: list[str] = Field(
        default_factory=lambda: [
            r"high demand",
            r"\boverloaded\b",
            r"\bcapacity\b",
            r"try again later",
            r"temporarily unavailable",
        ],
    )
    authentication_patterns: list[str] = Field(
        default_factory=lambda: [
            r"invalid api key",
            r"permission denied",
            r"denied access",
            r"\bunauthorized\b",
            r"api key not valid",
            r"project has been denied",
        ],
    )


# ---------------------------------------------------------------------------
# Eval judge
# ---------------------------------------------------------------------------


class EvalConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_EVAL__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    judge_model: str = Field(default="gemini/gemini-3.5-flash-lite")
    judge_base_url: str | None = Field(default=None)
    judge_api_key: SecretStr | None = Field(default=None)


# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------


class PostgresConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_POSTGRES__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    password: SecretStr = Field(..., description="Database password")
    host: str = Field(default="localhost")
    port: int = Field(default=5432, ge=1, le=65535)
    db: str = Field(default="app")
    user: str = Field(default="app")

    def _encoded_password(self) -> str:
        return quote_plus(self.password.get_secret_value())

    @property
    def dsn(self) -> str:
        return (
            f"postgresql+psycopg://{self.user}:{self._encoded_password()}"
            f"@{self.host}:{self.port}/{self.db}"
        )

    @property
    def raw_dsn(self) -> str:
        return (
            f"postgresql://{self.user}:{self._encoded_password()}@{self.host}:{self.port}/{self.db}"
        )


# ---------------------------------------------------------------------------
# Alert webhook
# ---------------------------------------------------------------------------


class AlertConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_ALERT__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    webhook_secret: SecretStr = Field(...)


# ---------------------------------------------------------------------------
# OpenObserve
# ---------------------------------------------------------------------------


class OpenObserveConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_OPENOBSERVE__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    email: str = Field(...)
    password: SecretStr = Field(...)
    url: str = Field(default="http://localhost:5080")


# ---------------------------------------------------------------------------
# OpenTelemetry
# ---------------------------------------------------------------------------


class OTelConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_OTEL__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    exporter_otlp_endpoint: str = Field(default="http://localhost:4318")
    service_name: str = Field(default="autosre-agent")
    deployment_environment: str = Field(default=_DEFAULT_DEPLOYMENT_ENVIRONMENT)
    exporter_headers: str = Field(default="")

    @property
    def parsed_headers(self) -> dict[str, str]:
        if not self.exporter_headers:
            return {}
        headers: dict[str, str] = {}
        for pair in self.exporter_headers.split(","):
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = value.strip()
        return headers


# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------


class SafetyConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_SAFETY__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    max_risk_tier_autonomous: int = Field(default=1, ge=0, le=4)
    max_actions_per_incident: int = Field(default=10, ge=1, lt=100)
    max_wall_clock_seconds: int = Field(default=600, ge=60, le=3600)
    initial_iteration_budget: int = Field(default=3, ge=1, le=10)
    stagnation_limit: int = Field(default=2, ge=1, le=5)
    max_action_attempts: int = Field(default=2, ge=1, le=5)
    confidence_propose: float = Field(default=0.55, ge=0.0, le=1.0)
    confidence_fast_path: float = Field(default=0.80, ge=0.0, le=1.0)
    confidence_give_up: float = Field(default=0.40, ge=0.0, le=1.0)
    min_confidence_improvement: float = Field(default=0.05, ge=0.0, le=0.5)
    max_llm_calls_per_incident: int = Field(default=15, ge=1, le=100)


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------


class SlackConfig(BaseSettings):
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
        if self.bot_token is None:
            return False
        if self.mode == "socket":
            return self.app_token is not None
        return self.signing_secret is not None

    @model_validator(mode="after")
    def _validate_mode_credentials(self) -> SlackConfig:
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
    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_ADMIN__",
        env_nested_delimiter="__",
        extra="ignore",
    )

    secret: SecretStr | None = Field(default=None)


# ---------------------------------------------------------------------------
# Root Settings
# ---------------------------------------------------------------------------


class Settings(BaseSettings):
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

    deployment_environment: str = Field(default=_DEFAULT_DEPLOYMENT_ENVIRONMENT)

    @model_validator(mode="after")
    def _sync_deployment_environment(self) -> Settings:
        top = self.deployment_environment
        otel = self.otel.deployment_environment
        if top != _DEFAULT_DEPLOYMENT_ENVIRONMENT:
            self.otel.deployment_environment = top
        elif otel != _DEFAULT_DEPLOYMENT_ENVIRONMENT:
            self.deployment_environment = otel
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


def reset_settings_cache() -> None:
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
