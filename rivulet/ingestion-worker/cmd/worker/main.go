package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/chaos"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/config"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/processor"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/queue"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/storage"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/telemetry"
)

const (
	valkeyPingTimeout        = 10 * time.Second
	processorDrainTimeout    = 10 * time.Second
	processorStopTimeout     = 2 * time.Second
	chaosShutdownTimeout     = 3 * time.Second
	healthShutdownTimeout    = 3 * time.Second
	telemetryShutdownTimeout = 5 * time.Second
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config load failed: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := telemetry.InitTelemetry(ctx, cfg)
	if err != nil {
		return fmt.Errorf("telemetry init failed: %w", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), telemetryShutdownTimeout)
		defer cancel()
		if err := shutdownTelemetry(shutdownCtx); err != nil {
			slog.Error("telemetry shutdown failed", "error", err)
		}
	}()

	logger := slog.New(telemetry.NewTraceHandler(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	slog.SetDefault(logger)
	slog.Info("starting ingestion-worker", "service", cfg.ServiceName, "env", cfg.Environment, "version", cfg.GitVersion)

	inst, err := metrics.Init(ctx)
	if err != nil {
		return fmt.Errorf("metrics init failed: %w", err)
	}

	pgDB, err := storage.NewPostgresPool(ctx, &cfg.Postgres, inst)
	if err != nil {
		return fmt.Errorf("postgres init failed: %w", err)
	}
	defer pgDB.Close()

	valkeyOpts := &redis.Options{
		Addr:     net.JoinHostPort(cfg.Valkey.Host, strconv.Itoa(cfg.Valkey.Port)),
		Password: cfg.Valkey.Password,
	}
	if cfg.Valkey.TLSEnabled {
		valkeyOpts.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, ServerName: cfg.Valkey.Host}
	}

	valkeyClient := redis.NewClient(valkeyOpts)
	defer func() {
		if err := valkeyClient.Close(); err != nil {
			slog.Error("valkey client shutdown failed", "error", err)
		}
	}()

	pingCtx, pingCancel := context.WithTimeout(ctx, valkeyPingTimeout)
	pingErr := valkeyClient.Ping(pingCtx).Err()
	pingCancel()
	if pingErr != nil {
		return fmt.Errorf("valkey ping failed: %w", pingErr)
	}

	consumerCtx, consumerCancel := context.WithCancel(context.Background())
	defer consumerCancel()
	processorCtx, processorCancel := context.WithCancel(context.Background())
	defer processorCancel()

	msgChan := make(chan queue.Message, 100)
	consumerID := os.Getenv("HOSTNAME")
	if consumerID == "" {
		consumerID = "local-worker"
	}

	consumer := queue.NewStreamConsumer(valkeyClient, "rivulet.orders.in", "ingestion-workers", consumerID, inst)

	// --- Health Server (Port 8080) ---
	var isReady atomic.Bool
	healthAddr := fmt.Sprintf(":%d", cfg.Server.HTTPPort)
	healthSrv := startHealthServer(healthAddr, &isReady)
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), healthShutdownTimeout)
		defer cancel()
		if err := healthSrv.Shutdown(shutdownCtx); err != nil {
			slog.Error("health server shutdown failed", "error", err)
		}
	}()

	// --- Chaos Server (Port 8081) ---
	chaosAddr := fmt.Sprintf(":%d", cfg.Server.ChaosPort)
	chaosSrv := chaos.NewServer(chaosAddr, pgDB.Pool(), consumerCancel)
	chaosSrv.Start()
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), chaosShutdownTimeout)
		defer cancel()
		if err := chaosSrv.Shutdown(shutdownCtx); err != nil {
			slog.Error("chaos server shutdown failed", "error", err)
		}
	}()

	if err := consumer.Start(consumerCtx, msgChan); err != nil {
		return fmt.Errorf("consumer start failed: %w", err)
	}

	worker := processor.NewWorker(pgDB.Pool(), inst)
	processorDone := make(chan struct{})
	go func() {
		defer close(processorDone)
		defer func() {
			if r := recover(); r != nil {
				slog.Error("processor goroutine panicked", "panic", r, "stack", string(debug.Stack()))
			}
		}()
		worker.Run(processorCtx, msgChan)
	}()

	// Flip readiness to true once all components are running
	isReady.Store(true)

	slog.Info("ingestion-worker started successfully", "http_port", cfg.Server.HTTPPort, "chaos_port", cfg.Server.ChaosPort)

	<-ctx.Done()
	slog.Info("shutdown signal received, draining in-flight work...")

	// Flip readiness to false immediately so K8s stops routing traffic
	isReady.Store(false)

	consumerCancel()

	select {
	case <-processorDone:
		slog.Info("processor drained successfully")
	case <-time.After(processorDrainTimeout):
		slog.Warn("processor drain timed out; cancelling processor", "timeout", processorDrainTimeout)
		processorCancel()
		select {
		case <-processorDone:
			slog.Info("processor stopped after cancellation")
		case <-time.After(processorStopTimeout):
			slog.Error("processor did not stop before shutdown deadline", "timeout", processorStopTimeout)
		}
	}

	slog.Info("shutdown complete")
	return nil
}

// startHealthServer creates and starts the HTTP server for liveness and readiness probes.
func startHealthServer(addr string, isReady *atomic.Bool) *http.Server {
	mux := http.NewServeMux()

	// Liveness: Returns 200 OK if the process is alive and not deadlocked.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// Readiness: Returns 200 OK only if the worker is ready to process messages.
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if isReady.Load() {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ready"))
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("not ready"))
		}
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("health server failed", "error", err)
		}
	}()

	return srv
}
