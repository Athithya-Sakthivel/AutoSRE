package config

import (
	"fmt"
	"os"
	"strconv"
)

// PostgresConfig holds discrete connection parameters for pgxpool.
// Connection strings are intentionally not constructed here, avoiding URL
// escaping and interpolation errors at the configuration boundary.
type PostgresConfig struct {
	Host     string
	Port     int
	Database string
	User     string
	Password string
	SSLMode  string
}

// ValkeyConfig holds discrete connection parameters for go-redis.
type ValkeyConfig struct {
	Host       string
	Port       int
	Password   string
	TLSEnabled bool
}

// ServerConfig defines the ports for the application and chaos injection planes.
type ServerConfig struct {
	HTTPPort  int // Public: health checks and Prometheus metrics.
	ChaosPort int // Private: fault-injection endpoints; never exposed via a Kubernetes Service.
}

// Config is the root configuration struct for the ingestion-worker.
type Config struct {
	Postgres    PostgresConfig
	Valkey      ValkeyConfig
	Server      ServerConfig
	ServiceName string
	Environment string
	GitVersion  string
}

// Load reads environment variables and validates them.
func Load() (*Config, error) {
	cfg := &Config{}

	cfg.Postgres.Host = os.Getenv("PGHOST")
	if cfg.Postgres.Host == "" {
		return nil, fmt.Errorf("PGHOST is required")
	}

	cfg.Postgres.Database = os.Getenv("PGDATABASE")
	if cfg.Postgres.Database == "" {
		return nil, fmt.Errorf("PGDATABASE is required")
	}

	cfg.Postgres.User = os.Getenv("PGUSER")
	if cfg.Postgres.User == "" {
		return nil, fmt.Errorf("PGUSER is required")
	}

	cfg.Postgres.Password = os.Getenv("PGPASSWORD")
	// Passwords can technically be empty for some PostgreSQL deployments, but
	// staging/production parity requires an explicitly non-empty password.
	if cfg.Postgres.Password == "" {
		return nil, fmt.Errorf("PGPASSWORD is required")
	}

	pgPort, err := getEnvPort("PGPORT", 5432)
	if err != nil {
		return nil, fmt.Errorf("invalid PGPORT: %w", err)
	}
	cfg.Postgres.Port = pgPort

	cfg.Postgres.SSLMode = os.Getenv("PGSSLMODE")
	if cfg.Postgres.SSLMode == "" {
		cfg.Postgres.SSLMode = "disable"
	}
	if !validSSLMode(cfg.Postgres.SSLMode) {
		return nil, fmt.Errorf("invalid PGSSLMODE: %q", cfg.Postgres.SSLMode)
	}

	cfg.Valkey.Host = os.Getenv("VALKEY_HOST")
	if cfg.Valkey.Host == "" {
		return nil, fmt.Errorf("VALKEY_HOST is required")
	}

	vPort, err := getEnvPort("VALKEY_PORT", 6379)
	if err != nil {
		return nil, fmt.Errorf("invalid VALKEY_PORT: %w", err)
	}
	cfg.Valkey.Port = vPort
	cfg.Valkey.Password = os.Getenv("VALKEY_PASSWORD")

	tlsEnabled, err := getEnvBool("VALKEY_TLS_ENABLED", false)
	if err != nil {
		return nil, fmt.Errorf("invalid VALKEY_TLS_ENABLED: %w", err)
	}
	cfg.Valkey.TLSEnabled = tlsEnabled

	httpPort, err := getEnvPort("HTTP_PORT", 8080)
	if err != nil {
		return nil, fmt.Errorf("invalid HTTP_PORT: %w", err)
	}
	cfg.Server.HTTPPort = httpPort

	chaosPort, err := getEnvPort("CHAOS_PORT", 8081)
	if err != nil {
		return nil, fmt.Errorf("invalid CHAOS_PORT: %w", err)
	}
	cfg.Server.ChaosPort = chaosPort

	cfg.ServiceName = os.Getenv("OTEL_SERVICE_NAME")
	if cfg.ServiceName == "" {
		cfg.ServiceName = "ingestion-worker"
	}

	cfg.Environment = os.Getenv("DEPLOYMENT_ENVIRONMENT")
	if cfg.Environment == "" {
		cfg.Environment = "evaluation"
	}

	cfg.GitVersion = os.Getenv("GIT_VERSION")
	if cfg.GitVersion == "" {
		cfg.GitVersion = "unknown"
	}

	return cfg, nil
}

func getEnvPort(key string, defaultVal int) (int, error) {
	return getEnvInt(key, defaultVal, 1, 65535)
}

func getEnvInt(key string, defaultVal, minVal, maxVal int) (int, error) {
	valStr := os.Getenv(key)
	if valStr == "" {
		return defaultVal, nil
	}

	val, err := strconv.Atoi(valStr)
	if err != nil {
		return 0, err
	}
	if val < minVal || val > maxVal {
		return 0, fmt.Errorf("value %d out of range [%d,%d]", val, minVal, maxVal)
	}
	return val, nil
}

func getEnvBool(key string, defaultVal bool) (bool, error) {
	valStr := os.Getenv(key)
	if valStr == "" {
		return defaultVal, nil
	}

	val, err := strconv.ParseBool(valStr)
	if err != nil {
		return false, err
	}
	return val, nil
}

func validSSLMode(mode string) bool {
	switch mode {
	case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
		return true
	default:
		return false
	}
}
