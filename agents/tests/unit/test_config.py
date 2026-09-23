"""Unit tests for autosre.config module.

Every test in this module is isolated from the host environment:
an autouse fixture strips all AUTOSRE_* variables before each test
and restores them afterward. This prevents env leakage from the
developer shell or CI pipeline.
"""

from __future__ import annotations

import os

import pytest
from pydantic import ValidationError

from autosre.config import (
    AlertConfig,
    LLMConfig,
    OpenObserveConfig,
    OTelConfig,
    PostgresConfig,
    SafetyConfig,
    Settings,
    SlackConfig,
    reset_settings_cache,
)

# ---------------------------------------------------------------------------
# Environment isolation fixture
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _isolate_autosre_env() -> None:
    """Strip all AUTOSRE_* env vars before each test, restore after."""
    saved: dict[str, str] = {}
    to_remove: list[str] = []

    for key in list(os.environ):
        if key.startswith("AUTOSRE_"):
            saved[key] = os.environ[key]
            to_remove.append(key)

    for key in to_remove:
        del os.environ[key]

    reset_settings_cache()

    yield

    # Restore original environment
    for key in to_remove:
        if key in os.environ:
            del os.environ[key]

    for key, value in saved.items():
        os.environ[key] = value

    reset_settings_cache()


# ===========================================================================
# LLMConfig
# ===========================================================================


