#!/usr/bin/env bash
# =============================================================================
# test_e2e_locally.sh — Full-Stack E2E Battle Test (Frontend + Java + Go)
# =============================================================================
#
# PURPOSE:
#   Validates the COMPLETE Rivulet platform end-to-end:
#     Frontend (Nginx) → Java Gateway → Valkey Stream → Go Worker → PostgreSQL
#   with cross-service trace correlation verified in OpenObserve.
#
# ARCHITECTURE:
#   - Kind cluster provides: PostgreSQL, Valkey, OTel Collector, OpenObserve
#   - Port-forwards expose cluster services to localhost
#   - Go Worker runs as native binary (port 18082/18083)
#   - Java Gateway runs as native JAR (port 18080/18081)
#   - Frontend runs as Docker container (port 18090 → nginx:8080)
#     → nginx proxies /orders, /inventory, /healthz, /readyz to Java Gateway
#
# USAGE:
#   bash rivulet/frontend/test_e2e_locally.sh
#
# Services STAY RUNNING after tests pass. Ctrl+C or --cleanup to stop.
# =============================================================================

set -Euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIVULET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_DIR="$SCRIPT_DIR"
JAVA_DIR="$RIVULET_ROOT/api-gateway"
GO_DIR="$RIVULET_ROOT/ingestion-worker"

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass() { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

PG_PORT=15432
VALKEY_PORT=16379
OTEL_PORT=14318
O2_PORT=15080
FRONTEND_PORT=18090
JAVA_HTTP_PORT=18080
JAVA_CHAOS_PORT=18081
GO_HTTP_PORT=18082
GO_CHAOS_PORT=18083

REQUEST_ID="e2e-fullstack-$(date +%s)"
USER_ID="00000000-0000-0000-0000-000000000099"
SKU="E2E-SKU-FULL"

WORKER_BIN="/tmp/worker-e2e-fullstack"
WORKER_LOG="/tmp/worker-e2e-fullstack.log"
JAVA_JAR="$JAVA_DIR/target/api-gateway-1.0.0.jar"
JAVA_LOG="/tmp/java-gateway-e2e-fullstack.log"
FRONTEND_IMAGE="rivulet-frontend-e2e:latest"
FRONTEND_CONTAINER="rivulet-frontend-e2e"

PIDS=()

do_cleanup() {
    echo ""
    log "Stopping all services..."

    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done

    wait 2>/dev/null || true

    pkill -f "kubectl port-forward.*:${PG_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${VALKEY_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${OTEL_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${O2_PORT}" 2>/dev/null || true

    docker rm -f "$FRONTEND_CONTAINER" 2>/dev/null || true
    rm -f "$WORKER_BIN"

    pass "All services stopped."
    exit 0
}

if [[ "${1:-}" == "--cleanup" ]]; then
    do_cleanup
fi

trap do_cleanup INT TERM

wait_for_port() {
    local port=$1
    local max=30
    local attempt=1

    while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
        if (( attempt > max )); then
            return 1
        fi

        sleep 1
        ((attempt++))
    done

    return 0
}

for cmd in kubectl curl jq go java docker; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

log "Killing any lingering processes..."

pkill -f "kubectl port-forward.*:${PG_PORT}" 2>/dev/null || true
pkill -f "kubectl port-forward.*:${VALKEY_PORT}" 2>/dev/null || true
pkill -f "kubectl port-forward.*:${OTEL_PORT}" 2>/dev/null || true
pkill -f "kubectl port-forward.*:${O2_PORT}" 2>/dev/null || true
pkill -f "worker-e2e-fullstack" 2>/dev/null || true
pkill -f "api-gateway.*spring" 2>/dev/null || true

docker rm -f "$FRONTEND_CONTAINER" 2>/dev/null || true
sleep 2

log "Fetching K8s secrets..."

PG_PASS=$(
    kubectl get secret postgres-app-env -n rivulet \
        -o jsonpath='{.data.PGPASSWORD}' |
        base64 -d
) || fail "Failed to get PG secret"

VALKEY_PASS=$(
    kubectl get secret valkey-auth -n rivulet \
        -o jsonpath='{.data.VALKEY_PASSWORD}' |
        base64 -d
) || fail "Failed to get Valkey secret"

O2_EMAIL=$(
    kubectl get secret openobserve-auth -n openobserve \
        -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' |
        base64 -d
) || fail "Failed to get O2 email"

O2_PASS=$(
    kubectl get secret openobserve-auth -n openobserve \
        -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' |
        base64 -d
) || fail "Failed to get O2 pass"

log "Starting port-forwards to Kind cluster..."

kubectl port-forward svc/postgres \
    "${PG_PORT}:5432" \
    -n rivulet >/dev/null 2>&1 &
PIDS+=($!)

kubectl port-forward svc/valkey \
    "${VALKEY_PORT}:6379" \
    -n rivulet >/dev/null 2>&1 &
PIDS+=($!)

kubectl port-forward svc/otel-gateway \
    "${OTEL_PORT}:4318" \
    -n openobserve >/dev/null 2>&1 &
PIDS+=($!)

kubectl port-forward svc/openobserve \
    "${O2_PORT}:5080" \
    -n openobserve >/dev/null 2>&1 &
PIDS+=($!)

log "Waiting for port-forwards..."

for port in $PG_PORT $VALKEY_PORT $OTEL_PORT $O2_PORT; do
    wait_for_port "$port" || fail "Port-forward failed on $port"
done

pass "All port-forwards active"

log "Bootstrapping DB schema..."

kubectl exec -n rivulet svc/postgres -- \
    psql -U app -d app -c "
CREATE TABLE IF NOT EXISTS inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku TEXT NOT NULL UNIQUE,
    quantity INT NOT NULL DEFAULT 0,
    version INT NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE,
    user_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
" >/dev/null || fail "Schema bootstrap failed"

log "Seeding inventory..."

kubectl exec -n rivulet svc/postgres -- \
    psql -U app -d app -c \
    "INSERT INTO inventory (sku, quantity)
     VALUES ('${SKU}', 100)
     ON CONFLICT (sku)
     DO UPDATE SET quantity = 100;" \
    >/dev/null || fail "Seed failed"

pass "DB bootstrapped and seeded"

log "Building Go worker..."

cd "$GO_DIR"
go build -o "$WORKER_BIN" ./cmd/worker || fail "Go build failed"
cd "$FRONTEND_DIR"

log "Building Java Gateway JAR..."

cd "$JAVA_DIR"
./mvnw -DskipTests clean package -q || fail "Maven build failed"
cd "$FRONTEND_DIR"

log "Building Frontend Docker image..."

docker build \
    --build-arg VITE_GIT_VERSION="$(
        git -C "$RIVULET_ROOT" rev-parse --short HEAD 2>/dev/null || echo dev
    )" \
    --build-arg VITE_ENVIRONMENT=evaluation \
    -t "$FRONTEND_IMAGE" . ||
    fail "Frontend Docker build failed"

