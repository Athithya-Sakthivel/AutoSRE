package storage

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/config"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
)

const (
	defaultMaxConns        = 20
	defaultMinConns        = 2
	defaultMaxConnLifetime = 30 * time.Minute
	defaultMaxConnIdleTime = 5 * time.Minute
	defaultHealthCheck     = 30 * time.Second
)

// PostgresDB wraps a pgxpool.Pool and owns its pool-metric callback
// registration.
type PostgresDB struct {
	pool         *pgxpool.Pool
	registration metric.Registration
	closeOnce    sync.Once
}

// NewPostgresPool creates a PostgreSQL connection pool, verifies
// connectivity, and registers pool statistics with OpenTelemetry.
func NewPostgresPool(
	ctx context.Context,
	cfg *config.PostgresConfig,
	inst *metrics.Instruments,
) (*PostgresDB, error) {
	if ctx == nil {
		return nil, fmt.Errorf("postgres context must not be nil")
	}
	if cfg == nil {
		return nil, fmt.Errorf("postgres config must not be nil")
	}
	if inst == nil {
		return nil, fmt.Errorf("metrics instruments must not be nil")
	}
	if strings.TrimSpace(cfg.Host) == "" {
		return nil, fmt.Errorf("postgres host must not be empty")
	}
	if cfg.Port < 1 || cfg.Port > 65535 {
		return nil, fmt.Errorf("postgres port out of range: %d", cfg.Port)
	}

	connString, err := postgresConnString(cfg)
	if err != nil {
		return nil, fmt.Errorf(
			"failed to build postgres connection string: %w",
			err,
		)
	}

	poolCfg, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("failed to parse pool config: %w", err)
	}

	poolCfg.MaxConns = defaultMaxConns
	poolCfg.MinConns = defaultMinConns
	poolCfg.MaxConnLifetime = defaultMaxConnLifetime
	poolCfg.MaxConnIdleTime = defaultMaxConnIdleTime
	poolCfg.HealthCheckPeriod = defaultHealthCheck

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create postgres pool: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("failed to ping postgres: %w", err)
	}

	db := &PostgresDB{pool: pool}

	dbAttr := attribute.String("db.system.name", "postgresql")

	registration, err := inst.Meter().RegisterCallback(
		func(_ context.Context, observer metric.Observer) error {
			stats := pool.Stat()
			attrs := metric.WithAttributes(dbAttr)

			observer.ObserveInt64(
				inst.PGPoolAcquired,
				int64(stats.AcquiredConns()),
				attrs,
			)
			observer.ObserveInt64(
				inst.PGPoolIdle,
				int64(stats.IdleConns()),
				attrs,
			)
			observer.ObserveInt64(
				inst.PGPoolTotal,
				int64(stats.TotalConns()),
				attrs,
			)
			observer.ObserveInt64(
				inst.PGPoolMax,
				int64(stats.MaxConns()),
				attrs,
			)
			observer.ObserveInt64(
				inst.PGPoolWaiters,
				stats.EmptyAcquireCount(),
				attrs,
			)

			acquireCount := stats.AcquireCount()
			averageAcquireSeconds := float64(0)
			if acquireCount > 0 {
				averageAcquireSeconds =
					stats.AcquireDuration().Seconds() /
						float64(acquireCount)
			}

			observer.ObserveFloat64(
				inst.PGPoolAcquireDuration,
				averageAcquireSeconds,
				attrs,
			)

			return nil
		},
		inst.PGPoolAcquired,
		inst.PGPoolIdle,
		inst.PGPoolTotal,
		inst.PGPoolMax,
		inst.PGPoolWaiters,
		inst.PGPoolAcquireDuration,
	)
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf(
			"failed to register postgres pool metrics: %w",
			err,
		)
	}

	db.registration = registration
	return db, nil
}

func postgresConnString(cfg *config.PostgresConfig) (string, error) {
	host := strings.TrimSpace(cfg.Host)
	host = strings.Trim(host, "[]")

	if host == "" {
		return "", fmt.Errorf("postgres host must not be empty")
	}
	if cfg.Database == "" {
		return "", fmt.Errorf("postgres database must not be empty")
	}

	u := &url.URL{
		Scheme: "postgres",
		Host:   net.JoinHostPort(host, strconv.Itoa(cfg.Port)),
		Path:   "/" + cfg.Database,
	}

	if cfg.User != "" || cfg.Password != "" {
		u.User = url.UserPassword(cfg.User, cfg.Password)
	}

	sslMode := strings.TrimSpace(strings.ToLower(cfg.SSLMode))
	if sslMode != "" {
		query := u.Query()
		query.Set("sslmode", sslMode)
		u.RawQuery = query.Encode()
	}

	return u.String(), nil
}

// Ping checks database connectivity.
func (db *PostgresDB) Ping(ctx context.Context) error {
	if db == nil || db.pool == nil {
		return fmt.Errorf("postgres pool is nil")
	}
	if ctx == nil {
		return fmt.Errorf("postgres context must not be nil")
	}
	return db.pool.Ping(ctx)
}

// Pool returns the underlying pgxpool.Pool for query execution.
func (db *PostgresDB) Pool() *pgxpool.Pool {
	if db == nil {
		return nil
	}
	return db.pool
}

// Close unregisters metric callbacks and closes the pool.
// It is safe to call Close multiple times.
func (db *PostgresDB) Close() {
	if db == nil {
		return
	}

	db.closeOnce.Do(func() {
		if db.registration != nil {
			_ = db.registration.Unregister()
		}
		if db.pool != nil {
			db.pool.Close()
		}
	})
}
