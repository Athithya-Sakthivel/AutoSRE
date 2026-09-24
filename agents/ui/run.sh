#!/usr/bin/env bash
# =============================================================================
# ui/run.sh — AutoSRE Full Development Stack
# =============================================================================
#
# Always launches the complete stack (no arguments):
#   1. Kubernetes port forwards (Postgres, Valkey, OpenObserve, OTel)
#   2. Fetches secrets from cluster and exports env vars
#   3. Agent backend (FastAPI with hot-reload on :8000)
#   4. React UI dev server (Vite on :5173)
#
# USAGE:
#   cd /workspace/agents
#   bash ui/run.sh
#
# ACCESS:
#   UI:           http://localhost:5173
#   Backend API:  http://localhost:8000
#   API Docs:     http://localhost:8000/docs
#   Healthz:      http://localhost:8000/healthz
#   OpenObserve:  http://localhost:15080
#
# TO STOP:
#   Press Ctrl+C — cleanup trap stops everything
#   Or: bash ui/run.sh --clean (kill leftover processes)
#
# SLACK BOT (Phase E — not yet implemented):
#   export AUTOSRE_SLACK__BOT_TOKEN=xoxb-...
#   export AUTOSRE_SLACK__SIGNING_SECRET=...
# =============================================================================

set -Euo pipefail
IFS=$'\n\t'

# =============================================================================
# Handle --clean mode (kill leftovers and exit)
# =============================================================================
if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning up leftover processes..."
    pkill -f "uvicorn autosre.api.main" 2>/dev/null || true
    pkill -f "node.*vite" 2>/dev/null || true
    pkill -f "kubectl port-forward" 2>/dev/null || true
    echo "✓ Cleanup complete"
    exit 0
fi

# =============================================================================
# Paths & constants
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UI_DIR="$SCRIPT_DIR"

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

# Process tracking
AGENT_PID=""
VITE_PID=""
declare -a PORT_FORWARD_PIDS=()