class TestLLMConfig:
    def test_loads_with_required_vars(self) -> None:
        config = LLMConfig(api_key="test-key-12345")

        assert config.api_key.get_secret_value() == "test-key-12345"
        assert config.base_url == "https://api.groq.com/openai/v1"
        assert config.provider == "groq"
        assert config.model_coordinator == "qwen/qwen3.8-27b"
        assert config.model_worker == "groq/openai/gpt-oss-20b"

    def test_fails_without_api_key(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            LLMConfig()  # type: ignore[call-arg]

        errors = exc_info.value.errors()
        field_names = [e["loc"][0] for e in errors]
        assert "api_key" in field_names

    def test_custom_model_names(self) -> None:
        config = LLMConfig(
            api_key="key",
            model_coordinator="anthropic/claude-3-sonnet",
            model_worker="openai/gpt-4o-mini",
        )

        assert config.model_coordinator == "anthropic/claude-3-sonnet"
        assert config.model_worker == "openai/gpt-4o-mini"

    def test_custom_base_url(self) -> None:
        config = LLMConfig(
            api_key="key",
            base_url="http://localhost:8000/v1",
        )

        assert config.base_url == "http://localhost:8000/v1"

    def test_cost_defaults(self) -> None:
        config = LLMConfig(api_key="key")

        assert config.input_cost_per_1k_coordinator == 0.0008
        assert config.output_cost_per_1k_coordinator == 0.004
        assert config.input_cost_per_1k_worker == 0.000075
        assert config.output_cost_per_1k_worker == 0.0003


# ===========================================================================
# PostgresConfig
# ===========================================================================


class TestPostgresConfig:
    def test_loads_with_required_vars(self) -> None:
        config = PostgresConfig(password="test-pass")

        assert config.host == "localhost"
        assert config.port == 5432
        assert config.db == "app"
        assert config.user == "app"
        assert config.password.get_secret_value() == "test-pass"

    def test_custom_host_and_db(self) -> None:
        config = PostgresConfig(
            host="db.example.com",
            db="autosre_state",
            password="pass",
        )

        assert config.host == "db.example.com"
        assert config.db == "autosre_state"

    def test_dsn_construction(self) -> None:
        config = PostgresConfig(
            host="postgres.rivulet.svc",
            user="app",
            password="StagingPostgresP123",
            db="app",
        )

        expected = "postgresql+psycopg://app:StagingPostgresP123@postgres.rivulet.svc:5432/app"
        assert config.dsn == expected

    def test_raw_dsn_construction(self) -> None:
        config = PostgresConfig(
            host="localhost",
            user="app",
            password="pass",
            db="app",
        )

        assert config.raw_dsn == "postgresql://app:pass@localhost:5432/app"

    def test_dsn_with_special_chars_in_password(self) -> None:
        """Special chars in password must be URL-encoded in the DSN."""
        config = PostgresConfig(password="p@ss:w0rd/test")

        # quote_plus encodes @ as %40, : as %3A, / as %2F
        assert "p%40ss%3Aw0rd%2Ftest" in config.dsn
        assert "@" not in config.dsn.split("://")[1].split("@")[0]

    def test_fails_without_password(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            PostgresConfig()  # type: ignore[call-arg]

        errors = exc_info.value.errors()
        field_names = [e["loc"][0] for e in errors]
        assert "password" in field_names

    def test_port_validation_too_high(self) -> None:
        with pytest.raises(ValidationError):
            PostgresConfig(password="pass", port=70000)

    def test_port_validation_too_low(self) -> None:
        with pytest.raises(ValidationError):
            PostgresConfig(password="pass", port=0)


# ===========================================================================
# AlertConfig
# ===========================================================================


class TestAlertConfig:
    def test_loads_with_required_vars(self) -> None:
        config = AlertConfig(webhook_secret="secret-123")

        assert config.webhook_secret.get_secret_value() == "secret-123"

    def test_fails_without_secret(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            AlertConfig()  # type: ignore[call-arg]

        errors = exc_info.value.errors()
        field_names = [e["loc"][0] for e in errors]
        assert "webhook_secret" in field_names


# ===========================================================================
# OpenObserveConfig
# ===========================================================================


class TestOpenObserveConfig:
    def test_loads_with_required_vars(self) -> None:
        config = OpenObserveConfig(
            email="reader@autosre.local",
            password="reader-pass",
        )

        assert config.email == "reader@autosre.local"
        assert config.password.get_secret_value() == "reader-pass"
        assert config.url == "http://localhost:5080"

    def test_fails_without_email(self) -> None:
        with pytest.raises(ValidationError):
            OpenObserveConfig(password="pass")  # type: ignore[call-arg]

    def test_fails_without_password(self) -> None:
        with pytest.raises(ValidationError):
            OpenObserveConfig(email="a@b.com")  # type: ignore[call-arg]

    def test_custom_url(self) -> None:
        config = OpenObserveConfig(
            email="a@b.com",
            password="pass",
            url="http://custom-o2:9000",
        )

        assert config.url == "http://custom-o2:9000"


# ===========================================================================
# OTelConfig
# ===========================================================================


class TestOTelConfig:
    def test_loads_with_defaults(self) -> None:
        config = OTelConfig()

        assert config.exporter_otlp_endpoint == "http://localhost:4318"
        assert config.service_name == "autosre-agent"
        assert config.exporter_headers == ""
        assert config.parsed_headers == {}

    def test_header_parsing_single(self) -> None:
        config = OTelConfig(exporter_headers="Authorization=Bearer token123")

        assert config.exporter_headers == "Authorization=Bearer token123"
        assert config.parsed_headers == {"Authorization": "Bearer token123"}

    def test_header_parsing_multiple(self) -> None:
        config = OTelConfig(
            exporter_headers="Authorization=Bearer token123,X-Custom=value,API-Key=secret",
        )

        assert config.parsed_headers == {
            "Authorization": "Bearer token123",
            "X-Custom": "value",
            "API-Key": "secret",
        }

    def test_header_parsing_with_spaces(self) -> None:
        config = OTelConfig(
            exporter_headers=" Authorization = Bearer token123 ",
        )

        assert config.parsed_headers == {"Authorization": "Bearer token123"}

    def test_custom_service_name(self) -> None:
        config = OTelConfig(service_name="custom-agent")

        assert config.service_name == "custom-agent"

    def test_malformed_pair_skipped(self) -> None:
        config = OTelConfig(
            exporter_headers="Authorization=Bearer token123,malformed,X-Custom=value",
        )

        assert config.parsed_headers == {
            "Authorization": "Bearer token123",
            "X-Custom": "value",
        }

    def test_empty_headers(self) -> None:
        config = OTelConfig(exporter_headers="")

        assert config.parsed_headers == {}


# ===========================================================================
# SafetyConfig
# ===========================================================================


class TestSafetyConfig:
    def test_defaults(self) -> None:
        config = SafetyConfig()

        assert config.max_risk_tier_autonomous == 1
        assert config.max_actions_per_incident == 10
        assert config.max_wall_clock_seconds == 600

    def test_risk_tier_validation_too_high(self) -> None:
        with pytest.raises(ValidationError):
            SafetyConfig(max_risk_tier_autonomous=5)

    def test_risk_tier_validation_negative(self) -> None:
        with pytest.raises(ValidationError):
            SafetyConfig(max_risk_tier_autonomous=-1)

    def test_actions_validation_too_low(self) -> None:
        with pytest.raises(ValidationError):
            SafetyConfig(max_actions_per_incident=0)

    def test_actions_validation_too_high(self) -> None:
        with pytest.raises(ValidationError):
            SafetyConfig(max_actions_per_incident=100)

    def test_wall_clock_validation_too_low(self) -> None:
        with pytest.raises(ValidationError):
            SafetyConfig(max_wall_clock_seconds=10)

    def test_custom_safety_limits(self) -> None:
        config = SafetyConfig(
            max_risk_tier_autonomous=2,
            max_actions_per_incident=20,
            max_wall_clock_seconds=1200,
        )

        assert config.max_risk_tier_autonomous == 2
        assert config.max_actions_per_incident == 20
        assert config.max_wall_clock_seconds == 1200


# ===========================================================================
# SlackConfig
# ===========================================================================


class TestSlackConfig:
    def test_defaults_are_disabled(self) -> None:
        config = SlackConfig()

        assert config.bot_token is None
        assert config.signing_secret is None
        assert config.is_enabled is False

    def test_enabled_when_both_set(self) -> None:
        config = SlackConfig(
            bot_token="xoxb-test",
            signing_secret="sig-test",
        )

        assert config.is_enabled is True

    def test_not_enabled_with_only_token(self) -> None:
        config = SlackConfig(bot_token="xoxb-test")

        assert config.is_enabled is False


# ===========================================================================
# Settings (root)
# ===========================================================================


class TestSettings:
    def test_loads_complete_config(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "test-key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pg-pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "webhook-secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "admin@test.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "o2-pass")

        settings = Settings()

        assert settings.llm.api_key.get_secret_value() == "test-key"
        assert settings.postgres.password.get_secret_value() == "pg-pass"
        assert settings.alert.webhook_secret.get_secret_value() == "webhook-secret"
        assert settings.openobserve.email == "admin@test.com"

    def test_fails_on_missing_llm_key(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pg-pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")
        # Deliberately NOT setting AUTOSRE_LLM__API_KEY

        with pytest.raises(ValidationError):
            Settings()

    def test_fails_on_missing_postgres_password(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")
        # Deliberately NOT setting AUTOSRE_POSTGRES__PASSWORD

        with pytest.raises(ValidationError):
            Settings()

    def test_deployment_environment_default(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")

        settings = Settings()

        assert settings.deployment_environment == "development"

    def test_deployment_environment_override(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_DEPLOYMENT_ENVIRONMENT", "staging")

        settings = Settings()

        assert settings.deployment_environment == "staging"

    def test_nested_env_delimiter(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """AUTOSRE_LLM__MODEL_COORDINATOR maps to settings.llm.model_coordinator."""
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_LLM__MODEL_COORDINATOR", "custom/model")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")

        settings = Settings()

        assert settings.llm.model_coordinator == "custom/model"

    def test_otel_headers_property_propagates(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")
        monkeypatch.setenv(
            "AUTOSRE_OTEL__EXPORTER_HEADERS",
            "Authorization=Bearer abc,X-Key=xyz",
        )

        settings = Settings()

        assert settings.otel.parsed_headers == {
            "Authorization": "Bearer abc",
            "X-Key": "xyz",
        }

    def test_safety_defaults_propagate(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "a@b.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "pass")
