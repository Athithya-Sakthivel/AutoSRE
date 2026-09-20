"""
Configuration management for AutoSRE Agent.

Loads environment variables using pydantic-settings v2 with strict validation.
All secrets use generic names (LLM_API_KEY, not GROQ_API_KEY) for provider-swappability.

Environment Variable Contract:
- Generic names allow swapping LLM providers without code changes
- Discrete variables (host, port, db, user, password) instead of derived URIs
- SecretStr for all sensitive values to prevent accidental logging
- env_ignore_empty=True so empty strings fall back to defaults
"""

from __future__ import annotations

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

# Shared base config: disable .env files, ignore unknown vars, treat empty
# env strings as unset so defaults apply. See pydantic-settings v2 docs.
_BASE_CONFIG = SettingsConfigDict(
    env_file=None,
    case_sensitive=False,
    extra="ignore",
    env_ignore_empty=True,
)


class LLMConfig(BaseSettings):
    """
    LLM provider configuration (provider-agnostic).

    Uses generic names so the same code works with Groq, OpenAI, Anthropic,
    or self-hosted vLLM by only changing environment variables.
    """

    model_config = SettingsConfigDict(env_prefix="LLM_", **_BASE_CONFIG)

    api_key: SecretStr = Field(
        description="API key for LLM provider (Groq, OpenAI, Anthropic, etc.)"
    )
    base_url: str = Field(
        default="https://api.groq.com/openai/v1",
        description="Base URL for LLM API",
    )
    provider: str = Field(
        default="groq",
        description="LLM provider name (for LiteLLM routing)",
    )
    model_coordinator: str = Field(
        default="qwen/qwen3.8-27b",
        description="Model for complex reasoning (high token budget, 70K TPM)",
    )
    model_worker: str = Field(
        default="openai/gpt-oss-20b",
        description="Model for fast triage and simple tasks (8K TPM)",
    )


class PostgresConfig(BaseSettings):
    """
    PostgreSQL connection configuration for agent's own state database.

    Uses discrete variables (not derived URIs) to avoid URL-encoding bugs
    when passwords contain special characters like @, :, or /.
    """

    model_config = SettingsConfigDict(env_prefix="POSTGRES_", **_BASE_CONFIG)

    host: str = Field(default="localhost", description="Postgres hostname")
    port: int = Field(default=5432, ge=1, le=65535, description="Postgres port")
    db: str = Field(default="autosre_state", description="Database name")
    user: str = Field(default="autosre_agent", description="Database user")
    password: SecretStr = Field(description="Database password")

    @property
    def dsn(self) -> str:
        """Construct PostgreSQL DSN from discrete variables."""
        return (
            f"postgresql://{self.user}:{self.password.get_secret_value()}"
            f"@{self.host}:{self.port}/{self.db}"
        )


class OpenObserveConfig(BaseSettings):
    """
    OpenObserve query credentials (read-only viewer).

    The agent queries OpenObserve to investigate incidents but never writes
    to it (telemetry export is handled by OTel instrumentation).
    """

    model_config = SettingsConfigDict(env_prefix="OPENOBSERVE_", **_BASE_CONFIG)

    email: str = Field(description="OpenObserve reader email")
    password: SecretStr = Field(description="OpenObserve reader password")
    url: str = Field(
        default="http://openobserve.openobserve.svc:5080",
        description="OpenObserve base URL",
    )


class OTelConfig(BaseSettings):
    """
    OpenTelemetry export configuration.

    The `exporter_headers` env var is stored as a raw comma-separated string
    (e.g. ``"Authorization=Bearer token,X-Custom=value"``) to avoid
    pydantic-settings v2's automatic JSON decoding of complex-typed fields.
    The parsed dict is exposed via the ``parsed_headers`` property.
    """

    model_config = SettingsConfigDict(env_prefix="OTEL_", **_BASE_CONFIG)

    exporter_otlp_endpoint: str = Field(
        default="http://otel-gateway.openobserve.svc:4318",
        description="OTLP HTTP endpoint",
    )
    service_name: str = Field(
        default="autosre-agent",
        description="Service name for traces",
    )
    # Stored as raw string — pydantic-settings v2 would otherwise attempt
    # json.loads() on complex types before validators run.
    exporter_headers: str = Field(
        default="",
        description="Comma-separated OTLP export headers (key=value,key2=value2)",
    )

    @property
    def parsed_headers(self) -> dict[str, str]:
        """
        Parse the raw header string into a dict.

        Input:  ``"Authorization=Bearer token,X-Custom=value"``
        Output: ``{"Authorization": "Bearer token", "X-Custom": "value"}``
        """
        if not self.exporter_headers:
            return {}

        headers: dict[str, str] = {}
        for pair in self.exporter_headers.split(","):
            pair = pair.strip()
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = value.strip()
        return headers


class SafetyConfig(BaseSettings):
    """
    Safety policy configuration.

    Controls autonomous execution limits and blast radius containment.
    """

    model_config = SettingsConfigDict(env_prefix="", **_BASE_CONFIG)

    max_risk_tier_autonomous: int = Field(
        default=1,
        ge=0,
        le=4,
        description="Maximum risk tier for autonomous execution (0=observe, 4=prohibited)",
    )
    max_actions_per_incident: int = Field(
        default=10,
        ge=1,
        le=100,
        description="Maximum actions per incident before escalation",
    )
    max_wall_clock_seconds: int = Field(
        default=600,
        ge=60,
        le=3600,
        description="Maximum investigation time in seconds (10 min default)",
    )


class AlertConfig(BaseSettings):
    """Alert ingress configuration."""

    model_config = SettingsConfigDict(env_prefix="ALERT_", **_BASE_CONFIG)

    webhook_secret: SecretStr = Field(
        description="Secret for validating webhook signatures (HMAC-SHA256)",
    )


class Settings(BaseSettings):
    """
    Root configuration aggregating all sub-configs.

    Explicitly disables .env file loading to enforce explicit env var exports.
    """

    model_config = SettingsConfigDict(
        env_file=None,
        case_sensitive=False,
        extra="ignore",
        env_ignore_empty=True,
    )

    llm: LLMConfig
    postgres: PostgresConfig
    openobserve: OpenObserveConfig
    otel: OTelConfig
    safety: SafetyConfig
    alert: AlertConfig

    deployment_environment: str = Field(
        default="development",
        alias="DEPLOYMENT_ENVIRONMENT",
        description="Deployment environment (development/staging/production)",
    )


def get_settings() -> Settings:
    """
    Load and validate settings from environment variables.

    Raises:
        pydantic.ValidationError: If required env vars are missing or invalid
    """
    return Settings(
        llm=LLMConfig(),
        postgres=PostgresConfig(),
        openobserve=OpenObserveConfig(),
        otel=OTelConfig(),
        safety=SafetyConfig(),
        alert=AlertConfig(),
    )
