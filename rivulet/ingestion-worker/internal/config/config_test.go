package config

import (
	"strings"
	"testing"
)

func setValidEnv(t *testing.T) {
	t.Helper()

	t.Setenv("PGHOST", "localhost")
	t.Setenv("PGPORT", "5432")
	t.Setenv("PGDATABASE", "app")
	t.Setenv("PGUSER", "app")
	t.Setenv("PGPASSWORD", "password")
	t.Setenv("PGSSLMODE", "disable")

	t.Setenv("VALKEY_HOST", "localhost")
	t.Setenv("VALKEY_PORT", "6379")
	t.Setenv("VALKEY_PASSWORD", "password")
	t.Setenv("VALKEY_TLS_ENABLED", "false")

	t.Setenv("HTTP_PORT", "8080")
	t.Setenv("CHAOS_PORT", "8081")
	t.Setenv("OTEL_SERVICE_NAME", "")
	t.Setenv("DEPLOYMENT_ENVIRONMENT", "")
	t.Setenv("GIT_VERSION", "")
}

func TestLoad_Success(t *testing.T) {
	setValidEnv(t)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.Postgres.Host != "localhost" {
		t.Fatalf("Postgres.Host = %q, want %q", cfg.Postgres.Host, "localhost")
	}
	if cfg.Postgres.Port != 5432 {
		t.Fatalf("Postgres.Port = %d, want %d", cfg.Postgres.Port, 5432)
	}
	if cfg.Postgres.SSLMode != "disable" {
		t.Fatalf("Postgres.SSLMode = %q, want %q", cfg.Postgres.SSLMode, "disable")
	}
	if cfg.Valkey.Port != 6379 {
		t.Fatalf("Valkey.Port = %d, want %d", cfg.Valkey.Port, 6379)
	}
	if cfg.Valkey.TLSEnabled {
		t.Fatal("Valkey.TLSEnabled = true, want false")
	}
	if cfg.Server.HTTPPort != 8080 {
		t.Fatalf("Server.HTTPPort = %d, want %d", cfg.Server.HTTPPort, 8080)
	}
	if cfg.Server.ChaosPort != 8081 {
		t.Fatalf("Server.ChaosPort = %d, want %d", cfg.Server.ChaosPort, 8081)
	}
	if cfg.ServiceName != "ingestion-worker" {
		t.Fatalf("ServiceName = %q, want %q", cfg.ServiceName, "ingestion-worker")
	}
	if cfg.Environment != "evaluation" {
		t.Fatalf("Environment = %q, want %q", cfg.Environment, "evaluation")
	}
	if cfg.GitVersion != "unknown" {
		t.Fatalf("GitVersion = %q, want %q", cfg.GitVersion, "unknown")
	}
}

func TestLoad_MissingRequired(t *testing.T) {
	setValidEnv(t)
	t.Setenv("PGHOST", "")

	_, err := Load()
	if err == nil {
		t.Fatal("Load() error = nil, want missing PGHOST error")
	}
	if got := err.Error(); got != "PGHOST is required" {
		t.Fatalf("Load() error = %q, want %q", got, "PGHOST is required")
	}
}

func TestLoad_InvalidPort(t *testing.T) {
	setValidEnv(t)
	t.Setenv("VALKEY_PORT", "99999")

	_, err := Load()
	if err == nil {
		t.Fatal("Load() error = nil, want invalid port error")
	}
	if got := err.Error(); !strings.HasPrefix(got, "invalid VALKEY_PORT") {
		t.Fatalf("Load() error = %q, want prefix %q", got, "invalid VALKEY_PORT")
	}
}

func TestLoad_InvalidBool(t *testing.T) {
	setValidEnv(t)
	t.Setenv("VALKEY_TLS_ENABLED", "not-a-bool")

	_, err := Load()
	if err == nil {
		t.Fatal("Load() error = nil, want invalid bool error")
	}
	if got := err.Error(); !strings.HasPrefix(got, "invalid VALKEY_TLS_ENABLED") {
		t.Fatalf("Load() error = %q, want prefix %q", got, "invalid VALKEY_TLS_ENABLED")
	}
}

func TestLoad_InvalidSSLMode(t *testing.T) {
	setValidEnv(t)
	t.Setenv("PGSSLMODE", "bogus")

	_, err := Load()
	if err == nil {
		t.Fatal("Load() error = nil, want invalid PGSSLMODE error")
	}
	if got := err.Error(); got != `invalid PGSSLMODE: "bogus"` {
		t.Fatalf("Load() error = %q, want %q", got, `invalid PGSSLMODE: "bogus"`)
	}
}
