package queue

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
)

const (
	defaultBatchSize           int64 = 10
	defaultBlockDuration             = 5 * time.Second
	defaultReclaimInterval           = 10 * time.Second
	defaultReclaimIdle               = 1 * time.Minute
	defaultMaxDeliveryAttempts int64 = 5
	reclaimBackoff                   = 500 * time.Millisecond
)

// RedisClient defines the Valkey commands used by the consumer.
type RedisClient interface {
	XReadGroup(ctx context.Context, a *redis.XReadGroupArgs) *redis.XStreamSliceCmd
	XAck(ctx context.Context, stream, group string, ids ...string) *redis.IntCmd
	XAdd(ctx context.Context, a *redis.XAddArgs) *redis.StringCmd
	XPendingExt(ctx context.Context, a *redis.XPendingExtArgs) *redis.XPendingExtCmd
	XClaim(ctx context.Context, a *redis.XClaimArgs) *redis.XMessageSliceCmd
	XInfoConsumers(ctx context.Context, stream, group string) *redis.XInfoConsumersCmd
	XInfoGroups(ctx context.Context, stream string) *redis.XInfoGroupsCmd
	XGroupCreateMkStream(ctx context.Context, stream, group, start string) *redis.StatusCmd
}

// StreamConsumerOptions controls StreamConsumer behavior.
type StreamConsumerOptions struct {
	BatchSize           int64
	Block               time.Duration
	ReclaimInterval     time.Duration
	ReclaimIdle         time.Duration
	MaxDeliveryAttempts int64
	DeadLetterStream    string
	Tracer              trace.Tracer
	Propagator          propagation.TextMapPropagator
}

// StreamConsumer reads messages from a Valkey Stream using a consumer group.
type StreamConsumer struct {
	client      RedisClient
	stream      string
	group       string
	consumer    string
	instruments *metrics.Instruments
	tracer      trace.Tracer
	propagator  propagation.TextMapPropagator

	batchSize           int64
	block               time.Duration
	reclaimInterval     time.Duration
	reclaimIdle         time.Duration
	maxDeliveryAttempts int64
	deadLetterStream    string

	started atomic.Bool
}

// Message is the validated unit handed to the processor.
type Message struct {
	ID            string
	Payload       json.RawMessage
	TraceCtx      context.Context
	DeliveryCount int64
	Ack           func(context.Context) error
}

// NewStreamConsumer creates a consumer with production-safe defaults.
func NewStreamConsumer(client RedisClient, stream, group, consumer string, inst *metrics.Instruments) *StreamConsumer {
	return NewStreamConsumerWithOptions(client, stream, group, consumer, inst, StreamConsumerOptions{})
}

// NewStreamConsumerWithOptions creates a consumer with explicit options.
func NewStreamConsumerWithOptions(client RedisClient, stream, group, consumer string, inst *metrics.Instruments, opts StreamConsumerOptions) *StreamConsumer {
	if opts.BatchSize <= 0 {
		opts.BatchSize = defaultBatchSize
	}
	if opts.Block <= 0 {
		opts.Block = defaultBlockDuration
	}
	if opts.ReclaimInterval <= 0 {
		opts.ReclaimInterval = defaultReclaimInterval
	}
	if opts.ReclaimIdle <= 0 {
		opts.ReclaimIdle = defaultReclaimIdle
	}
	if opts.MaxDeliveryAttempts <= 0 {
		opts.MaxDeliveryAttempts = defaultMaxDeliveryAttempts
	}
	if opts.DeadLetterStream == "" || opts.DeadLetterStream == stream {
		opts.DeadLetterStream = stream + ".dlq"
	}
	if opts.Tracer == nil {
		opts.Tracer = otel.Tracer("rivulet.queue")
	}
	if opts.Propagator == nil {
		opts.Propagator = otel.GetTextMapPropagator()
	}

	return &StreamConsumer{
		client:              client,
		stream:              stream,
		group:               group,
		consumer:            consumer,
		instruments:         inst,
		tracer:              opts.Tracer,
		propagator:          opts.Propagator,
		batchSize:           opts.BatchSize,
		block:               opts.Block,
		reclaimInterval:     opts.ReclaimInterval,
		reclaimIdle:         opts.ReclaimIdle,
		maxDeliveryAttempts: opts.MaxDeliveryAttempts,
		deadLetterStream:    opts.DeadLetterStream,
	}
}

