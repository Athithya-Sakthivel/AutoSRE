package queue

import (
	"context"
	"fmt"
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// MockRedisClient implements RedisClient for unit tests.
type MockRedisClient struct {
	XReadGroupFunc           func(ctx context.Context, a *redis.XReadGroupArgs) *redis.XStreamSliceCmd
	XAckFunc                 func(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd
	XAddFunc                 func(ctx context.Context, a *redis.XAddArgs) *redis.StringCmd
	XPendingExtFunc          func(ctx context.Context, a *redis.XPendingExtArgs) *redis.XPendingExtCmd
	XClaimFunc               func(ctx context.Context, a *redis.XClaimArgs) *redis.XMessageSliceCmd
	XInfoConsumersFunc       func(ctx context.Context, stream, group string) *redis.XInfoConsumersCmd
	XInfoGroupsFunc          func(ctx context.Context, stream string) *redis.XInfoGroupsCmd
	XGroupCreateMkStreamFunc func(ctx context.Context, stream, group, start string) *redis.StatusCmd
}

func (m *MockRedisClient) XReadGroup(ctx context.Context, a *redis.XReadGroupArgs) *redis.XStreamSliceCmd {
	if m.XReadGroupFunc != nil {
		return m.XReadGroupFunc(ctx, a)
	}
	cmd := &redis.XStreamSliceCmd{}
	cmd.SetErr(redis.Nil)
	return cmd
}

func (m *MockRedisClient) XAck(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd {
	if m.XAckFunc != nil {
		return m.XAckFunc(ctx, stream, group, ids...)
	}
	return redis.NewIntResult(0, nil)
}

func (m *MockRedisClient) XAdd(ctx context.Context, a *redis.XAddArgs) *redis.StringCmd {
	if m.XAddFunc != nil {
		return m.XAddFunc(ctx, a)
	}
	return redis.NewStringResult("", nil)
}

func (m *MockRedisClient) XPendingExt(ctx context.Context, a *redis.XPendingExtArgs) *redis.XPendingExtCmd {
	if m.XPendingExtFunc != nil {
		return m.XPendingExtFunc(ctx, a)
	}
	cmd := &redis.XPendingExtCmd{}
	cmd.SetVal([]redis.XPendingExt{})
	return cmd
}

func (m *MockRedisClient) XClaim(ctx context.Context, a *redis.XClaimArgs) *redis.XMessageSliceCmd {
	if m.XClaimFunc != nil {
		return m.XClaimFunc(ctx, a)
	}
	cmd := &redis.XMessageSliceCmd{}
	cmd.SetVal([]redis.XMessage{})
	return cmd
}

func (m *MockRedisClient) XInfoConsumers(ctx context.Context, stream, group string) *redis.XInfoConsumersCmd {
	if m.XInfoConsumersFunc != nil {
		return m.XInfoConsumersFunc(ctx, stream, group)
	}
	cmd := &redis.XInfoConsumersCmd{}
	cmd.SetVal([]redis.XInfoConsumer{})
	return cmd
}

func (m *MockRedisClient) XInfoGroups(ctx context.Context, stream string) *redis.XInfoGroupsCmd {
	if m.XInfoGroupsFunc != nil {
		return m.XInfoGroupsFunc(ctx, stream)
	}
	cmd := &redis.XInfoGroupsCmd{}
	cmd.SetVal([]redis.XInfoGroup{})
	return cmd
}

func (m *MockRedisClient) XGroupCreateMkStream(ctx context.Context, stream, group, start string) *redis.StatusCmd {
	if m.XGroupCreateMkStreamFunc != nil {
		return m.XGroupCreateMkStreamFunc(ctx, stream, group, start)
	}
	return redis.NewStatusResult("OK", nil)
}

func TestStreamConsumer_EnsureGroup(t *testing.T) {
	mock := &MockRedisClient{
		XGroupCreateMkStreamFunc: func(ctx context.Context, stream, group, start string) *redis.StatusCmd {
			assert.Equal(t, "test-stream", stream)
			assert.Equal(t, "test-group", group)
			assert.Equal(t, "0", start)
			return redis.NewStatusResult("OK", nil)
		},
	}

	consumer := NewStreamConsumer(mock, "test-stream", "test-group", "consumer-1", nil)
	err := consumer.EnsureGroup(context.Background())
	require.NoError(t, err)
}

func TestStreamConsumer_ProcessMessage_ExtractsTraceContext(t *testing.T) {
	exporter := tracetest.NewInMemoryExporter()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exporter))
	defer func() { _ = tp.Shutdown(context.Background()) }()

	propagator := propagation.TraceContext{}
	producerTracer := tp.Tracer("test-producer")
	parentCtx, parentSpan := producerTracer.Start(context.Background(), "producer-span")

	carrier := NewMessageCarrier()
	propagator.Inject(parentCtx, carrier)
	parentSpan.End()

	xmsg := redis.XMessage{
		ID: "1234567890-0",
		Values: map[string]interface{}{
			TraceParentKey: carrier[TraceParentKey],
			TraceStateKey:  carrier[TraceStateKey],
			PayloadKey:     `{"event":"test"}`,
		},
	}

	ackCalls := 0
	mock := &MockRedisClient{
		XAckFunc: func(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd {
			ackCalls++
			assert.Equal(t, "test-stream", stream)
			assert.Equal(t, "test-group", group)
			assert.Contains(t, ids, "1234567890-0")
			return redis.NewIntResult(1, nil)
		},
	}

	consumer := NewStreamConsumerWithOptions(mock, "test-stream", "test-group", "consumer-1", nil, StreamConsumerOptions{
		Tracer:     tp.Tracer("rivulet.queue"),
		Propagator: propagator,
	})

	msgChan := make(chan Message, 1)
	consumer.processMessage(context.Background(), xmsg, msgChan)

	msg := <-msgChan
	require.NotNil(t, msg.Ack)

	assert.Equal(t, "1234567890-0", msg.ID)
	assert.Equal(t, `{"event":"test"}`, string(msg.Payload))
	assert.Equal(t, parentSpan.SpanContext().TraceID(), trace.SpanContextFromContext(msg.TraceCtx).TraceID())
	assert.Equal(t, int64(1), msg.DeliveryCount)
	assert.Equal(t, 0, ackCalls, "valid messages must not be acknowledged before processing completes")

	require.NoError(t, msg.Ack(context.Background()))
	require.NoError(t, msg.Ack(context.Background()))
	assert.Equal(t, 1, ackCalls, "ack must be idempotent")

	spans := exporter.GetSpans()
	require.Len(t, spans, 2)

	var consumerSpan = spans[1]

	// tracetest.SpanStub fields are accessed directly, not as methods
	assert.Equal(t, "process test-stream", consumerSpan.Name)
	assert.Equal(t, parentSpan.SpanContext().TraceID(), consumerSpan.SpanContext.TraceID())
	assert.Equal(t, parentSpan.SpanContext().SpanID(), consumerSpan.Parent.SpanID())
}

func TestStreamConsumer_InvalidPayload_IsDeadLettered(t *testing.T) {
	ackCalls := 0
	addCalls := 0

	mock := &MockRedisClient{
		XAddFunc: func(ctx context.Context, args *redis.XAddArgs) *redis.StringCmd {
			addCalls++
			assert.Equal(t, "test-stream.dlq", args.Stream)

			// FIX: Type assert args.Values to map[string]interface{}
			values, ok := args.Values.(map[string]interface{})
			require.True(t, ok, "args.Values should be map[string]interface{}")
			assert.Equal(t, "invalid_json", values["dlq_reason"])

			return redis.NewStringResult("1-0", nil)
		},
		XAckFunc: func(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd {
			ackCalls++
			return redis.NewIntResult(1, nil)
		},
	}

	consumer := NewStreamConsumer(mock, "test-stream", "test-group", "consumer-1", nil)
	msgChan := make(chan Message, 1)

	consumer.processMessage(context.Background(), redis.XMessage{
		ID:     "1-0",
		Values: map[string]interface{}{PayloadKey: "not-json"},
	}, msgChan)

	assert.Empty(t, msgChan)
	assert.Equal(t, 1, addCalls)
	assert.Equal(t, 1, ackCalls)
}

func TestStreamConsumer_ExceededDeliveryAttempts_IsDeadLettered(t *testing.T) {
	ackCalls := 0
	addCalls := 0

	mock := &MockRedisClient{
		XAddFunc: func(ctx context.Context, args *redis.XAddArgs) *redis.StringCmd {
			addCalls++

			// FIX: Type assert args.Values to map[string]interface{}
			values, ok := args.Values.(map[string]interface{})
			require.True(t, ok, "args.Values should be map[string]interface{}")
			assert.Equal(t, "max_delivery_attempts_exceeded", values["dlq_reason"])
			assert.Equal(t, int64(2), values["delivery_count"])

			return redis.NewStringResult("2-0", nil)
		},
		XAckFunc: func(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd {
			ackCalls++
			return redis.NewIntResult(1, nil)
		},
	}

	consumer := NewStreamConsumerWithOptions(mock, "test-stream", "test-group", "consumer-1", nil, StreamConsumerOptions{
		MaxDeliveryAttempts: 1,
	})

	msgChan := make(chan Message, 1)
	consumer.processMessageWithDeliveryCount(context.Background(), redis.XMessage{
		ID:     "2-0",
		Values: map[string]interface{}{PayloadKey: `{"event":"test"}`},
	}, 2, msgChan)

	assert.Empty(t, msgChan)
	assert.Equal(t, 1, addCalls)
	assert.Equal(t, 1, ackCalls)
}

func TestStreamConsumer_BusyGroup_IsNotError(t *testing.T) {
	mock := &MockRedisClient{
		XGroupCreateMkStreamFunc: func(ctx context.Context, stream, group, start string) *redis.StatusCmd {
			return redis.NewStatusResult("", fmt.Errorf("BUSYGROUP Consumer Group name already exists"))
		},
	}

	consumer := NewStreamConsumer(mock, "test-stream", "test-group", "consumer-1", nil)
	require.NoError(t, consumer.EnsureGroup(context.Background()))
}