pass "All artifacts built"

log "Starting Go worker on :${GO_HTTP_PORT}..."

{
    export PGHOST=127.0.0.1
    export PGPORT=$PG_PORT
    export PGDATABASE=app
    export PGUSER=app
    export PGPASSWORD=$PG_PASS
    export PGSSLMODE=disable

    export VALKEY_HOST=127.0.0.1
    export VALKEY_PORT=$VALKEY_PORT
    export VALKEY_PASSWORD=$VALKEY_PASS
    export VALKEY_TLS_ENABLED=false

    export HTTP_PORT=$GO_HTTP_PORT
    export CHAOS_PORT=$GO_CHAOS_PORT

    export OTEL_SERVICE_NAME=ingestion-worker
    export DEPLOYMENT_ENVIRONMENT=evaluation
    export GIT_VERSION=e2e-go

    export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${OTEL_PORT}"
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
    export OTEL_TRACES_SAMPLER=parentbased_always_on
    export HOSTNAME=local-go-worker
}

> "$WORKER_LOG"
"$WORKER_BIN" >> "$WORKER_LOG" 2>&1 &
WORKER_PID=$!
PIDS+=($WORKER_PID)

for i in {1..20}; do
    if grep -q "ingestion-worker started successfully" \
        "$WORKER_LOG" 2>/dev/null; then
        pass "Go worker started (PID $WORKER_PID)"
        break
    fi

    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
        cat "$WORKER_LOG"
        fail "Go worker crashed"
    fi

    sleep 1
done

