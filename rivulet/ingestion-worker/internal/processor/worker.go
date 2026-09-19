package processor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/queue"
)

// Worker processes domain events from the queue and persists them to PostgreSQL.
type Worker struct {
	pool        *pgxpool.Pool
	instruments *metrics.Instruments
	tracer      trace.Tracer
}

// NewWorker creates a new processor worker.
func NewWorker(pool *pgxpool.Pool, inst *metrics.Instruments) *Worker {
	return &Worker{
		pool:        pool,
		instruments: inst,
		tracer:      otel.Tracer("rivulet.processor"),
	}
}

// Run starts the processing loop, reading from the message channel.
func (w *Worker) Run(ctx context.Context, msgChan <-chan queue.Message) {
	// CRITICAL: This log line is used by the E2E test to verify the binary is up-to-date.
	slog.Info("processor loop starting")
	defer slog.Info("processor loop exiting")

	for {
		select {
		case <-ctx.Done():
			slog.Info("processor context cancelled, stopping loop")
			return
		case msg, ok := <-msgChan:
			if !ok {
				slog.Info("message channel closed, stopping loop")
				return
			}
			slog.Info("received message from queue", "message_id", msg.ID)
			w.process(msg)
		}
	}
}

func (w *Worker) process(msg queue.Message) {
	traceCtx := msg.TraceCtx
	if traceCtx == nil {
		traceCtx = context.Background()
	}

	ctx, span := w.tracer.Start(
		traceCtx,
		"process_order_event",
		trace.WithSpanKind(trace.SpanKindInternal),
	)
	defer span.End()

	slog.InfoContext(ctx, "processing message", "message_id", msg.ID)

	start := time.Now()
	err := w.handleEvent(ctx, msg.Payload)
	duration := time.Since(start).Seconds()

	w.instruments.ProcessingDuration.Record(ctx, duration)

	if err != nil {
		slog.ErrorContext(ctx, "message processing failed",
			"message_id", msg.ID,
			"error", err,
			"duration_seconds", duration,
		)
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		w.instruments.MessagesFailed.Add(ctx, 1)

		var permErr *PermanentError
		if errors.As(err, &permErr) {
			slog.WarnContext(ctx, "permanent error detected, acknowledging message to drop from queue", "message_id", msg.ID)
			if ackErr := msg.Ack(ctx); ackErr != nil {
				slog.ErrorContext(ctx, "failed to ack permanent error", "message_id", msg.ID, "error", ackErr)
				span.RecordError(fmt.Errorf("failed to ack permanent error: %w", ackErr))
			}
		} else {
			slog.WarnContext(ctx, "transient error detected, leaving message in queue for retry", "message_id", msg.ID)
		}

		return
	}

	slog.InfoContext(ctx, "message processed successfully",
		"message_id", msg.ID,
		"duration_seconds", duration,
	)

	w.instruments.MessagesProcessed.Add(ctx, 1)

	if err := msg.Ack(ctx); err != nil {
		ackErr := fmt.Errorf("failed to ack message: %w", err)
		slog.ErrorContext(ctx, "ack failed", "message_id", msg.ID, "error", ackErr)
		span.RecordError(ackErr)
		span.SetStatus(codes.Error, ackErr.Error())
	}
}

func (w *Worker) handleEvent(ctx context.Context, payload json.RawMessage) error {
	var event OrderEvent

	if err := json.Unmarshal(payload, &event); err != nil {
		return NewPermanentError("invalid event schema: %v", err)
	}

	if err := event.Validate(); err != nil {
		return NewPermanentError("event validation failed: %v", err)
	}

	tx, err := w.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("failed to begin tx: %w", err)
	}
	defer func() {
		_ = tx.Rollback(context.Background())
	}()

	// 1. Deduct inventory atomically. Exactly one row must be updated.
	result, err := tx.Exec(ctx, `
		UPDATE inventory
		SET quantity = quantity - $1, version = version + 1
		WHERE sku = $2 AND quantity >= $1`,
		event.Quantity,
		event.SKU,
	)
	if err != nil {
		return fmt.Errorf("failed to update inventory: %w", err)
	}

	if result.RowsAffected() != 1 {
		return NewPermanentError(
			"insufficient inventory or unknown sku: %s",
			event.SKU,
		)
	}

	// 2. Create the order inside the same transaction.
	orderUUID, err := uuid.NewV7()
	if err != nil {
		return fmt.Errorf("failed to generate order id: %w", err)
	}
	orderID := orderUUID.String()

	_, err = tx.Exec(ctx, `
		INSERT INTO orders (id, event_id, user_id, status, created_at, updated_at)
		VALUES ($1, $2, $3, 'pending', now(), now())`,
		orderID,
		event.EventID,
		event.UserID,
	)
	if err != nil {
		return fmt.Errorf("failed to insert order: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("failed to commit tx: %w", err)
	}

	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("rivulet.event_id", event.EventID),
		attribute.String("rivulet.order_id", orderID),
		attribute.String("rivulet.sku", event.SKU),
	)

	return nil
}
