"""
Unit tests for configuration loading and validation.

Tests that:
1. Config loads correctly when all env vars are present
2. Config fails loudly when required env vars are missing
3. Type coercion works correctly (port validation, header parsing)
4. Validation rules are enforced (risk tier bounds, port ranges)
5. DSN construction from discrete Postgres vars works correctly

An autouse fixture wipes all known config env vars before each test to
guarantee isolation from any caller-exported env vars (e.g. ci.sh).
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from autosre.config import (
    AlertConfig,
    LLMConfig,
    OpenObserveConfig,
    OTelConfig,
    PostgresConfig,
    SafetyConfig,
    get_settings,
)

# Every env var the config module reads. The autouse fixture wipes all of them
# before each test so caller-exported vars (e.g. ci.sh) cannot leak in.
_ALL_KNOWN_VARS: list[str] = [
    # LLM
    "LLM_API_KEY",
    "LLM_BASE_URL",
    "LLM_PROVIDER",
    "LLM_MODEL_COORDINATOR",
    "LLM_MODEL_WORKER",
    # Postgres
    "POSTGRES_HOST",
    "POSTGRES_PORT",
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    # OpenObserve
    "OPENOBSERVE_EMAIL",
    "OPENOBSERVE_PASSWORD",
    "OPENOBSERVE_URL",
    # OTel
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_SERVICE_NAME",
    "OTEL_EXPORTER_HEADERS",
    # Safety
    "MAX_RISK_TIER_AUTONOMOUS",
    "MAX_ACTIONS_PER_INCIDENT",
    "MAX_WALL_CLOCK_SECONDS",
    # Alert
    "ALERT_WEBHOOK_SECRET",
    # Meta
    "DEPLOYMENT_ENVIRONMENT",
]


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Wipe all known config env vars before each test for isolation."""
    for var in _ALL_KNOWN_VARS:
        monkeypatch.delenv(var, raising=False)


