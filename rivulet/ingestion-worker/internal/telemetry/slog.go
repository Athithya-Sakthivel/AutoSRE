package telemetry

import (
	"context"
	"log/slog"

	"go.opentelemetry.io/otel/trace"
)

// TraceHandler wraps a slog.Handler and adds the active OpenTelemetry trace
// context to each handled record.
type TraceHandler struct {
	handler slog.Handler
}

// NewTraceHandler creates a handler that adds trace_id, span_id, and
// trace_flags when the incoming context contains a valid span context.
func NewTraceHandler(handler slog.Handler) *TraceHandler {
	if handler == nil {
		panic("telemetry: nil slog handler")
	}
	return &TraceHandler{handler: handler}
}

// Enabled delegates to the wrapped handler.
func (h *TraceHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.handler.Enabled(ctx, level)
}

// Handle adds OpenTelemetry trace context attributes to the record and then
// delegates to the wrapped handler.
func (h *TraceHandler) Handle(ctx context.Context, r slog.Record) error {
	if ctx == nil {
		ctx = context.Background()
	}

	spanCtx := trace.SpanContextFromContext(ctx)
	if spanCtx.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", spanCtx.TraceID().String()),
			slog.String("span_id", spanCtx.SpanID().String()),
			slog.String("trace_flags", spanCtx.TraceFlags().String()),
		)
	}

	return h.handler.Handle(ctx, r)
}

// WithAttrs delegates to the wrapped handler and wraps the returned handler.
func (h *TraceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &TraceHandler{handler: h.handler.WithAttrs(attrs)}
}

// WithGroup delegates to the wrapped handler and wraps the returned handler.
func (h *TraceHandler) WithGroup(name string) slog.Handler {
	return &TraceHandler{handler: h.handler.WithGroup(name)}
}

var _ slog.Handler = (*TraceHandler)(nil)