# =============================================================================
# Cleanup on exit (Ctrl+C or script failure)
# =============================================================================
cleanup() {
    local exit_code=$?
    echo ""
    log "Shutting down..."

    if [[ -n "$VITE_PID" ]] && kill -0 "$VITE_PID" 2>/dev/null; then
        kill "$VITE_PID" 2>/dev/null || true
        wait "$VITE_PID" 2>/dev/null || true
        pass "Vite dev server stopped"
    fi

    if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
        kill "$AGENT_PID" 2>/dev/null || true
        wait "$AGENT_PID" 2>/dev/null || true
        pass "Agent server stopped"
    fi

    if [[ ${#PORT_FORWARD_PIDS[@]} -gt 0 ]]; then
        for pid in "${PORT_FORWARD_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        pass "Port forwards stopped"
    fi

    if (( exit_code != 0 )); then
        warn "Exited with code $exit_code"
    else
        pass "Clean shutdown"
    fi
}
trap cleanup EXIT

fail() {
    error "$1"
    exit "${2:-1}"
}

# =============================================================================
# Helpers
# =============================================================================
wait_for_port() {
    local port=$1 max=${2:-30} attempt=1
    while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
        (( attempt > max )) && return 1
        sleep 1; ((attempt++))
    done
    return 0
}

# =============================================================================
# PHASE 1: Setup
# =============================================================================
header "PHASE 1: Setup"
cd "$PROJECT_ROOT"

log "Activating virtual environment..."
[[ -d ".venv" ]] || fail "Virtual environment not found at .venv" 1
source .venv/bin/activate
pass "Virtual environment activated"

for cmd in uvicorn kubectl npm psql; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd" 1
done
pass "All required commands available"

log "Checking UI dependencies..."
cd "$UI_DIR"
if [[ ! -d "node_modules" ]]; then
    log "Installing UI dependencies (first run)..."
    npm ci --silent
fi
pass "UI dependencies ready"
cd "$PROJECT_ROOT"

# =============================================================================
# PHASE 2: Infrastructure (always runs)
# =============================================================================
header "PHASE 2: Infrastructure"

log "Checking Kind cluster..."
kubectl cluster-info >/dev/null 2>&1 || fail "Kind cluster not running. Start it first." 1
pass "Kind cluster is running"

log "Checking Rivulet services..."
for app in api-gateway postgres ingestion-worker; do
    kubectl get pods -n rivulet -l "app.kubernetes.io/name=$app" --no-headers 2>/dev/null | grep -q Running \
        || fail "Service $app not running in namespace rivulet" 1
done
kubectl get pods -n rivulet -l app=valkey --no-headers 2>/dev/null | grep -q Running \
    || fail "Service valkey not running in namespace rivulet" 1
kubectl get pods -n openobserve -l app.kubernetes.io/name=open-observe-minimal --no-headers 2>/dev/null | grep -q Running \
    || fail "OpenObserve not running in namespace openobserve" 1
pass "All Rivulet + OpenObserve services deployed"

log "Cleaning up stale port forwards..."
pkill -f "kubectl port-forward.*:15432" 2>/dev/null || true
pkill -f "kubectl port-forward.*:16379" 2>/dev/null || true
pkill -f "kubectl port-forward.*:14318" 2>/dev/null || true
pkill -f "kubectl port-forward.*:15080" 2>/dev/null || true
sleep 1

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
wait_for_port 15432 || fail "Postgres port forward failed" 1
wait_for_port 16379 || fail "Valkey port forward failed" 1
wait_for_port 14318 || fail "OTel gateway port forward failed" 1
wait_for_port 15080 || fail "OpenObserve port forward failed" 1
pass "All port forwards ready"

# Fetch secrets
log "Fetching secrets from cluster..."
PG_SECRET_NAME=""
if kubectl get secret postgres-rivulet-env -n rivulet >/dev/null 2>&1; then
    PG_SECRET_NAME="postgres-rivulet-env"
elif kubectl get secret postgres-app-env -n rivulet >/dev/null 2>&1; then
    PG_SECRET_NAME="postgres-app-env"
else
    fail "No Postgres secret found (tried postgres-rivulet-env, postgres-app-env)" 1
fi

# Postgres
export AUTOSRE_POSTGRES__HOST="localhost"
export AUTOSRE_POSTGRES__PORT="15432"
export AUTOSRE_POSTGRES__DB="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGDATABASE}' | base64 -d)"
export AUTOSRE_POSTGRES__USER="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGUSER}' | base64 -d)"
export AUTOSRE_POSTGRES__PASSWORD="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGPASSWORD}' | base64 -d)"

# Valkey
export AUTOSRE_VALKEY__HOST="localhost"
export AUTOSRE_VALKEY__PORT="16379"
export AUTOSRE_VALKEY__PASSWORD="$(kubectl get secret valkey-auth -n rivulet -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d)"
export AUTOSRE_VALKEY__TLS="false"

# OpenObserve
export AUTOSRE_OPENOBSERVE__EMAIL="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
export AUTOSRE_OPENOBSERVE__PASSWORD="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"
export AUTOSRE_OPENOBSERVE__URL="http://localhost:15080"

# OTel
export AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT="http://localhost:14318"
export AUTOSRE_OTEL__SERVICE_NAME="autosre-agent"
export AUTOSRE_DEPLOYMENT_ENVIRONMENT="development"

# Safety
export AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS="1"
export AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT="10"
export AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS="600"

# Alerts
export AUTOSRE_ALERT__WEBHOOK_SECRET="${AUTOSRE_ALERT__WEBHOOK_SECRET:-test-secret}"

# LLM (CRITICAL — must be set for Settings to validate)
export AUTOSRE_LLM__API_KEY="${AUTOSRE_LLM__API_KEY:-${LLM_API_KEY:-}}"
export AUTOSRE_LLM__BASE_URL="${AUTOSRE_LLM__BASE_URL:-https://api.groq.com/openai/v1}"
export AUTOSRE_LLM__PROVIDER="${AUTOSRE_LLM__PROVIDER:-groq}"
export AUTOSRE_LLM__MODEL_COORDINATOR="${AUTOSRE_LLM__MODEL_COORDINATOR:-qwen/qwen3.8-27b}"
export AUTOSRE_LLM__MODEL_WORKER="${AUTOSRE_LLM__MODEL_WORKER:-openai/gpt-oss-20b}"

if [[ -z "$AUTOSRE_LLM__API_KEY" ]]; then
    fail "AUTOSRE_LLM__API_KEY (or LLM_API_KEY) not set. Export it first:
  export AUTOSRE_LLM__API_KEY=gsk_your_groq_key_here" 1
fi
pass "All environment variables configured"

# Pre-flight DSN check
log "Pre-flight: testing Postgres DSN..."
dim "DSN: postgresql://${AUTOSRE_POSTGRES__USER}:***@${AUTOSRE_POSTGRES__HOST}:${AUTOSRE_POSTGRES__PORT}/${AUTOSRE_POSTGRES__DB}"
if PGPASSWORD="$AUTOSRE_POSTGRES__PASSWORD" psql -h "$AUTOSRE_POSTGRES__HOST" -p "$AUTOSRE_POSTGRES__PORT" -U "$AUTOSRE_POSTGRES__USER" -d "$AUTOSRE_POSTGRES__DB" -c "SELECT 1" >/dev/null 2>&1; then
    pass "Postgres DSN valid"
else
    fail "Postgres DSN invalid — check port forward" 1
fi

log "Running database migrations..."
if alembic upgrade head 2>&1 | grep -q "Running upgrade"; then
    pass "Migrations applied"
else
    pass "Migrations up to date"
fi

# =============================================================================
# PHASE 3: Kill any existing servers
# =============================================================================
header "PHASE 3: Start Servers"

log "Stopping any existing servers..."
pkill -f "uvicorn autosre.api.main" 2>/dev/null || true
pkill -f "node.*vite" 2>/dev/null || true
sleep 1

# =============================================================================
# PHASE 4: Start Agent Backend
# =============================================================================
log "Starting agent backend (with hot-reload)..."
dim "Backend:  http://localhost:8000"
dim "API Docs: http://localhost:8000/docs"

uvicorn autosre.api.main:create_app_factory \
    --factory \
    --host 0.0.0.0 \
    --port 8000 \
    --reload \
    --reload-dir src \
    --log-level info \
    2>&1 &
AGENT_PID=$!

sleep 1

if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    fail "Agent process exited immediately — check logs above" 1
fi

log "Waiting for agent server (max 30s)..."
STARTUP_TIMEOUT=30
ELAPSED=0
while (( ELAPSED < STARTUP_TIMEOUT )); do
    if curl -sf http://localhost:8000/healthz >/dev/null 2>&1; then
        pass "Agent server ready (PID $AGENT_PID)"
        break
    fi

    if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        fail "Agent process crashed during startup — check traceback above" 1
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if (( ELAPSED >= STARTUP_TIMEOUT )); then
    fail "Agent server did not become ready within ${STARTUP_TIMEOUT}s" 1
fi

# =============================================================================
# PHASE 5: Start Vite Dev Server (UI)
# =============================================================================
log "Starting Vite dev server..."
dim "UI: http://localhost:5173"

cd "$UI_DIR"
npx vite --host 0.0.0.0 --port 5173 2>&1 &
VITE_PID=$!
cd "$PROJECT_ROOT"

sleep 2

if ! kill -0 "$VITE_PID" 2>/dev/null; then
    warn "Vite dev server failed to start"
    warn "Check: cd ui && npm run dev"
    VITE_PID=""
else
    pass "Vite dev server ready (PID $VITE_PID)"
fi

# =============================================================================
# PHASE 6: Print Access URLs
# =============================================================================
header "ACCESS URLS"

echo ""
printf '  %sUI:%-14s%s http://localhost:5173%s\n'        "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
printf '  %sBackend API:%-5s%s http://localhost:8000%s\n'  "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
printf '  %sAPI Docs:%-8s%s http://localhost:8000/docs%s\n' "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
printf '  %sHealth Check:%-4s%s http://localhost:8000/healthz%s\n' "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
printf '  %sOpenObserve:%-5s%s http://localhost:15080%s\n' "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
echo ""
echo "  ${C_DIM}Press Ctrl+C to stop all servers${C_RESET}"
echo ""

# =============================================================================
# PHASE 7: Watch and Wait
# =============================================================================
while true; do
    if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        error "Agent server died unexpectedly"
        exit 1
    fi

    if [[ -n "$VITE_PID" ]] && ! kill -0 "$VITE_PID" 2>/dev/null; then
        warn "Vite dev server died — restarting..."
        cd "$UI_DIR"
        npx vite --host 0.0.0.0 --port 5173 2>&1 &
        VITE_PID=$!
        cd "$PROJECT_ROOT"
        sleep 2
    fi

    sleep 5
done
