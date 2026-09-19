package telemetry

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"go.opentelemetry.io/otel"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/config"
)

func TestInitTelemetry_ExportsSpans(t *testing.T) {
	tracesReceived := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if r.URL.Path == "/v1/traces" {
			body, err := io.ReadAll(r.Body)
			if err != nil {
				http.Error(w, "failed to read body", http.StatusBadRequest)
				return
			}
			if len(body) == 0 {
				http.Error(w, "empty trace payload", http.StatusBadRequest)
				return
			}
			if got := r.Header.Get("Content-Type"); got != "application/x-protobuf" {
				http.Error(w, "unexpected content type", http.StatusUnsupportedMediaType)
				return
			}
			select {
			case tracesReceived <- struct{}{}:
			default:
			}
		}

		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	// Prevent inherited env vars from overriding the test endpoint
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", server.URL)
	t.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
	t.Setenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "")
	t.Setenv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
	t.Setenv("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "")
	t.Setenv("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "")

	oldTracerProvider := otel.GetTracerProvider()
	oldMeterProvider := otel.GetMeterProvider()
	oldPropagator := otel.GetTextMapPropagator()

	cfg := &config.Config{
		ServiceName: "test-worker",
		Environment: "test",
		GitVersion:  "v1.0.0",
	}

	ctx := context.Background()
	shutdown, err := InitTelemetry(ctx, cfg)
	if err != nil {
		t.Fatalf("InitTelemetry() error = %v", err)
	}

	// Generate a test span
	tracer := otel.Tracer("test-tracer")
	_, span := tracer.Start(ctx, "test-operation")
	span.End()

	flushCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	type forceFlusher interface {
		ForceFlush(context.Context) error
	}

	// 1. Flush traces synchronously
	traceFlusher, ok := otel.GetTracerProvider().(forceFlusher)
	if !ok {
		t.Fatal("global tracer provider does not implement ForceFlush")
	}
	if err := traceFlusher.ForceFlush(flushCtx); err != nil {
		t.Fatalf("Trace ForceFlush() error = %v", err)
	}

	// 2. Wait for trace to be received BEFORE any teardown
	select {
	case <-tracesReceived:
		// Success
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for trace export to mock collector")
	}

	// 3. Flush metrics synchronously while server is still alive
	if metricFlusher, ok := otel.GetMeterProvider().(forceFlusher); ok {
		if err := metricFlusher.ForceFlush(flushCtx); err != nil {
			t.Logf("Metric ForceFlush() warning (non-fatal): %v", err)
		}
	}

	// 4. Shutdown telemetry while server is still alive
	if err := shutdown(context.Background()); err != nil {
		t.Logf("telemetry shutdown warning (non-fatal): %v", err)
	}

	// 5. Restore global state before server closes
	otel.SetTracerProvider(oldTracerProvider)
	otel.SetMeterProvider(oldMeterProvider)
	otel.SetTextMapPropagator(oldPropagator)

	// server.Close() runs via defer AFTER all exports complete
}