def _set_minimum_settings_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Set the minimum env vars required for get_settings() to succeed."""
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
    monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
    monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
    monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "secret-123")


# ===========================================================================
# LLMConfig
# ===========================================================================
class TestLLMConfig:
    """Tests for LLM configuration."""

    def test_loads_with_required_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("LLM_API_KEY", "test-key-12345")

        config = LLMConfig()

        assert config.api_key.get_secret_value() == "test-key-12345"
        assert config.base_url == "https://api.groq.com/openai/v1"
        assert config.provider == "groq"
        assert config.model_coordinator == "qwen/qwen3.8-27b"
        assert config.model_worker == "openai/gpt-oss-20b"

    def test_fails_without_api_key(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            LLMConfig()

        errors = exc_info.value.errors()
        assert any(err["loc"] == ("api_key",) for err in errors)

    def test_custom_model_names(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("LLM_MODEL_COORDINATOR", "anthropic/claude-3-sonnet")
        monkeypatch.setenv("LLM_MODEL_WORKER", "openai/gpt-4o-mini")

        config = LLMConfig()

        assert config.model_coordinator == "anthropic/claude-3-sonnet"
        assert config.model_worker == "openai/gpt-4o-mini"

    def test_custom_base_url(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("LLM_BASE_URL", "http://localhost:8000/v1")

        config = LLMConfig()

        assert config.base_url == "http://localhost:8000/v1"


# ===========================================================================
# PostgresConfig
# ===========================================================================
class TestPostgresConfig:
    """Tests for PostgreSQL configuration."""

    def test_loads_with_required_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")

        config = PostgresConfig()

        assert config.host == "localhost"
        assert config.port == 5432
        assert config.db == "autosre_state"
        assert config.user == "autosre_agent"
        assert config.password.get_secret_value() == "test-pass"

    def test_dsn_construction(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_HOST", "postgres.rivulet.svc")
        monkeypatch.setenv("POSTGRES_PORT", "5432")
        monkeypatch.setenv("POSTGRES_DB", "app")
        monkeypatch.setenv("POSTGRES_USER", "app")
        monkeypatch.setenv("POSTGRES_PASSWORD", "StagingPostgresP123")

        config = PostgresConfig()

        expected = "postgresql://app:StagingPostgresP123@postgres.rivulet.svc:5432/app"
        assert config.dsn == expected

    def test_dsn_with_special_chars_in_password(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "p@ss:w0rd/test")

        config = PostgresConfig()

        assert "p@ss:w0rd/test" in config.dsn

    def test_fails_without_password(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            PostgresConfig()

        errors = exc_info.value.errors()
        assert any(err["loc"] == ("password",) for err in errors)

    def test_port_validation_too_high(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
        monkeypatch.setenv("POSTGRES_PORT", "99999")

        with pytest.raises(ValidationError):
            PostgresConfig()

    def test_port_validation_too_low(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
        monkeypatch.setenv("POSTGRES_PORT", "0")

        with pytest.raises(ValidationError):
            PostgresConfig()

    def test_custom_host_and_db(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
        monkeypatch.setenv("POSTGRES_HOST", "db.example.com")
        monkeypatch.setenv("POSTGRES_DB", "myapp")

        config = PostgresConfig()

        assert config.host == "db.example.com"
        assert config.db == "myapp"


# ===========================================================================
# OpenObserveConfig
# ===========================================================================
class TestOpenObserveConfig:
    """Tests for OpenObserve configuration."""

    def test_loads_with_required_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
        monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")

        config = OpenObserveConfig()

        assert config.email == "reader@autosre.local"
        assert config.password.get_secret_value() == "test-pass"
        assert config.url == "http://openobserve.openobserve.svc:5080"

    def test_fails_without_email(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")

        with pytest.raises(ValidationError):
            OpenObserveConfig()

    def test_fails_without_password(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")

        with pytest.raises(ValidationError):
            OpenObserveConfig()

    def test_custom_url(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
        monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
        monkeypatch.setenv("OPENOBSERVE_URL", "http://custom-o2:9000")

        config = OpenObserveConfig()

        assert config.url == "http://custom-o2:9000"


# ===========================================================================
# OTelConfig
# ===========================================================================
class TestOTelConfig:
    """Tests for OpenTelemetry configuration."""

    def test_loads_with_defaults(self) -> None:
        config = OTelConfig()

        assert config.service_name == "autosre-agent"
        assert config.exporter_otlp_endpoint == "http://otel-gateway.openobserve.svc:4318"
        assert config.exporter_headers == ""
        assert config.parsed_headers == {}

    def test_header_parsing_single(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "Authorization=Bearer token123")

        config = OTelConfig()

        assert config.exporter_headers == "Authorization=Bearer token123"
        assert config.parsed_headers == {"Authorization": "Bearer token123"}

    def test_header_parsing_multiple(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv(
            "OTEL_EXPORTER_HEADERS",
            "Authorization=Bearer token123,X-Custom=value,API-Key=secret",
        )

        config = OTelConfig()

        assert config.parsed_headers == {
            "Authorization": "Bearer token123",
            "X-Custom": "value",
            "API-Key": "secret",
        }

    def test_header_parsing_with_spaces(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "Authorization = Bearer token123")

        config = OTelConfig()

        assert config.parsed_headers == {"Authorization": "Bearer token123"}

    def test_empty_headers(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "")

        config = OTelConfig()

        # env_ignore_empty=True treats empty string as unset → default ""
        assert config.exporter_headers == ""
        assert config.parsed_headers == {}

    def test_custom_service_name(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("OTEL_SERVICE_NAME", "custom-agent")

        config = OTelConfig()

        assert config.service_name == "custom-agent"

    def test_malformed_pair_skipped(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A pair without '=' is silently skipped."""
        monkeypatch.setenv(
            "OTEL_EXPORTER_HEADERS",
            "Authorization=Bearer token123,badpair,X-Custom=value",
        )

        config = OTelConfig()

        assert config.parsed_headers == {
            "Authorization": "Bearer token123",
            "X-Custom": "value",
        }


