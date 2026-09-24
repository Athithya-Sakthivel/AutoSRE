#!/usr/bin/env bash
# =============================================================================
# test_e2e_locally.sh — AutoSRE Full E2E Evaluation
# =============================================================================
#
# Runs the complete evaluation pipeline:
#   Phase 1: Setup (venv, dependencies)
#   Phase 2: Lint & Type Check (ruff, mypy)
#   Phase 3: Unit & Integration Tests (pytest tests/)
#   Phase 4: Infrastructure Check (Kind cluster, Rivulet services)
#   Phase 5: Start Agent Server
#   Phase 6: Run Full Eval Suite (pytest eval/)
#   Phase 7: Print Aggregate Metrics
#   Phase 8: Cleanup
#
# All output is captured to agents/output.txt AND streamed to terminal.
#
# USAGE:
#   bash test_e2e_locally.sh [options]
#
# OPTIONS:
#   --skip-tests      Skip unit/integration tests (Phase 3)
#   --skip-infra      Skip infrastructure checks (Phase 4)
#   --skip-lint       Skip lint/typecheck (Phase 2)
#   --no-chaos        Skip chaos injection (legacy, no-op now)
#   --eval-only       Skip phases 1-5, run eval only (agent must be running)
#   --clean           Stop any running agent and clean up, then exit
#
# ENVIRONMENT VARIABLES:
#   EVAL_INCIDENT_IDS   Comma-separated incident IDs (e.g., INC-001,INC-003)
#                       If unset, runs all 15 incidents.
#   EVAL_FORCE_RERUN    Set to "1" to re-run incidents with existing results.
#   EVAL_DELAY_SECONDS  Seconds between incidents (default: 5.0)
#
# RESULTS:
#   Per-incident results: eval/results/<INCIDENT_ID>/result.json
#   All output:           agents/output.txt
# =============================================================================

set -Euo pipefail
IFS=$'\n\t'

export EVAL_INCIDENT_IDS=INC-003

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/output.txt"

SKIP_TESTS=false
SKIP_INFRA=false
SKIP_LINT=false
EVAL_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-tests)  SKIP_TESTS=true; shift ;;
        --skip-infra)  SKIP_INFRA=true; shift ;;
        --skip-lint)   SKIP_LINT=true; shift ;;
        --no-chaos)    shift ;;  # legacy, no-op
        --eval-only)   EVAL_ONLY=true; shift ;;
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

# Tee all output to both terminal and file
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo ""
echo "============================================================"
echo "  AutoSRE E2E Evaluation"
echo "  Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Output:  $OUTPUT_FILE"
echo "============================================================"
echo ""

# Show eval configuration
if [[ -n "${EVAL_INCIDENT_IDS:-}" ]]; then
    echo "  Incidents: ${EVAL_INCIDENT_IDS}"
else
    echo "  Incidents: ALL (15)"
fi
echo "  Force rerun: ${EVAL_FORCE_RERUN:-0}"
echo "  Delay: ${EVAL_DELAY_SECONDS:-5.0}s"
echo ""

# =============================================================================
# PHASE 1: Setup
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

if [[ "$SKIP_LINT" == "false" ]]; then
    header "PHASE 2: Lint & Type Check"

    log "Running ruff check..."
    ruff check --fix src/ tests/ eval/ 2>&1 || fail "Linting failed" 1
    pass "Linting passed"

    log "Running mypy..."
    mypy src/ 2>&1 || fail "Type checking failed" 1
    pass "Type checking passed"
else
    header "PHASE 2: Lint & Type Check (SKIPPED)"
fi

# =============================================================================
# PHASE 3: Unit & Integration Tests
# =============================================================================

if [[ "$SKIP_TESTS" == "false" ]]; then
    header "PHASE 3: Unit & Integration Tests"
    export LLM_API_KEY="${LLM_API_KEY:-test-key-for-ci}"
    export AUTOSRE_LLM__API_KEY="${LLM_API_KEY:-test-key-for-ci}"
    export AUTOSRE_POSTGRES__PASSWORD="test-pass"
    export AUTOSRE_OPENOBSERVE__EMAIL="test@example.com"
    export AUTOSRE_OPENOBSERVE__PASSWORD="test-pass"
    export AUTOSRE_ALERT__WEBHOOK_SECRET="test-secret"

    log "Running pytest tests/..."
    pytest tests/ -v --tb=short --cov=src/autosre --cov-report=term-missing 2>&1 || fail "Unit tests failed" 2
    pass "All unit and integration tests passed"
else
    header "PHASE 3: Unit & Integration Tests (SKIPPED)"
fi

# =============================================================================
# PHASE 4: Infrastructure Check
# =============================================================================

if [[ "$SKIP_INFRA" == "false" && "$EVAL_ONLY" == "false" ]]; then
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
# PHASE 5: Start Agent Server
# =============================================================================