// EnsureGroup creates the consumer group if it does not already exist.
func (sc *StreamConsumer) EnsureGroup(ctx context.Context) error {
	if sc == nil || sc.client == nil {
		return errors.New("stream consumer is not initialized")
	}
	if ctx == nil {
		return errors.New("context must not be nil")
	}

	err := sc.client.XGroupCreateMkStream(ctx, sc.stream, sc.group, "0").Err()

	// go-redis/v9 does not have HasErrorPrefix; check string directly
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		return fmt.Errorf("failed to create consumer group: %w", err)
	}

	return nil
}

// Start validates the consumer, ensures the group exists, and starts the loops.
func (sc *StreamConsumer) Start(ctx context.Context, msgChan chan<- Message) error {
	if sc == nil || sc.client == nil {
		return errors.New("stream consumer is not initialized")
	}
	if ctx == nil {
		return errors.New("context must not be nil")
	}
	if msgChan == nil {
		return errors.New("message channel must not be nil")
	}
	if sc.stream == "" {
		return errors.New("stream name must not be empty")
	}
	if sc.group == "" {
		return errors.New("consumer group must not be empty")
	}
	if sc.consumer == "" {
		return errors.New("consumer name must not be empty")
	}

	if !sc.started.CompareAndSwap(false, true) {
		return errors.New("stream consumer already started")
	}

	if err := sc.EnsureGroup(ctx); err != nil {
		sc.started.Store(false)
		return err
	}

	go sc.consumeLoop(ctx, msgChan)
	go sc.reclaimLoop(ctx, msgChan)

	if sc.instruments != nil {
		go sc.observeQueueMetrics(ctx)
	}

	return nil
}

func (sc *StreamConsumer) consumeLoop(ctx context.Context, msgChan chan<- Message) {
	for {
		if ctx.Err() != nil {
			return
		}

		streams, err := sc.client.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    sc.group,
			Consumer: sc.consumer,
			Streams:  []string{sc.stream, ">"},
			Count:    sc.batchSize,
			Block:    sc.block,
		}).Result()

		if err != nil {
			if errors.Is(err, redis.Nil) {
				continue
			}
			if ctx.Err() != nil {
				return
			}

			slog.Default().ErrorContext(ctx, "valkey stream read failed", "stream", sc.stream, "group", sc.group, "consumer", sc.consumer, "error", err)

			if !sleepContext(ctx, reclaimBackoff) {
				return
			}
			continue
		}

		for _, stream := range streams {
			for _, xmsg := range stream.Messages {
				sc.processMessage(ctx, xmsg, msgChan)
				if ctx.Err() != nil {
					return
				}
			}
		}
	}
}

func (sc *StreamConsumer) reclaimLoop(ctx context.Context, msgChan chan<- Message) {
	ticker := time.NewTicker(sc.reclaimInterval)
	defer ticker.Stop()

	sc.reclaimPending(ctx, msgChan)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sc.reclaimPending(ctx, msgChan)
		}
	}
}