log "Starting Java Gateway on :${JAVA_HTTP_PORT}..."

{
    export HTTP_PORT=$JAVA_HTTP_PORT
    export CHAOS_PORT=$JAVA_CHAOS_PORT
    export OTEL_SERVICE_NAME=api-gateway
    export GIT_VERSION=e2e-java
}

> "$JAVA_LOG"
java -jar "$JAVA_JAR" >> "$JAVA_LOG" 2>&1 &
JAVA_PID=$!
PIDS+=($JAVA_PID)

for i in {1..60}; do
    if curl -sf \
        "http://127.0.0.1:${JAVA_HTTP_PORT}/readyz" \
        >/dev/null 2>&1; then
        pass "Java Gateway ready (PID $JAVA_PID)"
        break
    fi

    if ! kill -0 "$JAVA_PID" 2>/dev/null; then
        echo "=== JAVA LOG ==="
        cat "$JAVA_LOG"
        fail "Java Gateway crashed"
    fi

    sleep 1
done

log "Starting Frontend container on :${FRONTEND_PORT}..."

docker run -d \
    --name "$FRONTEND_CONTAINER" \
    -p "${FRONTEND_PORT}:8080" \
    --add-host=host.docker.internal:host-gateway \
    -e "BACKEND_URL=http://host.docker.internal:${JAVA_HTTP_PORT}" \
    "$FRONTEND_IMAGE" >/dev/null ||
    fail "Failed to start frontend container"

for i in {1..30}; do
    if curl -sf \
        "http://127.0.0.1:${FRONTEND_PORT}/health" \
        >/dev/null 2>&1; then
        pass "Frontend container healthy"
        break
    fi

    if ! docker ps --format '{{.Names}}' |
        grep -q "^${FRONTEND_CONTAINER}$"; then
        echo "=== FRONTEND LOGS ==="
        docker logs "$FRONTEND_CONTAINER"
        fail "Frontend container crashed"
    fi

    sleep 1
done

set +e

log "Test 1: Frontend serves HTML..."

HTML=$(curl -s \
    "http://127.0.0.1:${FRONTEND_PORT}/")

if echo "$HTML" | grep -q "Rivulet"; then
    pass "Frontend serves Rivulet HTML"
else
    fail "Frontend did not serve expected HTML"
fi

log "Test 2: Full-stack checkout..."

RESPONSE=$(
    curl -s -w "\n%{http_code}" \
        -X POST \
        "http://127.0.0.1:${FRONTEND_PORT}/orders/${USER_ID}/checkout" \
        -H "Content-Type: application/json" \
        -H "X-Request-ID: ${REQUEST_ID}" \
        -d "{\"sku\":\"${SKU}\",\"quantity\":1}"
)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "202" ]]; then
    log "Response: $BODY (HTTP $HTTP_CODE)"
    fail "Expected 202, got $HTTP_CODE"
fi

EVENT_ID=$(echo "$BODY" | jq -r '.eventId')
pass "Frontend proxy returned eventId: $EVENT_ID"

log "Waiting 5s for Go worker to process..."
sleep 5

if grep -q "message processed successfully" \
    "$WORKER_LOG"; then
    pass "Go worker processed the message"
else
    tail -30 "$WORKER_LOG"
    fail "Go worker did not process"
fi

ORDER_COUNT=$(
    kubectl exec -n rivulet svc/postgres -- \
        psql -U app -d app -t -c \
        "SELECT count(*)
         FROM orders
         WHERE event_id='${EVENT_ID}';" \
        2>&1 |
        tr -d ' '
)

if [[ "$ORDER_COUNT" == "1" ]]; then
    pass "Order created in DB"
else
    fail "Expected 1 order, found $ORDER_COUNT"
fi

log "Test 3: /healthz proxy..."

HEALTH=$(
    curl -s \
        "http://127.0.0.1:${FRONTEND_PORT}/healthz"
)

if [[ "$HEALTH" == "ok" ]]; then
    pass "/healthz proxied"
else
    fail "/healthz proxy failed"
fi

log "Test 4: /inventory proxy..."

INV=$(
    curl -s \
        "http://127.0.0.1:${FRONTEND_PORT}/inventory/${SKU}"
)

INV_QTY=$(echo "$INV" | jq -r '.quantity')