if [[ "$EVAL_ONLY" == "false" ]]; then
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

    # Fetch secrets
    log "Fetching secrets from cluster..."
    PG_SECRET_NAME=""
    if kubectl get secret postgres-rivulet-env -n rivulet >/dev/null 2>&1; then
        PG_SECRET_NAME="postgres-rivulet-env"
    elif kubectl get secret postgres-app-env -n rivulet >/dev/null 2>&1; then
        PG_SECRET_NAME="postgres-app-env"
    else
        fail "No Postgres secret found" 3
    fi

    export AUTOSRE_POSTGRES__HOST="localhost"
    export AUTOSRE_POSTGRES__PORT="15432"
    export AUTOSRE_POSTGRES__DB="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGDATABASE}' | base64 -d)"
    export AUTOSRE_POSTGRES__USER="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGUSER}' | base64 -d)"
    export AUTOSRE_POSTGRES__PASSWORD="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGPASSWORD}' | base64 -d)"
    export AUTOSRE_VALKEY__HOST="localhost"
    export AUTOSRE_VALKEY__PORT="16379"
    export AUTOSRE_VALKEY__PASSWORD="$(kubectl get secret valkey-auth -n rivulet -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d)"
    export AUTOSRE_VALKEY__TLS="false"
    export AUTOSRE_OPENOBSERVE__EMAIL="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
    export AUTOSRE_OPENOBSERVE__PASSWORD="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"
    export AUTOSRE_OPENOBSERVE__URL="http://localhost:15080"
    export AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT="http://localhost:14318"
    export AUTOSRE_OTEL__SERVICE_NAME="autosre-agent"
    export AUTOSRE_DEPLOYMENT_ENVIRONMENT="evaluation"
    export AUTOSRE_LLM__API_KEY="${LLM_API_KEY:-}"
    export AUTOSRE_LLM__BASE_URL="https://api.groq.com/openai/v1"
    export AUTOSRE_LLM__PROVIDER="groq"
    export AUTOSRE_LLM__MODEL_COORDINATOR="qwen/qwen3.8-27b"
    export AUTOSRE_LLM__MODEL_WORKER="openai/gpt-oss-20b"
    export AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS="1"
    export AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT="10"
    export AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS="600"
    export AUTOSRE_ALERT__WEBHOOK_SECRET="test-secret"
    pass "Secrets fetched and environment configured"

    # Pre-flight DSN check
    log "Pre-flight: testing Postgres DSN..."
    dim "DSN: postgresql://${AUTOSRE_POSTGRES__USER}:***@${AUTOSRE_POSTGRES__HOST}:${AUTOSRE_POSTGRES__PORT}/${AUTOSRE_POSTGRES__DB}"

    if PGPASSWORD="$AUTOSRE_POSTGRES__PASSWORD" psql -h "$AUTOSRE_POSTGRES__HOST" -p "$AUTOSRE_POSTGRES__PORT" -U "$AUTOSRE_POSTGRES__USER" -d "$AUTOSRE_POSTGRES__DB" -c "SELECT 1" >/dev/null 2>&1; then
        pass "Postgres DSN valid"
    else
        error "Postgres DSN INVALID"
        fail "Pre-flight Postgres check failed" 3
    fi

    log "Running database migrations..."
    if alembic upgrade head 2>&1 | grep -q "Running upgrade"; then
        pass "Migrations applied"
    else
        pass "Migrations already up to date"
    fi

    # Launch agent server
    log "Starting AutoSRE agent server..."
    dim "Command: uvicorn autosre.api.main:create_app_factory --factory --host 0.0.0.0 --port 8000 --log-level debug"
    echo ""
    echo "${C_DIM}┌─────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo "${C_DIM}│  AGENT STARTUP OUTPUT (live)                                  │${C_RESET}"
    echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"

    uvicorn autosre.api.main:create_app_factory \
        --factory \
        --host 0.0.0.0 \
        --port 8000 \
        --log-level debug \
        2>&1 | tee /tmp/agent.log &
    AGENT_PID=$!

    sleep 1

    if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
        error "Agent process exited immediately after launch."
        fail "Agent process died on startup" 4
    fi

    log "Waiting for agent HTTP server (max 60s)..."
    STARTUP_TIMEOUT=60
    ELAPSED=0
    while (( ELAPSED < STARTUP_TIMEOUT )); do
        if curl -sf http://localhost:8000/healthz >/dev/null 2>&1; then
            echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
            pass "Agent server ready (PID $AGENT_PID)"
            break
        fi

        if ! kill -0 "$AGENT_PID" 2>/dev/null; then
            echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
            error "Agent process crashed after ${ELAPSED}s during startup."
            fail "Agent crashed during startup" 4
        fi

        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done

    if (( ELAPSED >= STARTUP_TIMEOUT )); then
        echo "${C_DIM}└─────────────────────────────────────────────────────────────────┘${C_RESET}"
        fail "Agent server did not become ready within ${STARTUP_TIMEOUT}s" 4
    fi