func (sc *StreamConsumer) reclaimPending(ctx context.Context, msgChan chan<- Message) {
	consumers, err := sc.client.XInfoConsumers(ctx, sc.stream, sc.group).Result()
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		slog.Default().ErrorContext(ctx, "failed to inspect stream consumers", "stream", sc.stream, "group", sc.group, "error", err)
		return
	}

	var claimed int64

	for _, owner := range consumers {
		if ctx.Err() != nil {
			return
		}
		if owner.Name == sc.consumer || owner.Pending <= 0 {
			continue
		}

		remaining := sc.batchSize - claimed
		if remaining <= 0 {
			return
		}

		entries, err := sc.client.XPendingExt(ctx, &redis.XPendingExtArgs{
			Stream:   sc.stream,
			Group:    sc.group,
			Start:    "-",
			End:      "+",
			Count:    remaining,
			Consumer: owner.Name,
			Idle:     sc.reclaimIdle,
		}).Result()

		if err != nil {
			if ctx.Err() != nil {
				return
			}
			slog.Default().ErrorContext(ctx, "failed to inspect pending stream entries", "stream", sc.stream, "group", sc.group, "owner", owner.Name, "error", err)
			continue
		}

		for _, entry := range entries {
			if ctx.Err() != nil {
				return
			}

			messages, err := sc.client.XClaim(ctx, &redis.XClaimArgs{
				Stream:   sc.stream,
				Group:    sc.group,
				Consumer: sc.consumer,
				MinIdle:  sc.reclaimIdle,
				Messages: []string{entry.ID},
			}).Result()

			if err != nil {
				if ctx.Err() != nil {
					return
				}
				slog.Default().ErrorContext(ctx, "failed to claim pending stream message", "stream", sc.stream, "group", sc.group, "owner", owner.Name, "message_id", entry.ID, "error", err)
				continue
			}

			if len(messages) == 0 {
				continue
			}

			for _, xmsg := range messages {
				deliveryCount := entry.RetryCount + 1
				if deliveryCount < 1 {
					deliveryCount = 1
				}

				sc.processMessageWithDeliveryCount(ctx, xmsg, deliveryCount, msgChan)

				claimed++
				if claimed >= sc.batchSize {
					return
				}
			}
		}
	}
}

func (sc *StreamConsumer) processMessage(ctx context.Context, xmsg redis.XMessage, msgChan chan<- Message) {
	sc.processMessageWithDeliveryCount(ctx, xmsg, 1, msgChan)
}

func (sc *StreamConsumer) processMessageWithDeliveryCount(ctx context.Context, xmsg redis.XMessage, deliveryCount int64, msgChan chan<- Message) {
	if ctx == nil {
		ctx = context.Background()
	}
	if msgChan == nil {
		return
	}
	if sc == nil || sc.client == nil {
		return
	}
	if deliveryCount < 1 {
		deliveryCount = 1
	}

	carrier := NewMessageCarrier()
	if value, ok := stringField(xmsg.Values[TraceParentKey]); ok {
		carrier[TraceParentKey] = value
	}
	if value, ok := stringField(xmsg.Values[TraceStateKey]); ok {
		carrier[TraceStateKey] = value
	}

	parentCtx := sc.propagator.Extract(ctx, carrier)

	spanCtx, span := sc.tracer.Start(
		parentCtx,
		fmt.Sprintf("process %s", sc.stream),
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.String("messaging.system", "redis"),
			attribute.String("messaging.operation.name", "process"),
			attribute.String("messaging.operation.type", "process"),
			attribute.String("messaging.destination.name", sc.stream),
			attribute.String("messaging.consumer.group.name", sc.group),
			attribute.Int64("rivulet.delivery.count", deliveryCount),
			attribute.String("rivulet.dependency.role", "queue"),
		),
	)
	defer span.End()

	payload, ok := rawPayload(xmsg.Values[PayloadKey])
	if !ok {
		err := errors.New("missing or unsupported payload field")
		sc.failMessage(spanCtx, span, xmsg, deliveryCount, "invalid_payload", err)
		return
	}

	if !json.Valid(payload) {
		err := errors.New("payload is not valid JSON")
		sc.failMessage(spanCtx, span, xmsg, deliveryCount, "invalid_json", err)
		return
	}

	if deliveryCount > sc.maxDeliveryAttempts {
		err := fmt.Errorf("delivery count %d exceeded maximum %d", deliveryCount, sc.maxDeliveryAttempts)
		sc.failMessage(spanCtx, span, xmsg, deliveryCount, "max_delivery_attempts_exceeded", err)
		return
	}

	var ackMu sync.Mutex
	acked := false

	ack := func(ackCtx context.Context) error {
		ackMu.Lock()
		defer ackMu.Unlock()

		if acked {
			return nil
		}
		if ackCtx == nil {
			ackCtx = spanCtx
		}

		if err := sc.client.XAck(ackCtx, sc.stream, sc.group, xmsg.ID).Err(); err != nil {
			return fmt.Errorf("failed to acknowledge message %s: %w", xmsg.ID, err)
		}

		acked = true
		return nil
	}

	message := Message{
		ID:            xmsg.ID,
		Payload:       json.RawMessage(append([]byte(nil), payload...)),
		TraceCtx:      spanCtx,
		DeliveryCount: deliveryCount,
		Ack:           ack,
	}

	select {
	case msgChan <- message:
	case <-ctx.Done():
		return
	}
}

