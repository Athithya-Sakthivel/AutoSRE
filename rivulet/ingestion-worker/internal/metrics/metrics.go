package metrics

import (
	"context"
	"sync"
	"sync/atomic"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

const meterName = "rivulet.ingestion-worker"

// Instruments contains the custom OpenTelemetry instruments used by the
// ingestion-worker. Init must be called once after telemetry initialization.
//
// Queue gauges are fed by SetQueueStats and exposed through asynchronous
// callbacks so metric collection never performs network I/O.
type Instruments struct {
	meter metric.Meter

	// PostgreSQL pool metrics.
	PGPoolAcquired        metric.Int64ObservableGauge
	PGPoolIdle            metric.Int64ObservableGauge
	PGPoolTotal           metric.Int64ObservableGauge
	PGPoolMax             metric.Int64ObservableGauge
	PGPoolWaiters         metric.Int64ObservableGauge
	PGPoolAcquireDuration metric.Float64ObservableGauge

	// Queue metrics.
	QueueLag     metric.Int64ObservableGauge
	QueuePending metric.Int64ObservableGauge

	// Processing metrics.
	MessagesProcessed  metric.Int64Counter
	MessagesFailed     metric.Int64Counter
	ProcessingDuration metric.Float64Histogram

	queueLag          atomic.Int64
	queuePending      atomic.Int64
	queueLagValid     atomic.Bool
	queuePendingValid atomic.Bool
}

var (
	instruments *Instruments
	initOnce    sync.Once
	initErr     error
)

// Init creates and registers all custom instruments with the global
// MeterProvider. It is intentionally process-wide so duplicate custom
// instruments and callbacks are avoided.
//
// Call Init only after the application's global MeterProvider has been
// initialized.
func Init(_ context.Context) (*Instruments, error) {
	initOnce.Do(func() {
		meter := otel.Meter(meterName)
		inst := &Instruments{meter: meter}

		var err error

		inst.PGPoolAcquired, err = meter.Int64ObservableGauge(
			"pgx.pool.acquired",
			metric.WithDescription(
				"Number of currently acquired PostgreSQL connections",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.PGPoolIdle, err = meter.Int64ObservableGauge(
			"pgx.pool.idle",
			metric.WithDescription(
				"Number of currently idle PostgreSQL connections",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.PGPoolTotal, err = meter.Int64ObservableGauge(
			"pgx.pool.total",
			metric.WithDescription(
				"Total number of PostgreSQL connections currently in the pool",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.PGPoolMax, err = meter.Int64ObservableGauge(
			"pgx.pool.max",
			metric.WithDescription(
				"Maximum number of PostgreSQL connections allowed by the pool",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		// pgxpool does not expose a current number of goroutines waiting for an
		// acquire. EmptyAcquireCount is cumulative: it counts successful acquires
		// that had to wait because the pool had no immediately available resource.
		inst.PGPoolWaiters, err = meter.Int64ObservableGauge(
			"pgx.pool.waiters",
			metric.WithDescription(
				"Cumulative number of successful PostgreSQL pool acquires that had to wait",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		// pgxpool exposes cumulative AcquireDuration and AcquireCount. This
		// observable therefore reports their current average rather than a
		// cumulative duration under a gauge name.
		inst.PGPoolAcquireDuration, err = meter.Float64ObservableGauge(
			"pgx.pool.acquire_duration.seconds",
			metric.WithDescription(
				"Average time taken by successful PostgreSQL pool acquires",
			),
			metric.WithUnit("s"),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.QueueLag, err = meter.Int64ObservableGauge(
			"rivulet.queue.lag",
			metric.WithDescription(
				"Number of stream entries still waiting to be delivered to the consumer group",
			),
			metric.WithInt64Callback(
				func(_ context.Context, observer metric.Int64Observer) error {
					if inst.queueLagValid.Load() {
						observer.Observe(inst.queueLag.Load())
					}
					return nil
				},
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.QueuePending, err = meter.Int64ObservableGauge(
			"rivulet.queue.pending",
			metric.WithDescription(
				"Number of stream entries delivered to the consumer group but not yet acknowledged",
			),
			metric.WithInt64Callback(
				func(_ context.Context, observer metric.Int64Observer) error {
					if inst.queuePendingValid.Load() {
						observer.Observe(inst.queuePending.Load())
					}
					return nil
				},
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.MessagesProcessed, err = meter.Int64Counter(
			"rivulet.messages.processed",
			metric.WithDescription(
				"Total number of messages successfully processed",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.MessagesFailed, err = meter.Int64Counter(
			"rivulet.messages.failed",
			metric.WithDescription(
				"Total number of messages that failed processing or were dead-lettered",
			),
		)
		if err != nil {
			initErr = err
			return
		}

		inst.ProcessingDuration, err = meter.Float64Histogram(
			"rivulet.processing.duration",
			metric.WithDescription(
				"Time taken to process a message",
			),
			metric.WithUnit("s"),
		)
		if err != nil {
			initErr = err
			return
		}

		instruments = inst
	})

	return instruments, initErr
}

// Meter returns the Meter that created these instruments.
//
// Components that own lifecycle-bound observable callbacks should register
// those callbacks through this Meter.
func (i *Instruments) Meter() metric.Meter {
	if i == nil {
		return nil
	}
	return i.meter
}

// SetQueueStats updates the latest queue snapshot used by the observable
// queue gauges.
//
// A negative lag means Valkey could not determine the logical lag for the
// consumer group, so the lag observation is temporarily suppressed.
func (i *Instruments) SetQueueStats(lag, pending int64) {
	if i == nil {
		return
	}

	if lag >= 0 {
		i.queueLag.Store(lag)
		i.queueLagValid.Store(true)
	} else {
		i.queueLagValid.Store(false)
	}

	if pending >= 0 {
		i.queuePending.Store(pending)
		i.queuePendingValid.Store(true)
	} else {
		i.queuePendingValid.Store(false)
	}
}