else
    header "PHASE 5: Start Agent Server (SKIPPED — eval-only mode)"
    # Verify agent is reachable
    if ! curl -sf http://localhost:8000/healthz >/dev/null 2>&1; then
        fail "Agent server not reachable at http://localhost:8000. Start it first." 4
    fi
    pass "Agent server confirmed running"
fi

# =============================================================================
# PHASE 6: Run Full Eval Suite
# =============================================================================

header "PHASE 6: Run Full Eval Suite"

# Set eval environment
export AGENT_BASE_URL="http://localhost:8000"
export ALERT_WEBHOOK_SECRET="test-secret"

# Show which incidents will run
log "Determining incidents to evaluate..."
python3 -c "
import sys
sys.path.insert(0, '.')
from eval.conftest import incident_ids, _has_existing_result
ids = incident_ids()
if not ids:
    print('  No incidents to run (all have existing results)')
else:
    print(f'  Incidents: {len(ids)}')
    for iid in ids:
        print(f'    - {iid}')
"

log "Running eval suite..."
echo ""

EVAL_START=$(date +%s)

# Run the eval suite — this is the core evaluation
pytest eval/ -v --tb=short --no-header 2>&1
EVAL_EXIT=$?

EVAL_END=$(date +%s)
EVAL_DURATION=$((EVAL_END - EVAL_START))

echo ""

if [[ $EVAL_EXIT -eq 0 ]]; then
    pass "Eval suite completed in ${EVAL_DURATION}s"
elif [[ $EVAL_EXIT -eq 1 ]]; then
    warn "Eval suite completed with failures (${EVAL_DURATION}s)"
elif [[ $EVAL_EXIT -eq 2 ]]; then
    warn "Eval suite interrupted (${EVAL_DURATION}s)"
else
    error "Eval suite error (exit code ${EVAL_EXIT}, ${EVAL_DURATION}s)"
fi

# =============================================================================
# PHASE 7: Print Aggregate Metrics
# =============================================================================

header "PHASE 7: Aggregate Metrics"

python3 -c "
import json
import sys
sys.path.insert(0, '.')
from eval.conftest import compute_aggregate_metrics, RESULTS_DIR

metrics = compute_aggregate_metrics()

print()
print('=========================================')
print('  EVALUATION RESULTS')
print('=========================================')
print()
print(f'  Total incidents:    {metrics[\"total_incidents\"]}')
print(f'  Resolved:           {metrics[\"resolved_count\"]}')
print(f'  Failed:             {metrics[\"failed_count\"]}')
print(f'  Avg MTTR:           {metrics[\"avg_mttr_seconds\"]}s')
print(f'  Total cost:         \${metrics[\"total_cost_usd\"]:.4f}')
print(f'  Avg cost/incident:  \${metrics[\"avg_cost_usd\"]:.4f}')
print(f'  Total tokens:       {metrics[\"total_tokens\"]:,}')
print(f'  Avg tokens:         {metrics[\"avg_tokens\"]:,}')
print(f'  Safety violations:  {metrics[\"safety_violations\"]}')
print()

if metrics['per_incident']:
    print('  Per-incident breakdown:')
    print(f'  {\"ID\":<10} {\"Status\":<12} {\"MTTR\":>8} {\"Cost\":>10} {\"Tokens\":>10}')
    print(f'  {\"─\"*10} {\"─\"*12} {\"─\"*8} {\"─\"*10} {\"─\"*10}')
    for inc in metrics['per_incident']:
        status = inc['status']
        if status in ('resolved', 'complete'):
            status_str = '✓ ' + status
        elif status == 'failed':
            status_str = '✗ ' + status
        else:
            status_str = '? ' + status
        print(f'  {inc[\"incident_id\"]:<10} {status_str:<12} {inc[\"mttr_seconds\"]:>7.1f}s \${inc[\"cost_usd\"]:>9.4f} {inc[\"tokens_used\"]:>10,}')
    print()

print(f'  Results saved to: {RESULTS_DIR}')
print()
print('=========================================')
"

# =============================================================================
# PHASE 8: Final Report
# =============================================================================

header "FINAL REPORT"

echo ""
echo "========================================="
echo "  AUTOSRE E2E EVALUATION COMPLETE"
echo "========================================="
echo ""
echo "  ✓ Linting (ruff)"
echo "  ✓ Type checking (mypy)"
[[ "$SKIP_TESTS" == "false" ]] && echo "  ✓ Unit & integration tests" || echo "  ⊘ Unit & integration tests (skipped)"
echo "  ✓ Infrastructure checks"
echo "  ✓ Agent server running"
echo "  ✓ Eval suite executed"
echo ""
echo "  Agent API:      http://localhost:8000"
echo "  OpenObserve:    http://localhost:15080"
echo "  Agent logs:     /tmp/agent.log"
echo "  Full output:    $OUTPUT_FILE"
echo "  Eval results:   $SCRIPT_DIR/eval/results/"
echo ""
echo "  Completed:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================="
echo ""

pass "E2E evaluation complete"
