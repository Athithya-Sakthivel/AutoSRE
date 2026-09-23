"""Application configuration via environment variables.

All settings are loaded from env vars with the ``AUTOSRE_`` prefix.
Nested configs use ``__`` as delimiter (e.g. ``AUTOSRE_LLM__API_KEY``
maps to ``settings.llm.api_key``).

Nested config classes inherit from BaseModel, not BaseSettings.
Only the root Settings class inherits from BaseSettings.
"""

from __future__ import annotations

from urllib.parse import quote_plus

from pydantic import BaseModel, Field, SecretStr, computed_field
from pydantic_settings import BaseSettings, SettingsConfigDict


class LLMConfig(BaseModel):
    """LLM provider configuration."""

    api_key: SecretStr = Field(description="Groq API key")
    base_url: str = Field(
        default="https://api.groq.com/openai/v1",
        description="LLM API base URL",
    )
    provider: str = Field(default="groq", description="LLM provider name")
    model_coordinator: str = Field(
        default="qwen/qwen3.8-27b",
        description="Fast model for coordination",
    )
    model_worker: str = Field(
        default="groq/openai/gpt-oss-20b",
        description="Fallback model for worker tasks",
    )
    input_cost_per_1k_coordinator: float = Field(
        default=0.0008,
        description="USD per 1K input tokens (coordinator)",
    )
    output_cost_per_1k_coordinator: float = Field(
        default=0.004,
        description="USD per 1K output tokens (coordinator)",
    )
    input_cost_per_1k_worker: float = Field(
        default=0.000075,
        description="USD per 1K input tokens (worker)",
    )
    output_cost_per_1k_worker: float = Field(
        default=0.0003,
        description="USD per 1K output tokens (worker)",
    )


class PostgresConfig(BaseModel):
    """PostgreSQL connection configuration."""

    host: str = Field(default="localhost")
    port: int = Field(default=5432, ge=1, le=65535)
    db: str = Field(default="app")
    user: str = Field(default="app")
    password: SecretStr = Field(description="PostgreSQL password")

    @computed_field  # type: ignore[prop-decorator]
    @property
    def dsn(self) -> str:
        """Build SQLAlchemy-compatible async DSN with URL-encoded password."""
        encoded_password = quote_plus(self.password.get_secret_value())
        return (
            f"postgresql+psycopg://{self.user}:{encoded_password}@{self.host}:{self.port}/{self.db}"
        )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def raw_dsn(self) -> str:
        """Build psycopg-compatible DSN (no +psycopg driver suffix)."""
        encoded_password = quote_plus(self.password.get_secret_value())
        return f"postgresql://{self.user}:{encoded_password}@{self.host}:{self.port}/{self.db}"


class AlertConfig(BaseModel):
    """Alert ingress configuration."""

    webhook_secret: SecretStr = Field(
        description="HMAC secret for webhook verification",
    )


class OpenObserveConfig(BaseModel):
    """OpenObserve observability platform configuration."""

    email: str = Field(description="OpenObserve login email")
    password: SecretStr = Field(description="OpenObserve login password")
    url: str = Field(
        default="http://localhost:5080",
        description="OpenObserve base URL",
    )


class OTelConfig(BaseModel):
    """OpenTelemetry exporter configuration."""

    exporter_otlp_endpoint: str = Field(
        default="http://localhost:4318",
        description="OTLP HTTP endpoint",
    )
    service_name: str = Field(
        default="autosre-agent",
        description="Service name for traces",
    )
    exporter_headers: str = Field(
        default="",
        description="Comma-separated key=value pairs for OTLP headers",
    )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def parsed_headers(self) -> dict[str, str]:
        """Parse comma-separated key=value pairs into OTLP headers."""
        if not self.exporter_headers.strip():
            return {}

        headers: dict[str, str] = {}

        for pair in self.exporter_headers.split(","):
            pair = pair.strip()
            if not pair or "=" not in pair:
                continue

            key, value = pair.split("=", 1)
            key = key.strip()
            value = value.strip()

            if key:
                headers[key] = value

        return headers


class SafetyConfig(BaseModel):
    """Safety policy configuration."""

    max_risk_tier_autonomous: int = Field(
        default=1,
        ge=0,
        le=3,
        description="Maximum risk tier allowed without human approval",
    )
    max_actions_per_incident: int = Field(
        default=10,
        ge=1,
        le=50,
        description="Maximum remediation actions per incident",
    )
    max_wall_clock_seconds: int = Field(
        default=600,
        ge=30,
        le=3600,
        description="Maximum investigation duration in seconds",
    )


class SlackConfig(BaseModel):
    """Slack bot configuration (optional)."""

    bot_token: SecretStr | None = Field(
        default=None,
        description="Slack bot OAuth token (xoxb-...)",
    )
    signing_secret: SecretStr | None = Field(
        default=None,
        description="Slack app signing secret",
    )
    approval_channel: str = Field(
        default="#sre-incidents",
        description="Slack channel for approval requests",
    )

    @property
    def is_enabled(self) -> bool:
        """Return whether Slack integration is fully configured."""
        return self.bot_token is not None and self.signing_secret is not None


class Settings(BaseSettings):
    """Root application settings.

    Env vars use ``AUTOSRE_`` prefix with ``__`` nested delimiter:
      AUTOSRE_LLM__API_KEY       → settings.llm.api_key
      AUTOSRE_POSTGRES__HOST     → settings.postgres.host
      AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS → settings.safety.max_risk_tier_autonomous
    """

    model_config = SettingsConfigDict(
        env_prefix="AUTOSRE_",
        env_nested_delimiter="__",
        case_sensitive=False,
    )

    deployment_environment: str = Field(
        default="development",
        description="Deployment environment name",
    )
    eval_max_cost_usd: float = Field(
        default=0.15,
        description="Maximum cost per incident for evaluation",
    )

    llm: LLMConfig
    postgres: PostgresConfig
    alert: AlertConfig
    openobserve: OpenObserveConfig
    otel: OTelConfig = Field(default_factory=OTelConfig)
    safety: SafetyConfig = Field(default_factory=SafetyConfig)
    slack: SlackConfig = Field(default_factory=SlackConfig)


_settings_cache: Settings | None = None


def get_settings() -> Settings:
    """Return cached Settings instance, creating it on first call."""
    global _settings_cache

    if _settings_cache is None:
        _settings_cache = Settings()

    return _settings_cache


def reset_settings_cache() -> None:
    """Reset the settings cache. Useful for testing."""
    global _settings_cache
    _settings_cache = None
