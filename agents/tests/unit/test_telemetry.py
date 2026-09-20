"""Unit tests for ``autosre.telemetry.otel``."""

from __future__ import annotations

import contextlib
from typing import Any

import pytest
from openinference.semconv.trace import SpanAttributes
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.util._once import Once

from autosre.config import Settings, get_settings
from autosre.telemetry import otel as otel_module
from autosre.telemetry.otel import (
    SEMANTIC_ATTRIBUTES,
    _build_endpoint,
    _TelemetryState,
    get_tracer,
    init_telemetry,
    instrument_fastapi,
    shutdown_telemetry,
)


@pytest.fixture(autouse=True)
def clean_telemetry(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Reset module and OTel global state around each test.

    OpenTelemetry intentionally has no public API to replace or reset the global
    tracer provider. Test isolation therefore has to touch its private module
    globals; this fixture is the only place in the suite that does so.
    """
    # Pre-test: force a clean slate. shutdown_telemetry() may not have been
    # called if the previous test crashed, so we suppress errors.
    with contextlib.suppress(Exception):
        shutdown_telemetry()

    monkeypatch.delenv("OTEL_PYTHON_TRACER_PROVIDER", raising=False)

    trace._TRACER_PROVIDER = None  # type: ignore[attr-defined]
    trace._TRACER_PROVIDER_SET_ONCE = Once()  # type: ignore[attr-defined]

    otel_module._state = _TelemetryState()

    yield

    # Post-test: always tear down, even if the test raised mid-span.
    with contextlib.suppress(Exception):
        shutdown_telemetry()

    trace._TRACER_PROVIDER = None  # type: ignore[attr-defined]
    trace._TRACER_PROVIDER_SET_ONCE = Once()  # type: ignore[attr-defined]

    otel_module._state = _TelemetryState()


@pytest.fixture
def settings(monkeypatch: pytest.MonkeyPatch) -> Settings:
    """Build valid application settings using only test credentials."""
    monkeypatch.setenv("LLM_API_KEY", "test-key")
    monkeypatch.setenv("POSTGRES_PASSWORD", "test-pass")
    monkeypatch.setenv("OPENOBSERVE_EMAIL", "reader@autosre.local")
    monkeypatch.setenv("OPENOBSERVE_PASSWORD", "test-pass")
    monkeypatch.setenv("ALERT_WEBHOOK_SECRET", "secret-123")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "autosre-agent-test")
    monkeypatch.setenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://otel.test:4318",
    )
    monkeypatch.setenv("DEPLOYMENT_ENVIRONMENT", "test")

    return get_settings()


class TestBuildEndpoint:
    """Tests for OTLP/HTTP endpoint construction."""

    def test_appends_traces_path_when_absent(self) -> None:
        assert _build_endpoint("http://otel:4318") == "http://otel:4318/v1/traces"

    def test_appends_traces_path_when_root_slash(self) -> None:
        assert _build_endpoint("http://otel:4318/") == "http://otel:4318/v1/traces"

    def test_preserves_explicit_traces_path(self) -> None:
        url = "http://otel:4318/v1/traces"

        assert _build_endpoint(url) == url

    def test_preserves_traces_path_with_trailing_slash(self) -> None:
        url = "http://otel:4318/v1/traces/"

        assert _build_endpoint(url) == url

    def test_appends_to_custom_collector_prefix(self) -> None:
        url = "http://otel:4318/custom/collector"

        assert _build_endpoint(url) == ("http://otel:4318/custom/collector/v1/traces")

    def test_preserves_query_string(self) -> None:
        url = "https://otel.example.com:4318/otlp?tenant=autosre"

        assert _build_endpoint(url) == (
            "https://otel.example.com:4318/otlp/v1/traces?tenant=autosre"
        )

    def test_supports_https(self) -> None:
        assert (
            _build_endpoint("https://otel.example.com:4318")
            == "https://otel.example.com:4318/v1/traces"
        )

    @pytest.mark.parametrize(
        "url",
        [
            "",
            "otel:4318",
            "/v1/traces",
            "ftp://otel:4318",
        ],
    )
    def test_rejects_invalid_endpoint(self, url: str) -> None:
        # Both error paths raise ValueError with a message containing
        # "OTLP endpoint" — either "must not be empty" or
        # "must be an absolute HTTP(S) URL".
        with pytest.raises(ValueError, match="OTLP endpoint"):
            _build_endpoint(url)


class TestInitTelemetry:
    """Tests for initialization and shutdown lifecycle."""

    def test_returns_shutdown_callable(self, settings: Settings) -> None:
        shutdown = init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        assert callable(shutdown)

    def test_initializes_global_tracer_provider(
        self,
        settings: Settings,
    ) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        assert isinstance(trace.get_tracer_provider(), TracerProvider)

    def test_double_init_raises(self, settings: Settings) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        with pytest.raises(RuntimeError, match="more than once"):
            init_telemetry(
                settings,
                exporter_override=InMemorySpanExporter(),
            )

    def test_shutdown_is_idempotent(self, settings: Settings) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        shutdown_telemetry()
        shutdown_telemetry()

    def test_reinit_after_shutdown_is_rejected(
        self,
        settings: Settings,
    ) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )
        shutdown_telemetry()

        with pytest.raises(
            RuntimeError,
            match="reinitialized after shutdown",
        ):
            init_telemetry(
                settings,
                exporter_override=InMemorySpanExporter(),
            )


class TestOpenInferenceAttributes:
    """Contract tests for OpenInference attributes and OTel resources."""

    def test_llm_call_span_carries_openinference_attributes(
        self,
        settings: Settings,
    ) -> None:
        exporter = InMemorySpanExporter()

        init_telemetry(
            settings,
            exporter_override=exporter,
        )

        provider = otel_module._state.provider
        assert provider is not None

        tracer = get_tracer("autosre.test")

        with tracer.start_as_current_span("litellm.completion") as span:
            span.set_attribute(
                SpanAttributes.OPENINFERENCE_SPAN_KIND,
                "LLM",
            )
            span.set_attribute(
                SpanAttributes.LLM_PROVIDER,
                "groq",
            )
            span.set_attribute(
                SpanAttributes.LLM_MODEL_NAME,
                "qwen/qwen3.8-27b",
            )
            span.set_attribute(
                SpanAttributes.INPUT_VALUE,
                "What is MTTR?",
            )
            span.set_attribute(
                SpanAttributes.OUTPUT_VALUE,
                "Mean Time To Recovery.",
            )
            span.set_attribute(
                SpanAttributes.LLM_TOKEN_COUNT_PROMPT,
                12,
            )
            span.set_attribute(
                SpanAttributes.LLM_TOKEN_COUNT_COMPLETION,
                8,
            )
            span.set_attribute(
                SpanAttributes.LLM_TOKEN_COUNT_TOTAL,
                20,
            )

        assert provider.force_flush()

        spans = exporter.get_finished_spans()

        assert len(spans) == 1

        finished = spans[0]
        attrs = dict(finished.attributes or {})

        assert finished.name == "litellm.completion"
        assert attrs[SpanAttributes.OPENINFERENCE_SPAN_KIND] == "LLM"
        assert attrs[SpanAttributes.LLM_PROVIDER] == "groq"
        assert attrs[SpanAttributes.LLM_MODEL_NAME] == "qwen/qwen3.8-27b"
        assert attrs[SpanAttributes.INPUT_VALUE] == "What is MTTR?"
        assert attrs[SpanAttributes.OUTPUT_VALUE] == ("Mean Time To Recovery.")
        assert attrs[SpanAttributes.LLM_TOKEN_COUNT_PROMPT] == 12
        assert attrs[SpanAttributes.LLM_TOKEN_COUNT_COMPLETION] == 8
        assert attrs[SpanAttributes.LLM_TOKEN_COUNT_TOTAL] == 20

    def test_resource_attributes_propagate(
        self,
        settings: Settings,
    ) -> None:
        exporter = InMemorySpanExporter()

        init_telemetry(
            settings,
            exporter_override=exporter,
        )

        provider = otel_module._state.provider
        assert provider is not None

        tracer = get_tracer("autosre.test")

        with tracer.start_as_current_span("dummy"):
            pass

        assert provider.force_flush()

        spans = exporter.get_finished_spans()

        assert len(spans) == 1

        resource_attrs = dict(spans[0].resource.attributes)

        assert resource_attrs["service.name"] == "autosre-agent-test"
        assert resource_attrs["service.namespace"] == "autosre"
        assert resource_attrs["deployment.environment.name"] == "test"

    def test_semantic_attributes_reexport(self) -> None:
        assert SEMANTIC_ATTRIBUTES is SpanAttributes

        for name in (
            "OPENINFERENCE_SPAN_KIND",
            "LLM_PROVIDER",
            "LLM_MODEL_NAME",
            "LLM_TOKEN_COUNT_PROMPT",
            "LLM_TOKEN_COUNT_COMPLETION",
            "LLM_TOKEN_COUNT_TOTAL",
            "INPUT_VALUE",
            "OUTPUT_VALUE",
        ):
            assert hasattr(SEMANTIC_ATTRIBUTES, name)


class TestGetTracer:
    """Tests for the tracer helper."""

    def test_returns_tracer_with_default_name(
        self,
        settings: Settings,
    ) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        tracer = get_tracer()

        with tracer.start_as_current_span("ping") as span:
            assert span.is_recording()

    def test_returns_tracer_with_custom_name(
        self,
        settings: Settings,
    ) -> None:
        init_telemetry(
            settings,
            exporter_override=InMemorySpanExporter(),
        )

        tracer = get_tracer("autosre.custom.scope")

        with tracer.start_as_current_span("ping") as span:
            assert span.is_recording()


class TestFastAPIInstrumentation:
    """Tests for the FastAPI-specific lifecycle guard."""

    def test_requires_telemetry_initialization(self) -> None:
        with pytest.raises(
            RuntimeError,
            match=r"init_telemetry\(\) must be called",
        ):
            instrument_fastapi(object())