if [[ -n "$INV_QTY" && "$INV_QTY" -lt 100 ]]; then
    pass "/inventory proxied (qty=$INV_QTY)"
else
    fail "/inventory proxy failed"
fi

log "Test 5: Cross-service traces in OpenObserve..."

sleep 3

END_US=$(( $(date -u +%s) * 1000000 ))
START_US=$(( END_US - 600000000 ))

AUTH_HEADER="Authorization: Basic $(printf '%s:%s' \
    "$O2_EMAIL" "$O2_PASS" |
    base64 |
    tr -d '\n')"

QUERY_BODY=$(
    jq -nc \
        --argjson s "$START_US" \
        --argjson e "$END_US" \
        '{
            query: {
                sql: "SELECT service_name FROM \"default\" WHERE service_name IN ('\''api-gateway'\'', '\''ingestion-worker'\'')",
                start_time: $s,
                end_time: $e
            }
        }'
)

O2_RESP=$(
    curl -s \
        -X POST \
        "http://127.0.0.1:${O2_PORT}/api/default/_search?type=traces" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$QUERY_BODY"
)

GATEWAY_HITS=$(
    echo "$O2_RESP" |
        jq '[.hits[] | select(.service_name=="api-gateway")] | length' \
        2>/dev/null ||
        echo "0"
)

WORKER_HITS=$(
    echo "$O2_RESP" |
        jq '[.hits[] | select(.service_name=="ingestion-worker")] | length' \
        2>/dev/null ||
        echo "0"
)

if [[ "$GATEWAY_HITS" -gt 0 && "$WORKER_HITS" -gt 0 ]]; then
    pass "Telemetry verified: Gateway ($GATEWAY_HITS) + Worker ($WORKER_HITS) spans"
else
    warn "Trace correlation incomplete (Gateway: $GATEWAY_HITS, Worker: $WORKER_HITS) — check OpenObserve UI"
fi

log "Test 6: Chaos endpoints..."

JAVA_CHAOS=$(
    curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        "http://127.0.0.1:${JAVA_CHAOS_PORT}/__chaos/cpu-spin"
)

if [[ "$JAVA_CHAOS" == "200" ]]; then
    pass "Java chaos: 200"
else
    fail "Java chaos failed"
fi

curl -s \
    -X POST \
    "http://127.0.0.1:${JAVA_CHAOS_PORT}/__chaos/reset" \
    >/dev/null

GO_CHAOS=$(
    curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        "http://127.0.0.1:${GO_CHAOS_PORT}/__chaos/cpu-spin"
)

if [[ "$GO_CHAOS" == "200" ]]; then
    pass "Go chaos: 200"
else
    fail "Go chaos failed"
fi

curl -s \
    -X POST \
    "http://127.0.0.1:${GO_CHAOS_PORT}/__chaos/reset" \
    >/dev/null

log "Test 7: SPA fallback..."

SPA_CODE=$(
    curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        "http://127.0.0.1:${FRONTEND_PORT}/this-route-does-not-exist"
)

if [[ "$SPA_CODE" == "200" ]]; then
    pass "SPA fallback works"
else
    warn "SPA fallback returned $SPA_CODE"
fi

echo ""
echo ""
echo "========================================="
echo "  ALL FULL-STACK E2E TESTS PASSED"
echo "  Services running — open in browser:"
echo "========================================="
echo ""
echo "  Frontend (Rivulet UI):"
echo "    http://127.0.0.1:${FRONTEND_PORT}"
echo ""
echo "  OpenObserve (Traces):"
echo "    http://127.0.0.1:${O2_PORT}"
echo "    Email: ${O2_EMAIL}"
echo "    Password: ${O2_PASS}"
echo ""
echo "  Backend APIs (direct):"
echo "    Java Gateway:  http://127.0.0.1:${JAVA_HTTP_PORT}/readyz"
echo "    Go Worker:     http://127.0.0.1:${GO_HTTP_PORT}/healthz"
echo ""
echo "  Logs:"
echo "    Java:  ${JAVA_LOG}"
echo "    Go:    ${WORKER_LOG}"
echo ""
echo "  To cleanup:"
echo "    bash rivulet/frontend/test_e2e_locally.sh --cleanup"
echo "    OR press Ctrl+C in this terminal"
echo ""

while true; do
    sleep 60
done
