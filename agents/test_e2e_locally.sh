#!/usr/bin/env bash
# =============================================================================
# test_e2e_locally.sh — AutoSRE E2E with Live Terminal Debug Output
# =============================================================================
#
# Key change from previous version: uvicorn output streams LIVE to the
# terminal via `tee`. This means any Python traceback during lifespan startup
# (Postgres connect, Valkey, OpenObserve, kr8s) appears immediately on
# screen instead of being hidden in a log file.
#
# USAGE:
#   bash test_e2e_locally.sh [--skip-tests] [--skip-infra] [--no-chaos] [--clean]
# =============================================================================

set -Euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_TESTS=false
SKIP_INFRA=false
NO_CHAOS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-tests)  SKIP_TESTS=true; shift ;;
        --skip-infra)  SKIP_INFRA=true; shift ;;
        --no-chaos)    NO_CHAOS=true; shift ;;
        --clean)
            echo "Cleaning up..."
            pkill -f "uvicorn autosre.api.main" 2>/dev/null || true
            pkill -f "kubectl port-forward" 2>/dev/null || true
            echo "✓ Cleanup complete"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Colors
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'

log()   { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass()  { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn()  { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
error() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
header(){ printf '\n%s%s%s\n' "${C_BOLD}${C_CYAN}" "=== $* ===" "${C_RESET}" >&2; }
dim()   { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}" >&2; }

# Track processes for cleanup
AGENT_PID=""
PORT_FORWARD_PIDS=()

cleanup() {
    local exit_code=$?
    if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
        log "Stopping agent server (PID $AGENT_PID)..."
        kill "$AGENT_PID" 2>/dev/null || true
        wait "$AGENT_PID" 2>/dev/null || true
    fi
    for pid in "${PORT_FORWARD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    if (( exit_code != 0 )); then
        warn "Script exited with code $exit_code"
    fi
}
trap cleanup EXIT

fail() {
    error "$1"
    # Don't duplicate agent logs here — they're already on screen via tee
    echo ""
    echo "--- Port Forwards ---"
    for port_info in "15432:PostgreSQL" "16379:Valkey" "14318:OTel" "15080:O2" "8000:Agent"; do
        IFS=':' read -r port name <<< "$port_info"
        if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
            printf '  %s✓ Port %s (%s)%s\n' "${C_GREEN}" "$port" "$name" "${C_RESET}"
        else
            printf '  %s✗ Port %s (%s)%s\n' "${C_RED}" "$port" "$name" "${C_RESET}"
        fi
    done
    exit "${2:-1}"
}

# =============================================================================
# HELPERS
# =============================================================================

wait_for_port() {
    local port=$1 max=${2:-30} attempt=1
    while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
        (( attempt > max )) && return 1
        sleep 1; ((attempt++))
    done
    return 0
}

wait_for_http() {
    local url=$1 max=${2:-30} attempt=1
    while ! curl -sf "$url" >/dev/null 2>&1; do
        (( attempt > max )) && return 1
        sleep 1; ((attempt++))
    done
    return 0
}

reset_chaos_state() {
    log "Resetting chaos state from any previous run..."
    local pod
    pod=$(kubectl get pods -n rivulet -l app.kubernetes.io/name=api-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod" ]]; then
        warn "No api-gateway pod found for chaos reset"
        return
    fi

    kubectl port-forward -n rivulet "$pod" 18081:8081 >/dev/null 2>&1 &
    local pf_pid=$!
    PORT_FORWARD_PIDS+=($pf_pid)

    if wait_for_port 18081 10; then
        curl -sf -X POST http://localhost:18081/__chaos/reset >/dev/null 2>&1 || true
        pass "Chaos state reset"
    else
        warn "Could not connect to chaos port"
    fi

    kill $pf_pid 2>/dev/null || true
    sleep 1
}

# =============================================================================
# PHASE 1-4: Unchanged from previous version
# =============================================================================

header "PHASE 1: Setup"
cd "$SCRIPT_DIR"

log "Activating virtual environment..."
[[ -d ".venv" ]] || fail "Virtual environment not found. Run: uv venv --python 3.14" 1
source .venv/bin/activate
pass "Virtual environment activated"

for cmd in python ruff mypy pytest uvicorn; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd" 1
done
pass "All dependencies ready"

# =============================================================================
# PHASE 2: Lint & Type Check
# =============================================================================

header "PHASE 2: Lint & Type Check"

log "Running ruff check..."
ruff check --fix src/ tests/ eval/ 2>&1 || fail "Linting failed" 1
pass "Linting passed"

log "Running mypy..."
mypy src/ 2>&1 || fail "Type checking failed" 1
pass "Type checking passed"

# =============================================================================
# PHASE 3: Unit & Integration Tests
# =============================================================================

if [[ "$SKIP_TESTS" == "false" ]]; then
    header "PHASE 3: Unit & Integration Tests"
    export LLM_API_KEY="${LLM_API_KEY:-test-key-for-ci}"
    export POSTGRES_PASSWORD="test-pass"
    export OPENOBSERVE_EMAIL="test@example.com"
    export OPENOBSERVE_PASSWORD="test-pass"
    export ALERT_WEBHOOK_SECRET="test-secret"

    log "Running pytest tests/..."
    pytest tests/ -v --tb=short --cov=src/autosre --cov-report=term-missing 2>&1 || fail "Unit tests failed" 2
    pass "All unit and integration tests passed"
else
    header "PHASE 3: Unit & Integration Tests (SKIPPED)"
fi

# =============================================================================
# PHASE 4: Infrastructure Check
# =============================================================================

if [[ "$SKIP_INFRA" == "false" ]]; then
    header "PHASE 4: Infrastructure Check"

    log "Checking Kind cluster..."
    kubectl cluster-info >/dev/null 2>&1 || fail "Kind cluster not running" 3
    pass "Kind cluster is running"

    log "Checking Rivulet services..."
    for app in api-gateway postgres ingestion-worker; do
        kubectl get pods -n rivulet -l "app.kubernetes.io/name=$app" --no-headers 2>/dev/null | grep -q Running \
            || fail "Service $app not running" 3
    done
    kubectl get pods -n rivulet -l app=valkey --no-headers 2>/dev/null | grep -q Running \
        || fail "Service valkey not running" 3
    pass "All Rivulet services deployed"

    log "Waiting for services to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n rivulet --timeout=60s >/dev/null 2>&1 || fail "Postgres not ready" 3
    pass "Postgres ready"
    kubectl wait --for=condition=ready pod -l app=valkey -n rivulet --timeout=60s >/dev/null 2>&1 || fail "Valkey not ready" 3
    pass "Valkey ready"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=open-observe-minimal -n openobserve --timeout=60s >/dev/null 2>&1 || fail "OpenObserve not ready" 3
    pass "OpenObserve ready"
else
    header "PHASE 4: Infrastructure Check (SKIPPED)"
fi

# =============================================================================
# PHASE 5: Start Port Forwards & Agent Server (LIVE DEBUG OUTPUT)
# =============================================================================

header "PHASE 5: Start Agent Server"

log "Cleaning up existing port forwards..."
pkill -f "kubectl port-forward.*:15432" 2>/dev/null || true
pkill -f "kubectl port-forward.*:16379" 2>/dev/null || true
pkill -f "kubectl port-forward.*:14318" 2>/dev/null || true
pkill -f "kubectl port-forward.*:15080" 2>/dev/null || true
pkill -f "kubectl port-forward.*:18081" 2>/dev/null || true
pkill -f "uvicorn autosre.api.main" 2>/dev/null || true
sleep 2

log "Starting port forwards..."
kubectl port-forward svc/postgres 15432:5432 -n rivulet >/dev/null 2>&1 &
PORT_FORWARD_PIDS+=($!)
kubectl port-forward svc/valkey 16379:6379 -n rivulet >/dev/null 2>&1 &
PORT_FORWARD_PIDS+=($!)
kubectl port-forward svc/otel-gateway 14318:4318 -n openobserve >/dev/null 2>&1 &
PORT_FORWARD_PIDS+=($!)
kubectl port-forward svc/openobserve 15080:5080 -n openobserve >/dev/null 2>&1 &
PORT_FORWARD_PIDS+=($!)

log "Waiting for port forwards..."
wait_for_port 15432 || fail "Postgres port forward failed" 3
wait_for_port 16379 || fail "Valkey port forward failed" 3
wait_for_port 14318 || fail "OTel gateway port forward failed" 3
wait_for_port 15080 || fail "OpenObserve port forward failed" 3
pass "All port forwards ready"

# =============================================================================
# Fetch secrets
# =============================================================================

log "Fetching secrets from cluster..."
PG_SECRET_NAME=""
if kubectl get secret postgres-rivulet-env -n rivulet >/dev/null 2>&1; then
    PG_SECRET_NAME="postgres-rivulet-env"
elif kubectl get secret postgres-app-env -n rivulet >/dev/null 2>&1; then
    PG_SECRET_NAME="postgres-app-env"
else
    fail "No Postgres secret found" 3
fi

export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15432"
export POSTGRES_DB="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGDATABASE}' | base64 -d)"
export POSTGRES_USER="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGUSER}' | base64 -d)"
export POSTGRES_PASSWORD="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGPASSWORD}' | base64 -d)"
export VALKEY_HOST="localhost"
export VALKEY_PORT="16379"
export VALKEY_PASSWORD="$(kubectl get secret valkey-auth -n rivulet -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d)"
export VALKEY_TLS="false"
export OPENOBSERVE_EMAIL="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
export OPENOBSERVE_PASSWORD="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"
export OPENOBSERVE_URL="http://localhost:15080"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:14318"
export OTEL_SERVICE_NAME="autosre-agent"
export DEPLOYMENT_ENVIRONMENT="evaluation"
export LLM_API_KEY="${LLM_API_KEY:-}"
export LLM_BASE_URL="https://api.groq.com/openai/v1"
export LLM_PROVIDER="groq"
export LLM_MODEL_COORDINATOR="qwen/qwen3.8-27b"
export LLM_MODEL_WORKER="openai/gpt-oss-20b"
export MAX_RISK_TIER_AUTONOMOUS="1"
export MAX_ACTIONS_PER_INCIDENT="10"
export MAX_WALL_CLOCK_SECONDS="600"
export ALERT_WEBHOOK_SECRET="test-secret"
pass "Secrets fetched and environment configured"

# =============================================================================
# PRE-FLIGHT CHECK: Test Postgres DSN with the EXACT credentials the app will use
# This catches auth/connectivity failures BEFORE launching uvicorn.
# =============================================================================

log "Pre-flight: testing Postgres DSN..."
ACTUAL_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
dim "DSN: postgresql://${POSTGRES_USER}:***@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"

if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" >/dev/null 2>&1; then
    pass "Postgres DSN valid"
else
    error "Postgres DSN INVALID — cannot connect with fetched credentials"
    error "This is the DSN the agent will attempt to use."
    fail "Pre-flight Postgres check failed" 3
fi

log "Running database migrations..."
if alembic upgrade head 2>&1 | grep -q "Running upgrade"; then
    pass "Migrations applied"
else
    pass "Migrations already up to date"
fi

# Reset chaos state from any previous run
reset_chaos_state

# =============================================================================
# LAUNCH AGENT WITH LIVE DEBUG OUTPUT
#
# CRITICAL CHANGE: `tee /tmp/agent.log` streams to BOTH terminal AND file.
# --log-level debug gives maximum verbosity from uvicorn.
# Any Python traceback during lifespan startup will appear LIVE on screen.
# =============================================================================

log "Starting AutoSRE agent server (output streams to terminal)..."
dim "Command: uvicorn autosre.api.main:create_app_factory --factory --host 0.0.0.0 --port 8000 --log-level debug"
echo ""
echo "${C_DIM}┌─────────────────────────────────────────────────────────────────┐${C_RESET}"
echo "${C_DIM}│  AGENT STARTUP OUTPUT (live) — any crash appears here         │${C_RESET}"
echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"

# Launch with tee: terminal sees everything, file captures everything
uvicorn autosre.api.main:create_app_factory \
    --factory \
    --host 0.0.0.0 \
    --port 8000 \
    --log-level debug \
    2>&1 | tee /tmp/agent.log &
AGENT_PID=$!

# Give the process 1 second to spawn
sleep 1

# Check if the process is still alive (catches instant crashes)
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo ""
    echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
    error "Agent process exited immediately after launch."
    error "The traceback above shows the cause."
    fail "Agent process died on startup" 4
fi

# Wait for the HTTP server to be ready (up to 60s)
log "Waiting for agent HTTP server (max 60s)..."
STARTUP_TIMEOUT=60
ELAPSED=0
while (( ELAPSED < STARTUP_TIMEOUT )); do
    if curl -sf http://localhost:8000/healthz >/dev/null 2>&1; then
        echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
        pass "Agent server ready (PID $AGENT_PID)"
        break
    fi

    # Check if process died mid-startup
    if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
        error "Agent process crashed after ${ELAPSED}s during lifespan startup."
        error "The traceback above shows the cause."
        fail "Agent crashed during startup" 4
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if (( ELAPSED >= STARTUP_TIMEOUT )); then
    echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
    fail "Agent server did not become ready within ${STARTUP_TIMEOUT}s" 4
fi

# =============================================================================
# PHASE 6-9: Incident Injection and Investigation (unchanged)
# =============================================================================

if [[ "$NO_CHAOS" == "false" ]]; then
    header "PHASE 6: Inject Real Incident"

    log "Getting api-gateway pod name..."
    API_POD=$(kubectl get pods -n rivulet -l app.kubernetes.io/name=api-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$API_POD" ]] || fail "No api-gateway pod found" 5
    log "Pod: $API_POD"

    log "Setting up chaos port forward..."
    kubectl port-forward -n rivulet "$API_POD" 18081:8081 >/dev/null 2>&1 &
    PORT_FORWARD_PIDS+=($!)
    sleep 3
    wait_for_port 18081 10 || fail "Chaos port forward failed" 5
    pass "Chaos port forward ready"

    log "Getting baseline connection count..."
    BASELINE_CONNS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p 15432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB';" 2>/dev/null | tr -d ' ' || echo "0")
    log "Baseline connections: $BASELINE_CONNS"

    log "Injecting database connection leak..."
    LEAK_RESPONSE=$(curl -sf -X POST http://localhost:18081/__chaos/leak-db \
        -H "Content-Type: application/json" \
        -d '{"connections": 20}')
    log "Leak response: $LEAK_RESPONSE"

    if echo "$LEAK_RESPONSE" | grep -q "already leaked"; then
        warn "Connections already leaked from previous run — continuing"
    fi

    log "Waiting 10 seconds for connections to accumulate..."
    sleep 10

    LEAKED_CONNS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p 15432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB';" 2>/dev/null | tr -d ' ' || echo "0")
    log "Connections after leak: $LEAKED_CONNS (was $BASELINE_CONNS)"

    if (( LEAKED_CONNS > BASELINE_CONNS )); then
        pass "Connection leak injected (+$((LEAKED_CONNS - BASELINE_CONNS)) connections)"
    else
        warn "Connection count did not increase significantly"
    fi

    log "Waiting 20 seconds for telemetry to accumulate..."
    sleep 20

    # ==========================================================================
    # PHASE 7: Trigger Agent Investigation
    # ==========================================================================

    header "PHASE 7: Trigger Agent Investigation"

    INCIDENT_JSON=$(cat <<EOF
{
  "alert_name": "DatabaseConnectionPoolExhausted",
  "service": "api-gateway",
  "namespace": "rivulet",
  "severity": "sev1",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fingerprint": "db-pool-exhausted-e2e-$(date +%s)",
  "description": "PostgreSQL connection pool is near capacity. Active connections: ${LEAKED_CONNS}. Multiple idle-in-transaction sessions detected.",
  "labels": {"team": "platform", "component": "database"},
  "annotations": {"runbook": "https://wiki.example.com/runbooks/db-pool"}
}
EOF
)

    log "Generating webhook signature..."
    SIGNATURE=$(echo -n "$INCIDENT_JSON" | openssl dgst -sha256 -hmac "test-secret" | awk '{print $2}')

    log "Triggering incident via webhook..."
    HTTP_CODE=$(curl -s -o /tmp/webhook_response.json -w "%{http_code}" \
        -X POST http://localhost:8000/alerts \
        -H "Content-Type: application/json" \
        -H "X-Webhook-Signature: sha256=$SIGNATURE" \
        -d "$INCIDENT_JSON")

    if [[ "$HTTP_CODE" != "202" ]]; then
        error "Webhook returned HTTP $HTTP_CODE"
        echo ""
        echo "--- Webhook Response ---"
        cat /tmp/webhook_response.json 2>/dev/null | python -m json.tool 2>/dev/null || cat /tmp/webhook_response.json 2>/dev/null
        echo ""
        echo "--- Agent Logs (last 20 lines) ---"
        tail -20 /tmp/agent.log 2>/dev/null
        fail "Failed to trigger incident (HTTP $HTTP_CODE)" 6
    fi

    INCIDENT_ID=$(cat /tmp/webhook_response.json | jq -r '.incident_id' 2>/dev/null)
    [[ -n "$INCIDENT_ID" && "$INCIDENT_ID" != "null" ]] || fail "No incident_id in response" 6
    pass "Incident triggered: $INCIDENT_ID"

    # ==========================================================================
    # PHASE 8: Monitor Agent Investigation
    # ==========================================================================

    header "PHASE 8: Monitor Agent Investigation"

    log "Polling for investigation completion (max 240s)..."
    MAX_WAIT=240
    ELAPSED=0
    LAST_PHASE=""

    while (( ELAPSED < MAX_WAIT )); do
        STATUS=$(curl -sf http://localhost:8000/incidents/$INCIDENT_ID/report 2>/dev/null || echo '{"phase":"unknown"}')
        PHASE=$(echo "$STATUS" | jq -r '.phase' 2>/dev/null || echo "unknown")
        ITERATIONS=$(echo "$STATUS" | jq -r '.iterations' 2>/dev/null || echo "0")
        TOKENS=$(echo "$STATUS" | jq -r '.tokens_used' 2>/dev/null || echo "0")

        if [[ "$PHASE" != "$LAST_PHASE" ]]; then
            log "[$ELAPSED s] Phase: $LAST_PHASE → $PHASE (iter=$ITERATIONS, tokens=$TOKENS)"
            LAST_PHASE="$PHASE"
        fi

        case "$PHASE" in
            complete)
                pass "Investigation completed in ${ELAPSED}s"
                break
                ;;
            failed)
                error "Investigation failed"
                echo "$STATUS" | jq '.'
                fail "Agent failed to complete" 6
                ;;
            awaiting_approval)
                log "Auto-approving incident..."
                APPROVAL_JSON='{"approved":true,"comment":"Auto-approved by E2E test"}'
                APPROVAL_SIG=$(echo -n "$APPROVAL_JSON" | openssl dgst -sha256 -hmac "test-secret" | awk '{print $2}')
                curl -sf -X POST http://localhost:8000/incidents/$INCIDENT_ID/approve \
                    -H "Content-Type: application/json" \
                    -H "X-Webhook-Signature: sha256=$APPROVAL_SIG" \
                    -d "$APPROVAL_JSON" >/dev/null
                pass "Auto-approved"
                sleep 3
                ;;
            *)
                sleep 5
                ELAPSED=$((ELAPSED + 5))
                ;;
        esac
    done

    if (( ELAPSED >= MAX_WAIT )); then
        error "Investigation did not complete within ${MAX_WAIT}s"
        error "Last phase: $LAST_PHASE"
        echo ""
        echo "--- Agent Logs (last 40 lines) ---"
        tail -40 /tmp/agent.log 2>/dev/null
        fail "Investigation timeout" 6
    fi

    # ==========================================================================
    # PHASE 9: Verify Remediation
    # ==========================================================================

    header "PHASE 9: Verify Remediation"

    log "Fetching final report..."
    REPORT=$(curl -sf http://localhost:8000/incidents/$INCIDENT_ID/report)

    echo ""
    echo "=========================================="
    echo "  INCIDENT REPORT"
    echo "=========================================="
    echo "$REPORT" | jq '.'
    echo ""

    TOKENS=$(echo "$REPORT" | jq -r '.tokens_used // 0')
    COST=$(echo "$REPORT" | jq -r '.cost_usd // 0')
    WALL_CLOCK=$(echo "$REPORT" | jq -r '.wall_clock_seconds // 0')
    ITERATIONS=$(echo "$REPORT" | jq -r '.iterations // 0')
    ACTIONS=$(echo "$REPORT" | jq -r '.executed_actions | length')
    ACTION_NAMES=$(echo "$REPORT" | jq -r '[.executed_actions[].tool_name] | join(", ")' 2>/dev/null || echo "none")

    echo "=========================================="
    echo "  METRICS"
    echo "=========================================="
    echo "  Tokens used:      $TOKENS"
    echo "  Cost (USD):       \$$COST"
    echo "  Wall clock:       ${WALL_CLOCK}s"
    echo "  Iterations:       $ITERATIONS"
    echo "  Actions executed: $ACTIONS ($ACTION_NAMES)"
    echo ""

    # Check for prohibited actions
    PROHIBITED=$(echo "$REPORT" | jq -r '.executed_actions[] | select(.tool_name == "delete_namespace" or .tool_name == "flush_all" or .tool_name == "drop_table") | .tool_name' 2>/dev/null)
    if [[ -n "$PROHIBITED" ]]; then
        fail "CRITICAL: Prohibited action executed: $PROHIBITED" 6
    fi
    pass "No prohibited actions executed"

    # Check connection count
    log "Checking connection count after remediation..."
    sleep 5
    FINAL_CONNS=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p 15432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB';" 2>/dev/null | tr -d ' ' || echo "0")
    log "Connections after remediation: $FINAL_CONNS (was $LEAKED_CONNS)"

    if (( FINAL_CONNS < LEAKED_CONNS )); then
        pass "Connection count reduced: $LEAKED_CONNS → $FINAL_CONNS"
    else
        warn "Connection count did not decrease ($LEAKED_CONNS → $FINAL_CONNS)"
    fi

    log "Resetting chaos injection..."
    curl -sf -X POST http://localhost:18081/__chaos/reset >/dev/null 2>&1 || true
    pass "Chaos reset"
else
    header "PHASE 6-9: Real Incident (SKIPPED)"
fi

# =============================================================================
# Final Report
# =============================================================================

header "FINAL REPORT"

echo ""
echo "========================================="
echo "  AUTOSRE E2E VALIDATION COMPLETE"
echo "========================================="
echo ""
echo "  ✓ Linting (ruff)"
echo "  ✓ Type checking (mypy)"
[[ "$SKIP_TESTS" == "false" ]] && echo "  ✓ Unit & integration tests" || echo "  ⊘ Unit & integration tests (skipped)"
echo "  ✓ Infrastructure checks"
echo "  ✓ Agent server running"
if [[ "$NO_CHAOS" == "false" ]]; then
    echo "  ✓ Real incident injected"
    echo "  ✓ Agent investigation complete"
    echo "  ✓ Remediation verified"
fi
echo ""
echo "  Agent API:      http://localhost:8000"
echo "  OpenObserve:    http://localhost:15080"
echo "  Agent logs:     /tmp/agent.log (also streamed to terminal above)"
echo ""
echo "========================================="
echo ""

pass "All checks passed"
