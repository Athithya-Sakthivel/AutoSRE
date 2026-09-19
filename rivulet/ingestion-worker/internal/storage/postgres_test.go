package storage

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/config"
	"github.com/Athithya-Sakthivel/AutoSRE/rivulet/ingestion-worker/internal/metrics"
)

func TestNewPostgresPool_InvalidHost(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	cfg := &config.PostgresConfig{
		Host:     "127.0.0.1",
		Port:     1,
		Database: "test",
		User:     "test",
		Password: "test",
		SSLMode:  "disable",
	}

	inst, err := metrics.Init(ctx)
	require.NoError(t, err)

	db, err := NewPostgresPool(ctx, cfg, inst)
	if db != nil {
		t.Cleanup(db.Close)
	}

	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to ping postgres")
}
