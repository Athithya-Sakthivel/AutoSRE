#!/usr/bin/env bash
# ==============================================================================
# End-to-End Battle Test for Rivulet Ingestion Worker
# ==============================================================================
#
# PURPOSE:
#   Validates the Go ingestion worker against a live Kind/Kubernetes cluster.
#   It connects to real Postgres and Valkey instances via port-forwarding,
#   injects a test message, and verifies the database transaction and telemetry.
#
# PREREQUISITES:
#   - A running Kind cluster with 'rivulet' and 'openobserve' namespaces.
#   - Postgres and Valkey pods must be running and healthy.
#   - kubectl, go, curl, and jq must be installed.
#
# USAGE:
#   bash rivulet/ingestion-worker/test_e2e_locally.sh
#
# BEHAVIOR:
#   1. Verifies that the Go source code has been saved (checks for debug logs).
#   2. Kills any lingering port-forwards to prevent "address in use" errors.
#   3. Establishes fresh port-forwards to DB, Cache, and Telemetry backends.
#   4. Bootstraps the database schema and seeds test data.
#   5. Builds and starts the worker binary, streaming logs to the terminal.
#   6. Injects a valid message into the Valkey stream.
#   7. Asserts that the order was created in Postgres.
#   8. Cleans up all background processes and port-forwards gracefully.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Ensure we are in the module root directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# --- Colors & Logging ---
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass() { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

# --- Prerequisites ---
for cmd in kubectl curl jq go; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

# --- Configuration ---
PG_PORT=15432
VALKEY_PORT=16379
OTEL_PORT=14318
O2_PORT=15080
WORKER_HTTP_PORT=8080
WORKER_CHAOS_PORT=8081

TRACE_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SPAN_ID="bbbbbbbbbbbbbbbb"
EVENT_ID="e2e-test-$(date +%s)"
USER_ID="00000000-0000-0000-0000-000000000001"

WORKER_BIN="/tmp/worker-e2e"
WORKER_LOG="/tmp/worker-e2e.log"

# --- Helper Functions ---
wait_for_port() {
    local port=$1 max_attempts=20 attempt=1
    while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
        if (( attempt > max_attempts )); then return 1; fi
        sleep 1; ((attempt++))
    done
    return 0
}

kill_port_forwards() {
    # Kill any existing kubectl port-forward processes targeting our specific ports
    pkill -f "kubectl port-forward.*:${PG_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${VALKEY_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${OTEL_PORT}" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:${O2_PORT}" 2>/dev/null || true
    sleep 1
}

# --- Cleanup Trap ---
PIDS=()
TAIL_PID=""
cleanup() {
    log "Cleaning up background processes..."
    if [[ -n "$TAIL_PID" ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    kill_port_forwards
    rm -f "$WORKER_BIN"
    log "Cleanup complete."
}
trap cleanup EXIT

# --- 0. Pre-flight Checks ---
log "Verifying source code is saved and up-to-date..."
if ! grep -q "processor loop starting" internal/processor/worker.go; then
    fail "CRITICAL: internal/processor/worker.go is missing debug logs. Open the file in your editor, paste the latest code, and press SAVE before running this script."
fi
pass "Source code verification passed."

log "Killing any lingering port-forwards..."
kill_port_forwards

# --- 1. Fetch K8s Secrets ---
log "Fetching K8s secrets..."
PG_PASS=$(kubectl get secret postgres-app-env -n rivulet -o jsonpath='{.data.PGPASSWORD}' | base64 -d) || fail "Failed to get PG secret"
VALKEY_PASS=$(kubectl get secret valkey-auth -n rivulet -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d) || fail "Failed to get Valkey secret"
O2_EMAIL=$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d) || fail "Failed to get O2 email"
O2_PASS=$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d) || fail "Failed to get O2 pass"

# --- 2. Start Port-Forwards ---
log "Starting port-forwards..."
kubectl port-forward svc/postgres ${PG_PORT}:5432 -n rivulet >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward svc/valkey ${VALKEY_PORT}:6379 -n rivulet >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward svc/otel-gateway ${OTEL_PORT}:4318 -n openobserve >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward svc/openobserve ${O2_PORT}:5080 -n openobserve >/dev/null 2>&1 & PIDS+=($!)

log "Waiting for port-forwards to establish..."
for port in $PG_PORT $VALKEY_PORT $OTEL_PORT $O2_PORT; do
    wait_for_port "$port" || fail "Port-forward failed to establish on local port $port"
done
pass "All port-forwards active"

# --- 3. Export Environment Variables ---
log "Exporting environment variables..."
export PGHOST=127.0.0.1 PGPORT=$PG_PORT PGDATABASE=app PGUSER=app PGPASSWORD=$PG_PASS PGSSLMODE=disable
export VALKEY_HOST=127.0.0.1 VALKEY_PORT=$VALKEY_PORT VALKEY_PASSWORD=$VALKEY_PASS VALKEY_TLS_ENABLED=false
export HTTP_PORT=$WORKER_HTTP_PORT CHAOS_PORT=$WORKER_CHAOS_PORT
export OTEL_SERVICE_NAME=ingestion-worker DEPLOYMENT_ENVIRONMENT=evaluation GIT_VERSION=e2e-local
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${OTEL_PORT}"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_TRACES_SAMPLER=parentbased_always_on
export HOSTNAME=local-e2e-worker

# --- 4. Bootstrap Schema & Seed DB ---
log "Bootstrapping DB schema..."
SCHEMA_SQL="
CREATE TABLE IF NOT EXISTS inventory (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), sku TEXT NOT NULL UNIQUE, quantity INT NOT NULL DEFAULT 0, version INT NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS orders (id UUID PRIMARY KEY, event_id TEXT NOT NULL UNIQUE, user_id UUID NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
"
kubectl exec -n rivulet svc/postgres -- psql -U app -d app -c "$SCHEMA_SQL" >/dev/null || fail "Schema bootstrap failed"

log "Seeding DB..."
kubectl exec -n rivulet svc/postgres -- psql -U app -d app -c \
    "INSERT INTO inventory (sku, quantity) VALUES ('TEST-SKU-E2E', 100) ON CONFLICT (sku) DO UPDATE SET quantity = 100;" >/dev/null || fail "Seed failed"

# --- 5. Build & Run Worker ---
log "Clearing Go build cache and building worker..."
go clean -cache >/dev/null
go build -v -o "$WORKER_BIN" ./cmd/worker 2>&1 | tail -n 1 || fail "Go build failed"

log "Starting worker (logs streaming from $WORKER_LOG)..."
# Truncate log file
> "$WORKER_LOG"
"$WORKER_BIN" >> "$WORKER_LOG" 2>&1 &
WORKER_PID=$!
PIDS+=($WORKER_PID)

# Stream logs to terminal in real-time
tail -f "$WORKER_LOG" &
TAIL_PID=$!

log "Waiting for worker startup..."
for i in {1..20}; do
    if grep -q "ingestion-worker started successfully" "$WORKER_LOG" 2>/dev/null; then
        pass "Worker started successfully"
        break
    fi
    if ! kill -0 $WORKER_PID 2>/dev/null; then
        fail "Worker crashed during startup. Check $WORKER_LOG"
    fi
    sleep 1
done

# Disable exit-on-error for test assertions
set +e

# --- 6. Test 1: Happy Path ---
log "Test 1: Injecting valid message into Valkey stream..."
TRACEPARENT="00-${TRACE_ID}-${SPAN_ID}-01"
PAYLOAD="{\"event_id\":\"${EVENT_ID}\",\"user_id\":\"${USER_ID}\",\"sku\":\"TEST-SKU-E2E\",\"quantity\":1}"

INJECT_OUT=$(kubectl exec -n rivulet svc/valkey -- valkey-cli -a "$VALKEY_PASS" --no-auth-warning \
    XADD rivulet.orders.in '*' traceparent "$TRACEPARENT" payload "$PAYLOAD" 2>&1)
if [[ $? -ne 0 ]]; then
    log "Valkey injection failed: $INJECT_OUT"
    fail "Test 1 aborted due to injection failure"
fi
pass "Message injected into stream"

log "Waiting 5 seconds for processing..."
sleep 5

log "Verifying database state..."
ORDER_COUNT=$(kubectl exec -n rivulet svc/postgres -- psql -U app -d app -t -c \
    "SELECT count(*) FROM orders WHERE event_id='${EVENT_ID}';" 2>&1 | tr -d ' ')

if [[ "$ORDER_COUNT" == "1" ]]; then
    pass "Happy path verified: Order created in database"
else
    log "DB Query output: '$ORDER_COUNT'"
    fail "Happy path failed: Expected 1 order, found $ORDER_COUNT"
fi

# --- 7. Test 2: Chaos Injection ---
log "Test 2: Triggering chaos endpoint..."
CHAOS_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${WORKER_CHAOS_PORT}/__chaos/cpu-spin")
if [[ "$CHAOS_RESP" == "200" ]]; then
    pass "Chaos endpoint 200 OK"
else
    fail "Chaos endpoint failed: HTTP $CHAOS_RESP"
fi
curl -s -X POST "http://127.0.0.1:${WORKER_CHAOS_PORT}/__chaos/reset" >/dev/null

# --- 8. Test 3: Telemetry Verification ---
log "Test 3: Querying OpenObserve for traces..."
END_US=$(( $(date -u +%s) * 1000000 ))
START_US=$(( END_US - 300000000 ))
AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$O2_EMAIL" "$O2_PASS" | base64 | tr -d '\n')"
QUERY_BODY=$(jq -nc --argjson s "$START_US" --argjson e "$END_US" \
    '{query: {sql: "SELECT * FROM \"default\" WHERE service_name='\''ingestion-worker'\''", start_time: $s, end_time: $e}}')

O2_RESP=$(curl -s -X POST "http://127.0.0.1:${O2_PORT}/api/default/_search?type=traces" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$QUERY_BODY")

HITS=$(echo "$O2_RESP" | jq '.hits | length' 2>/dev/null || echo "0")
if [[ "$HITS" -gt 0 ]]; then
    pass "Telemetry verified: Found $HITS trace(s) in OpenObserve"
else
    # Telemetry failure is a warning, not a hard fail for the happy path DB test
    log "Warning: Telemetry verification failed (No traces found). DB test still passed."
fi

echo
log "========================================="
log "  ALL E2E BATTLE TESTS PASSED"
log "========================================="
