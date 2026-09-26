"""Unit tests for autosre.config.

Every test is isolated from the host environment: an autouse fixture
strips AUTOSRE_* variables before each test and restores them after.
"""

from __future__ import annotations

import os

import pytest
from pydantic import ValidationError

from autosre.config import (
    AdminConfig,
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
# Environment isolation
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _isolate_autosre_env() -> None:
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

    for key in to_remove:
        if key in os.environ:
            del os.environ[key]

    for key, value in saved.items():
        os.environ[key] = value

    reset_settings_cache()


# ---------------------------------------------------------------------------
# LLMConfig
# ---------------------------------------------------------------------------


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
        assert any(e["loc"][0] == "api_key" for e in errors)

    def test_custom_model_names(self) -> None:
        config = LLMConfig(
            api_key="key",
            model_coordinator="anthropic/claude-3-sonnet",
            model_worker="openai/gpt-4o-mini",
        )
        assert config.model_coordinator == "anthropic/claude-3-sonnet"
        assert config.model_worker == "openai/gpt-4o-mini"

    def test_custom_base_url(self) -> None:
        config = LLMConfig(api_key="key", base_url="http://localhost:8000/v1")
        assert config.base_url == "http://localhost:8000/v1"

    def test_cost_defaults(self) -> None:
        config = LLMConfig(api_key="key")
        assert config.input_cost_per_1k_coordinator == 0.0008
        assert config.output_cost_per_1k_coordinator == 0.004
        assert config.input_cost_per_1k_worker == 0.000075
        assert config.output_cost_per_1k_worker == 0.0003


# ---------------------------------------------------------------------------
# PostgresConfig
# ---------------------------------------------------------------------------


class TestPostgresConfig:
    def test_loads_with_required_vars(self) -> None:
        config = PostgresConfig(password="test-pass")
        assert config.host == "localhost"
        assert config.port == 5432
        assert config.db == "app"
        assert config.user == "app"
        assert config.password.get_secret_value() == "test-pass"

    def test_dsn_construction(self) -> None:
        config = PostgresConfig(
            host="postgres.rivulet.svc",
            user="app",
            password="StagingPostgresP123",
            db="app",
        )
        assert config.dsn == (
            "postgresql+psycopg://app:StagingPostgresP123@postgres.rivulet.svc:5432/app"
        )

    def test_raw_dsn_construction(self) -> None:
        config = PostgresConfig(host="localhost", user="app", password="pass", db="app")
        assert config.raw_dsn == "postgresql://app:pass@localhost:5432/app"

    def test_dsn_encodes_special_chars(self) -> None:
        config = PostgresConfig(password="p@ss:w0rd/test")
        assert "p%40ss%3Aw0rd%2Ftest" in config.dsn
        assert "p%40ss%3Aw0rd%2Ftest" in config.raw_dsn

    def test_fails_without_password(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            PostgresConfig()  # type: ignore[call-arg]
        errors = exc_info.value.errors()
        assert any(e["loc"][0] == "password" for e in errors)

    def test_port_bounds(self) -> None:
        for bad in (0, 70000):
            with pytest.raises(ValidationError):
                PostgresConfig(password="pass", port=bad)


# ---------------------------------------------------------------------------
# AlertConfig
# ---------------------------------------------------------------------------


class TestAlertConfig:
    def test_loads_with_required_vars(self) -> None:
        config = AlertConfig(webhook_secret="secret-123")
        assert config.webhook_secret.get_secret_value() == "secret-123"

    def test_fails_without_secret(self) -> None:
        with pytest.raises(ValidationError) as exc_info:
            AlertConfig()  # type: ignore[call-arg]
        errors = exc_info.value.errors()
        assert any(e["loc"][0] == "webhook_secret" for e in errors)


# ---------------------------------------------------------------------------
# OpenObserveConfig
# ---------------------------------------------------------------------------


class TestOpenObserveConfig:
    def test_loads_with_required_vars(self) -> None:
        config = OpenObserveConfig(email="reader@test.local", password="rp")
        assert config.email == "reader@test.local"
        assert config.password.get_secret_value() == "rp"
        assert config.url == "http://localhost:5080"

    def test_fails_without_email(self) -> None:
        with pytest.raises(ValidationError):
            OpenObserveConfig(password="pass")  # type: ignore[call-arg]

    def test_fails_without_password(self) -> None:
        with pytest.raises(ValidationError):
            OpenObserveConfig(email="a@b.com")  # type: ignore[call-arg]

    def test_custom_url(self) -> None:
        config = OpenObserveConfig(email="a@b.com", password="pass", url="http://custom-o2:9000")
        assert config.url == "http://custom-o2:9000"


# ---------------------------------------------------------------------------
# OTelConfig
# ---------------------------------------------------------------------------


class TestOTelConfig:
    def test_loads_with_defaults(self) -> None:
        config = OTelConfig()
        assert config.exporter_otlp_endpoint == "http://localhost:4318"
        assert config.service_name == "autosre-agent"
        assert config.exporter_headers == ""
        assert config.parsed_headers == {}

    def test_header_parsing_single(self) -> None:
        config = OTelConfig(exporter_headers="Authorization=Bearer token")
        assert config.parsed_headers == {"Authorization": "Bearer token"}

    def test_header_parsing_multiple(self) -> None:
        config = OTelConfig(
            exporter_headers="Authorization=Bearer token,X-Custom=value,API-Key=secret",
        )
        assert config.parsed_headers == {
            "Authorization": "Bearer token",
            "X-Custom": "value",
            "API-Key": "secret",
        }

    def test_header_parsing_with_spaces(self) -> None:
        config = OTelConfig(exporter_headers=" Authorization = Bearer token ")
        assert config.parsed_headers == {"Authorization": "Bearer token"}

    def test_malformed_pair_skipped(self) -> None:
        config = OTelConfig(
            exporter_headers="Authorization=Bearer token,malformed,X=value",
        )
        assert config.parsed_headers == {
            "Authorization": "Bearer token",
            "X": "value",
        }

    def test_empty_headers(self) -> None:
        assert OTelConfig(exporter_headers="").parsed_headers == {}


# ---------------------------------------------------------------------------
# SafetyConfig
# ---------------------------------------------------------------------------


class TestSafetyConfig:
    def test_defaults(self) -> None:
        config = SafetyConfig()
        assert config.max_risk_tier_autonomous == 1
        assert config.max_actions_per_incident == 10
        assert config.max_wall_clock_seconds == 600

    def test_risk_tier_bounds(self) -> None:
        for bad in (-1, 5):
            with pytest.raises(ValidationError):
                SafetyConfig(max_risk_tier_autonomous=bad)

    def test_actions_bounds(self) -> None:
        for bad in (0, 100, 101):
            with pytest.raises(ValidationError):
                SafetyConfig(max_actions_per_incident=bad)

    def test_wall_clock_bounds(self) -> None:
        for bad in (10, 59, 3601):
            with pytest.raises(ValidationError):
                SafetyConfig(max_wall_clock_seconds=bad)

    def test_custom_limits(self) -> None:
        config = SafetyConfig(
            max_risk_tier_autonomous=2,
            max_actions_per_incident=20,
            max_wall_clock_seconds=1200,
        )
        assert config.max_risk_tier_autonomous == 2
        assert config.max_actions_per_incident == 20
        assert config.max_wall_clock_seconds == 1200


# ---------------------------------------------------------------------------
# SlackConfig
# ---------------------------------------------------------------------------


class TestSlackConfig:
    def test_defaults_disabled(self) -> None:
        config = SlackConfig()
        assert config.bot_token is None
        assert config.app_token is None
        assert config.signing_secret is None
        assert config.is_enabled is False

    def test_socket_mode_enabled_with_both_tokens(self) -> None:
        config = SlackConfig(
            mode="socket",
            bot_token="xoxb-test",
            app_token="xapp-test",
        )
        assert config.is_enabled is True

    def test_http_mode_enabled_with_token_and_secret(self) -> None:
        config = SlackConfig(
            mode="http",
            bot_token="xoxb-test",
            signing_secret="sig-test",
        )
        assert config.is_enabled is True

    def test_socket_mode_rejects_missing_app_token(self) -> None:
        with pytest.raises(ValidationError, match="mode=socket"):
            SlackConfig(mode="socket", bot_token="xoxb-test")

    def test_http_mode_rejects_missing_signing_secret(self) -> None:
        with pytest.raises(ValidationError, match="mode=http"):
            SlackConfig(mode="http", bot_token="xoxb-test")

    def test_empty_config_is_valid_and_disabled(self) -> None:
        config = SlackConfig()
        assert config.is_enabled is False


# ---------------------------------------------------------------------------
# AdminConfig
# ---------------------------------------------------------------------------


class TestAdminConfig:
    def test_default_secret_is_none(self) -> None:
        config = AdminConfig()
        assert config.secret is None

    def test_custom_secret(self) -> None:
        config = AdminConfig(secret="s3cr3t")
        assert config.secret is not None
        assert config.secret.get_secret_value() == "s3cr3t"


# ---------------------------------------------------------------------------
# Settings (root)
# ---------------------------------------------------------------------------


class TestSettings:
    def _set_minimum_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AUTOSRE_LLM__API_KEY", "test-key")
        monkeypatch.setenv("AUTOSRE_POSTGRES__PASSWORD", "pg-pass")
        monkeypatch.setenv("AUTOSRE_ALERT__WEBHOOK_SECRET", "webhook-secret")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__EMAIL", "admin@test.com")
        monkeypatch.setenv("AUTOSRE_OPENOBSERVE__PASSWORD", "o2-pass")

    def test_loads_complete_config(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self._set_minimum_env(monkeypatch)
        settings = Settings()
        assert settings.llm.api_key.get_secret_value() == "test-key"
        assert settings.postgres.password.get_secret_value() == "pg-pass"
        assert settings.alert.webhook_secret.get_secret_value() == "webhook-secret"
