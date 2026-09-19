package telemetry

import (
	"context"
	"errors"
	"fmt"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/config"
)

// InitTelemetry configures the global OpenTelemetry providers and propagator.
// The returned function must be called during application shutdown.
func InitTelemetry(ctx context.Context, cfg *config.Config) (func(context.Context) error, error) {
	if cfg == nil {
		return nil, errors.New("telemetry config is nil")
	}

	res, err := resource.New(
		ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithSchemaURL(semconv.SchemaURL),
		resource.WithAttributes(
			semconv.ServiceName(cfg.ServiceName),
			semconv.ServiceNamespace("rivulet"),
			attribute.String("deployment.environment.name", cfg.Environment),
			semconv.ServiceVersion(cfg.GitVersion),
		),
	)

	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	traceExporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
		sdktrace.WithBatcher(traceExporter),
	)

	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		_ = tp.Shutdown(ctx)
		return nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(
			sdkmetric.NewPeriodicReader(
				metricExporter,
				sdkmetric.WithInterval(15*time.Second),
			),
		),
	)

	if err := runtime.Start(
		runtime.WithMeterProvider(mp),
		runtime.WithMinimumReadMemStatsInterval(15*time.Second),
	); err != nil {
		cleanupErr := errors.Join(mp.Shutdown(ctx), tp.Shutdown(ctx))
		if cleanupErr != nil {
			return nil, errors.Join(
				fmt.Errorf("failed to start runtime instrumentation: %w", err),
				fmt.Errorf("telemetry cleanup failed: %w", cleanupErr),
			)
		}
		return nil, fmt.Errorf("failed to start runtime instrumentation: %w", err)
	}

	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	shutdown := func(shutdownCtx context.Context) error {
		var shutdownErr error

		if err := mp.Shutdown(shutdownCtx); err != nil {
			shutdownErr = fmt.Errorf("metric provider shutdown failed: %w", err)
		}
		if err := tp.Shutdown(shutdownCtx); err != nil {
			traceErr := fmt.Errorf("trace provider shutdown failed: %w", err)
			shutdownErr = errors.Join(shutdownErr, traceErr)
		}
		return shutdownErr
	}

	return shutdown, nil
}
