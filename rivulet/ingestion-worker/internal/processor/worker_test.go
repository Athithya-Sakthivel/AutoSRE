package processor

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/queue"
)

func TestWorker_Process_ValidationError_AcksAndRecords(t *testing.T) {
	exporter := tracetest.NewInMemoryExporter()
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(exporter),
	)
	defer func() {
		assert.NoError(t, tp.Shutdown(context.Background()))
	}()

	inst, err := metrics.Init(context.Background())
	if !assert.NoError(t, err) {
		return
	}

	w := &Worker{
		pool:        nil,
		instruments: inst,
		tracer:      tp.Tracer("test"),
	}

	ackCalled := false

	msg := queue.Message{
		ID:       "1-0",
		Payload:  json.RawMessage(`{"event_id":"","user_id":"u1","sku":"s1","quantity":1}`),
		TraceCtx: context.Background(),
		Ack: func(ctx context.Context) error {
			ackCalled = true
			return nil
		},
	}

	w.process(msg)

	assert.True(
		t,
		ackCalled,
		"permanent validation errors must ack the message to prevent infinite retries",
	)

	spans := exporter.GetSpans()
	if assert.Len(t, spans, 1) {
		assert.Equal(t, "process_order_event", spans[0].Name)
	}
}

func TestWorker_Process_InvalidJSON_Acks(t *testing.T) {
	exporter := tracetest.NewInMemoryExporter()
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(exporter),
	)
	defer func() {
		assert.NoError(t, tp.Shutdown(context.Background()))
	}()

	inst, err := metrics.Init(context.Background())
	if !assert.NoError(t, err) {
		return
	}

	w := &Worker{
		pool:        nil,
		instruments: inst,
		tracer:      tp.Tracer("test"),
	}

	ackCalled := false

	msg := queue.Message{
		ID:       "1-1",
		Payload:  json.RawMessage(`{"event_id":`),
		TraceCtx: context.Background(),
		Ack: func(ctx context.Context) error {
			ackCalled = true
			return nil
		},
	}

	w.process(msg)

	assert.True(
		t,
		ackCalled,
		"invalid JSON must be acknowledged as a permanent error",
	)

	spans := exporter.GetSpans()
	if assert.Len(t, spans, 1) {
		assert.Equal(t, "process_order_event", spans[0].Name)
	}
}

func TestWorker_HandleEvent_ValidationErrorDoesNotTouchDatabase(t *testing.T) {
	w := &Worker{
		pool: nil,
	}

	err := w.handleEvent(
		context.Background(),
		json.RawMessage(`{"event_id":"","user_id":"u1","sku":"s1","quantity":1}`),
	)

	assert.Error(t, err)

	var permErr *PermanentError
	assert.ErrorAs(t, err, &permErr)
	assert.Contains(t, err.Error(), "missing event_id")
}

func TestWorker_HandleEvent_InvalidQuantityIsPermanent(t *testing.T) {
	w := &Worker{
		pool: nil,
	}

	err := w.handleEvent(
		context.Background(),
		json.RawMessage(`{"event_id":"e1","user_id":"u1","sku":"s1","quantity":0}`),
	)

	assert.Error(t, err)

	var permErr *PermanentError
	assert.ErrorAs(t, err, &permErr)
	assert.Contains(t, err.Error(), "invalid quantity")
}