# ===========================================================================
# SafetyConfig
# ===========================================================================
class TestSafetyConfig:
    """Tests for safety policy configuration."""

    def test_loads_with_defaults(self) -> None:
        config = SafetyConfig()

        assert config.max_risk_tier_autonomous == 1
        assert config.max_actions_per_incident == 10
        assert config.max_wall_clock_seconds == 600

    def test_risk_tier_validation_too_high(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_RISK_TIER_AUTONOMOUS", "5")

        with pytest.raises(ValidationError):
            SafetyConfig()

    def test_risk_tier_validation_negative(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_RISK_TIER_AUTONOMOUS", "-1")

        with pytest.raises(ValidationError):
            SafetyConfig()

    def test_actions_validation_too_low(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_ACTIONS_PER_INCIDENT", "0")

        with pytest.raises(ValidationError):
            SafetyConfig()

    def test_actions_validation_too_high(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_ACTIONS_PER_INCIDENT", "150")

        with pytest.raises(ValidationError):
            SafetyConfig()

    def test_wall_clock_validation_too_low(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_WALL_CLOCK_SECONDS", "30")

        with pytest.raises(ValidationError):
            SafetyConfig()

    def test_custom_safety_limits(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("MAX_RISK_TIER_AUTONOMOUS", "2")
        monkeypatch.setenv("MAX_ACTIONS_PER_INCIDENT", "20")
        monkeypatch.setenv("MAX_WALL_CLOCK_SECONDS", "900")

        config = SafetyConfig()

        assert config.max_risk_tier_autonomous == 2
        assert config.max_actions_per_incident == 20
        assert config.max_wall_clock_seconds == 900


# ===========================================================================
# AlertConfig
# ===========================================================================
class TestAlertConfig:
    """Tests for alert ingress configuration."""

    def test_loads_with_required_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "secret-123")

        config = AlertConfig()

        assert config.webhook_secret.get_secret_value() == "secret-123"

    def test_fails_without_secret(self) -> None:
        with pytest.raises(ValidationError):
            AlertConfig()


# ===========================================================================
# Settings (integration)
# ===========================================================================
class TestSettings:
    """Integration tests for root Settings."""

    def test_loads_complete_config(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _set_minimum_settings_env(monkeypatch)

        settings = get_settings()

        assert settings.llm.api_key.get_secret_value() == "test-key"
        assert settings.postgres.password.get_secret_value() == "test-pass"
        assert settings.openobserve.email == "reader@autosre.local"
        assert settings.alert.webhook_secret.get_secret_value() == "secret-123"
        assert settings.deployment_environment == "development"

    def test_fails_on_missing_llm_key(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
        monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
        monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
        monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "secret-123")

        with pytest.raises(ValidationError):
            get_settings()

    def test_fails_on_missing_postgres_password(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("LLM_API_KEY", "test-key")
        monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
        monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
        monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "secret-123")

        with pytest.raises(ValidationError):
            get_settings()

    def test_deployment_environment_default(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _set_minimum_settings_env(monkeypatch)

        settings = get_settings()

        assert settings.deployment_environment == "development"

    def test_deployment_environment_override(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _set_minimum_settings_env(monkeypatch)
        monkeypatch.setenv("DEPLOYMENT_ENVIRONMENT", "staging")

        settings = get_settings()

        assert settings.deployment_environment == "staging"

    def test_extra_env_vars_ignored(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _set_minimum_settings_env(monkeypatch)
        monkeypatch.setenv("UNKNOWN_VAR", "some-value")

        settings = get_settings()

        assert settings is not None

    def test_otel_headers_property_propagates(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _set_minimum_settings_env(monkeypatch)
        monkeypatch.setenv("OTEL_EXPORTER_HEADERS", "Authorization=Bearer abc,X-Key=xyz")

        settings = get_settings()

        assert settings.otel.parsed_headers == {
            "Authorization": "Bearer abc",
            "X-Key": "xyz",
        }
