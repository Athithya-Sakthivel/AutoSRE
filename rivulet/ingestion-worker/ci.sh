#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Formatting Go source..."
find . \
    -type f \
    -name '*.go' \
    -not -path './vendor/*' \
    -exec gofmt -w {} +

echo "==> Synchronizing Go module dependencies..."
go mod tidy

echo "==> Running race-enabled tests..."
go test -race -count=1 -v ./...

echo "==> Running go vet..."
go vet ./...

docker build --no-cache --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t rivulet/ingestion-worker:latest .

docker run --rm   -e PGHOST=localhost -e PGPORT=5432 -e PGDATABASE=app   -e PGUSER=app -e PGPASSWORD=test   -e VALKEY_HOST=localhost -e VALKEY_PORT=6379   rivulet/ingestion-worker:latest 2>&1 | head -1 | jq -r '.version'

echo "==> All checks passed"