func (sc *StreamConsumer) failMessage(ctx context.Context, span trace.Span, xmsg redis.XMessage, deliveryCount int64, reason string, cause error) {
	span.RecordError(cause)
	span.SetStatus(codes.Error, cause.Error())

	if sc.instruments != nil {
		sc.instruments.MessagesFailed.Add(ctx, 1)
	}

	if err := sc.deadLetter(ctx, xmsg, deliveryCount, reason); err != nil {
		span.RecordError(err)
		slog.Default().ErrorContext(ctx, "failed to dead-letter stream message", "stream", sc.stream, "group", sc.group, "message_id", xmsg.ID, "reason", reason, "error", err)
		return
	}

	span.SetAttributes(attribute.String("rivulet.dead_letter.reason", reason))
}

func (sc *StreamConsumer) deadLetter(ctx context.Context, xmsg redis.XMessage, deliveryCount int64, reason string) error {
	values := make(map[string]interface{}, len(xmsg.Values)+6)
	for key, value := range xmsg.Values {
		values[key] = value
	}

	values["original_stream"] = sc.stream
	values["original_group"] = sc.group
	values["original_consumer"] = sc.consumer
	values["original_id"] = xmsg.ID
	values["delivery_count"] = deliveryCount
	values["dlq_reason"] = reason

	if _, err := sc.client.XAdd(ctx, &redis.XAddArgs{
		Stream: sc.deadLetterStream,
		Values: values,
	}).Result(); err != nil {
		return fmt.Errorf("failed to append message %s to dead-letter stream %q: %w", xmsg.ID, sc.deadLetterStream, err)
	}

	if err := sc.client.XAck(ctx, sc.stream, sc.group, xmsg.ID).Err(); err != nil {
		return fmt.Errorf("dead-lettered message %s but failed to acknowledge original: %w", xmsg.ID, err)
	}

	return nil
}

func (sc *StreamConsumer) observeQueueMetrics(ctx context.Context) {
	const observationTimeout = 2 * time.Second

	update := func() {
		if ctx.Err() != nil || sc.instruments == nil {
			return
		}

		observeCtx, cancel := context.WithTimeout(ctx, observationTimeout)
		defer cancel()

		groups, err := sc.client.XInfoGroups(observeCtx, sc.stream).Result()
		if err != nil {
			if observeCtx.Err() == nil {
				slog.Default().ErrorContext(observeCtx, "failed to observe stream metrics", "stream", sc.stream, "group", sc.group, "error", err)
			}
			return
		}

		for _, group := range groups {
			if group.Name == sc.group {
				sc.instruments.SetQueueStats(group.Lag, group.Pending)
				return
			}
		}
	}

	update()

	ticker := time.NewTicker(sc.reclaimInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			update()
		}
	}
}

func rawPayload(value interface{}) ([]byte, bool) {
	switch value := value.(type) {
	case string:
		return []byte(value), true
	case []byte:
		return value, true
	case json.RawMessage:
		return value, true
	default:
		return nil, false
	}
}

func stringField(value interface{}) (string, bool) {
	switch value := value.(type) {
	case string:
		return value, true
	case []byte:
		return string(value), true
	case json.RawMessage:
		return string(value), true
	default:
		return "", false
	}
}

func sleepContext(ctx context.Context, duration time.Duration) bool {
	if ctx == nil {
		return false
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}
