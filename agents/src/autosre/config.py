"""Configuration management for AutoSRE Agent."""

from __future__ import annotations

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

_BASE_CONFIG = SettingsConfigDict(
    env_file=None,
    case_sensitive=False,
    extra="ignore",
    env_ignore_empty=True,
)


class LLMConfig(BaseSettings):
    """LLM provider configuration with cost tracking."""

    model_config = SettingsConfigDict(env_prefix="LLM_", **_BASE_CONFIG)

    api_key: SecretStr = Field(description="API key for LLM provider")
    base_url: str = Field(default="https://api.groq.com/openai/v1")
    provider: str = Field(default="groq")
    model_coordinator: str = Field(
        default="qwen/qwen3.8-27b",
        description="Model for complex reasoning (high token budget, 70K TPM)",
    )
    model_worker: str = Field(
        default="openai/gpt-oss-20b",
        description="Model for fast triage and simple tasks (8K TPM)",
    )

    # Cost tracking (USD per 1000 tokens)
    # Groq pricing: GPT-OSS 20B = $0.075/$0.30, Qwen 3.8 27B = $0.80/$4.00
    input_cost_per_1k_coordinator: float = Field(
        default=0.000800,  # Qwen 3.8 27B: $0.80/1M = $0.000800/1K
        ge=0.0,
        description="Input cost per 1K tokens for coordinator model (USD)",
    )
    output_cost_per_1k_coordinator: float = Field(
        default=0.004000,  # Qwen 3.8 27B: $4.00/1M = $0.004000/1K
        ge=0.0,
        description="Output cost per 1K tokens for coordinator model (USD)",
    )
    input_cost_per_1k_worker: float = Field(
        default=0.000075,  # GPT-OSS 20B: $0.075/1M = $0.000075/1K
        ge=0.0,
        description="Input cost per 1K tokens for worker model (USD)",
    )
    output_cost_per_1k_worker: float = Field(
        default=0.000300,  # GPT-OSS 20B: $0.30/1M = $0.000300/1K
        ge=0.0,
        description="Output cost per 1K tokens for worker model (USD)",
    )


class PostgresConfig(BaseSettings):
    """PostgreSQL connection configuration."""

    model_config = SettingsConfigDict(env_prefix="POSTGRES_", **_BASE_CONFIG)

    host: str = Field(default="localhost")
    port: int = Field(default=5432, ge=1, le=65535)
    db: str = Field(default="autosre_state")
    user: str = Field(default="autosre_agent")
    password: SecretStr = Field(description="Database password")

    @property
    def dsn(self) -> str:
        return (
            f"postgresql://{self.user}:{self.password.get_secret_value()}"
            f"@{self.host}:{self.port}/{self.db}"
        )


class OpenObserveConfig(BaseSettings):
    """OpenObserve query credentials (read-only viewer)."""

    model_config = SettingsConfigDict(env_prefix="OPENOBSERVE_", **_BASE_CONFIG)

    email: str = Field(description="OpenObserve reader email")
    password: SecretStr = Field(description="OpenObserve reader password")
    url: str = Field(
        default="http://openobserve.openobserve.svc:5080",
        description="OpenObserve base URL",
    )


class OTelConfig(BaseSettings):
    """OpenTelemetry export configuration."""

    model_config = SettingsConfigDict(env_prefix="OTEL_", **_BASE_CONFIG)

    exporter_otlp_endpoint: str = Field(
        default="http://otel-gateway.openobserve.svc:4318",
    )
    service_name: str = Field(default="autosre-agent")
    exporter_headers: str = Field(
        default="",
        description="Comma-separated OTLP export headers (key=value,key2=value2)",
    )

    @property
    def parsed_headers(self) -> dict[str, str]:
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
    """Safety policy configuration."""

    model_config = SettingsConfigDict(env_prefix="", **_BASE_CONFIG)

    max_risk_tier_autonomous: int = Field(default=1, ge=0, le=4)
    max_actions_per_incident: int = Field(default=10, ge=1, le=100)
    max_wall_clock_seconds: int = Field(default=600, ge=60, le=3600)


class AlertConfig(BaseSettings):
    """Alert ingress configuration."""

    model_config = SettingsConfigDict(env_prefix="ALERT_", **_BASE_CONFIG)

    webhook_secret: SecretStr = Field(
        description="Secret for validating webhook signatures (HMAC-SHA256)",
    )


class Settings(BaseSettings):
    """Root configuration aggregating all sub-configs."""

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
    )

    eval_max_cost_usd: float = Field(
        default=0.15,
        ge=0.0,
        alias="EVAL_MAX_COST_USD",
        description="Maximum cost per incident in USD for eval assertions",
    )


def get_settings() -> Settings:
    """Load and validate settings from environment variables."""
    return Settings(
        llm=LLMConfig(),
        postgres=PostgresConfig(),
        openobserve=OpenObserveConfig(),
        otel=OTelConfig(),
        safety=SafetyConfig(),
        alert=AlertConfig(),
    )
