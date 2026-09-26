#!/usr/bin/env bash
# =============================================================================
# test_e2e.sh — AutoSRE unified harness
# =============================================================================
#
# Modes
# -----
#   --run           (default) Interactive. Starts agent + UI, streams logs,
#                   prints URIs, blocks until Ctrl+C. Requires a running
#                   Kind cluster with Rivulet deployed.
#
#   --test-locally  Full local harness. Runs static checks, unit and
#                   integration tests, then starts agent + UI, runs the
#                   eval suite, prints metrics, and verifies every contract.
#                   Requires a running Kind cluster. Non-interactive.
#
#   --ci            Headless. Runs static checks, eval static checks, and
#                   unit + integration tests. Does NOT touch Kubernetes,
#                   does NOT start the agent, does NOT run the eval suite.
#                   Suitable for GitHub Actions with Testcontainers.
#
# Usage
# -----
#   bash test_e2e.sh
#   bash test_e2e.sh --test-locally
#   bash test_e2e.sh --ci
#
# Environment
# -----------
#   LLM_API_KEY              Required for --run and --test-locally.
#   AUTOSRE_ADMIN__SECRET    Optional; harness generates one if unset.
#
# Strong defaults for --test-locally (override via env)
# -----------------------------------------------------
#   EVAL_FORCE_RERUN=1       Bypass the eval session/disk cache.
#   EVAL_INCIDENT_IDS=INC-003  Single incident; quota-friendly.
#   EVAL_DELAY_SECONDS=10    Seconds between fresh triggers.
#
# Outputs
# -------
#   agents/output.txt                Full console log (tee'd)
#   /tmp/autosre-agent.log           Agent stdout/stderr
#   /tmp/autosre-ui.log              Vite dev server stdout/stderr
#   /tmp/autosre-pf/*.log            Per-service port-forward logs
#   agents/eval/results/             Per-incident result JSON
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

MODE="run"

usage() {
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)           MODE="run"; shift ;;
        --test-locally)  MODE="test-locally"; shift ;;
        --ci)            MODE="ci"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            printf 'Unknown argument: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Paths and constants
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/output.txt"
AGENT_LOG="/tmp/autosre-agent.log"
UI_LOG="/tmp/autosre-ui.log"
PF_LOG_DIR="/tmp/autosre-pf"

AGENT_HOST="127.0.0.1"
AGENT_PORT="8000"
UI_HOST="127.0.0.1"
UI_PORT="5173"

# Port-forward map: "local:remote:namespace:service"
PORT_FORWARDS=(
    "15432:5432:rivulet:postgres"
    "16379:6379:rivulet:valkey"
    "14318:4318:openobserve:otel-gateway"
    "15080:5080:openobserve:openobserve"
)

mkdir -p "$PF_LOG_DIR"

# Strong defaults for the eval, only consumed by --test-locally.
: "${EVAL_FORCE_RERUN:=1}"
: "${EVAL_INCIDENT_IDS:=INC-003}"
: "${EVAL_DELAY_SECONDS:=10}"
export EVAL_FORCE_RERUN EVAL_INCIDENT_IDS EVAL_DELAY_SECONDS

# Deterministic admin secret for the gate. Operators can override.
ADMIN_SECRET="harness-admin-$(date +%s)"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'          # <- defined here; was missing
C_RESET=$'\033[0m'

log()    { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn()   { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
error()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
header() { printf '\n%s%s%s\n' "${C_BOLD}${C_CYAN}" "=== $* ===" "${C_RESET}" >&2; }

fail() {
    error "$1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# Process tracking and cleanup
#
# Unchanged from the working version. Do not modify:
#   - $! is captured immediately after the inline `kubectl ... &`
#   - cleanup kills UI -> agent -> port-forwards in that order
#   - SIGINT and SIGTERM set SHUTDOWN; the main loop decides
# -----------------------------------------------------------------------------

SHUTDOWN=false
AGENT_PID=""
UI_PID=""
TAIL_AGENT_PID=""
TAIL_UI_PID=""
PORT_FORWARD_PIDS=()

on_signal() { SHUTDOWN=true; }

stop_tails() {
    for pid in "$TAIL_AGENT_PID" "$TAIL_UI_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    TAIL_AGENT_PID=""
    TAIL_UI_PID=""
}

cleanup() {
    local exit_code=$?

    stop_tails

    if [[ -n "$UI_PID" ]] && kill -0 "$UI_PID" 2>/dev/null; then
        log "Stopping UI (pid $UI_PID)…"
        kill "$UI_PID" 2>/dev/null || true
        wait "$UI_PID" 2>/dev/null || true
    fi

    if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
        log "Stopping agent (pid $AGENT_PID)…"
        kill "$AGENT_PID" 2>/dev/null || true
        wait "$AGENT_PID" 2>/dev/null || true
    fi

    for pid in "${PORT_FORWARD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done

    if (( exit_code != 0 )) && [[ "$SHUTDOWN" != "true" ]]; then
        warn "Script exited with code $exit_code"
    fi
}

trap cleanup EXIT
trap on_signal INT
trap on_signal TERM

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

wait_for_port() {
    local host=$1 port=$2 max=${3:-30} attempt=1
    while ! (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; do
        [[ "$SHUTDOWN" == "true" ]] && return 3
        (( attempt >= max )) && return 1
        sleep 1; ((attempt++))
    done
    return 0
}

wait_for_http() {
    local url=$1 max=${2:-30} watch_pid=${3:-} attempt=1
    while ! curl -sf --max-time 2 "$url" >/dev/null 2>&1; do
        [[ "$SHUTDOWN" == "true" ]] && return 3
        if [[ -n "$watch_pid" ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
            return 2
        fi
        (( attempt >= max )) && return 1
        sleep 1; ((attempt++))
    done
    return 0
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1" 1
}

stream_log() {
    # Args: LOG_PATH PREFIX WATCH_PID
    local log_path=$1 prefix=$2 pid=$3
    tail -n +1 -F --pid="$pid" "$log_path" 2>/dev/null \
        | sed -u "s/^/[${prefix}] /" >&2 &
    echo $!
}

# Tee all output to file AND terminal.
exec > >(tee -a "$OUTPUT_FILE") 2>&1

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "  AutoSRE unified harness"
echo "  Mode:    $MODE"
echo "  Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Log:     $OUTPUT_FILE"
echo "============================================================"
echo ""

# =============================================================================
# PHASE 1 — Setup (all modes)
# =============================================================================

header "PHASE 1: Setup"

cd "$SCRIPT_DIR"

[[ -d ".venv" ]] || fail "Virtual environment missing. Run: uv venv --python 3.14" 1
# shellcheck disable=SC1091
source .venv/bin/activate
pass "Virtual environment activated"

REQUIRED_CMDS=(python ruff mypy pytest curl)
if [[ "$MODE" != "ci" ]]; then
    REQUIRED_CMDS+=(uvicorn npm kubectl psql pgrep pkill)
fi
for cmd in "${REQUIRED_CMDS[@]}"; do
    require_cmd "$cmd"
done
pass "Required commands present"

if [[ "$MODE" != "ci" ]]; then
    export AUTOSRE_ADMIN__SECRET="${AUTOSRE_ADMIN__SECRET:-$ADMIN_SECRET}"
    pass "Admin secret configured"

    if [[ ! -f "$SCRIPT_DIR/ui/node_modules/vite/dist/node/cli.js" ]]; then
        log "UI dependencies missing or incomplete — running npm ci…"
        (cd "$SCRIPT_DIR/ui" && npm ci --no-audit --no-fund) \
            || fail "npm ci failed (check disk space and npm cache)" 1
        [[ -f "$SCRIPT_DIR/ui/node_modules/vite/dist/node/cli.js" ]] \
            || fail "npm ci completed but vite payload is still missing" 1
    fi
    pass "UI dependencies present"
fi

# =============================================================================
# PHASE 2 — Infrastructure + port-forwards (NOT in --ci)
#
# The port-forward startup is INLINE. kubectl is backgrounded in the current
# shell and its PID captured immediately via $!. The cleanup function kills
# each PID. Do not wrap this in a function or command substitution.
# =============================================================================

if [[ "$MODE" != "ci" ]]; then
    header "PHASE 2: Infrastructure"

    log "Checking Kind cluster…"
    kubectl cluster-info >/dev/null 2>&1 || fail "Kind cluster not reachable" 2
    pass "Kind cluster reachable"

    log "Verifying Rivulet workloads…"
    for app in api-gateway postgres ingestion-worker; do
        kubectl get pods -n rivulet -l "app.kubernetes.io/name=$app" --no-headers 2>/dev/null \
            | grep -q Running || fail "Rivulet workload not running: $app" 2
    done
    kubectl get pods -n rivulet -l app=valkey --no-headers 2>/dev/null \
        | grep -q Running || fail "Rivulet workload not running: valkey" 2
    kubectl get pods -n openobserve --no-headers 2>/dev/null \
        | grep -q Running || fail "OpenObserve not running" 2
    pass "Rivulet + OpenObserve workloads running"

    log "Waiting for ready pods…"
    while IFS=':' read -r ns _ selector; do
        kubectl wait --for=condition=ready pod \
            -n "$ns" -l "$selector" --timeout=60s >/dev/null 2>&1 \
            || fail "Pod not ready: $ns ($selector)" 2
    done <<'PODS'
rivulet:postgres:app.kubernetes.io/name=postgres
rivulet:valkey:app=valkey
openobserve:openobserve:app.kubernetes.io/name=open-observe-minimal
PODS
    pass "All pods ready"

    log "Recycling stale port-forwards…"
    pkill -f "kubectl port-forward.*:15432" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:16379" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:14318" 2>/dev/null || true
    pkill -f "kubectl port-forward.*:15080" 2>/dev/null || true
    pkill -f "uvicorn autosre.api.main" 2>/dev/null || true
    sleep 1

    log "Starting port-forwards (logs under $PF_LOG_DIR)…"
    for entry in "${PORT_FORWARDS[@]}"; do
        IFS=':' read -r local_port remote_port ns svc <<< "$entry"
        : > "$(printf '%s/%s-%s.log' "$PF_LOG_DIR" "$ns" "$svc")"
        kubectl port-forward "svc/$svc" "$local_port:$remote_port" -n "$ns" \
            < /dev/null >>"$(printf '%s/%s-%s.log' "$PF_LOG_DIR" "$ns" "$svc")" 2>&1 &
        PORT_FORWARD_PIDS+=("$!")
    done

    for entry in "${PORT_FORWARDS[@]}"; do
        IFS=':' read -r local_port _ _ _ <<< "$entry"
        wait_for_port "$AGENT_HOST" "$local_port" 30 \
            || fail "Port-forward failed on :$local_port — see $PF_LOG_DIR/*.log" 2
    done
    pass "Port-forwards established"
else
    header "PHASE 2: Infrastructure (skipped — ci mode)"
fi

# =============================================================================
# PHASE 3 — Static checks (all modes except --run)
# =============================================================================

if [[ "$MODE" != "run" ]]; then
    header "PHASE 3: Static Checks"

    log "ruff check…"
    ruff check --fix src/ tests/ eval/ || fail "ruff check failed" 3
    pass "Linting clean"

    log "mypy (src)…"
    mypy src/ || fail "mypy src/ failed" 3
    pass "src/ type checking clean"

    log "mypy (eval)…"
    mypy eval/ || fail "mypy eval/ failed" 3
    pass "eval/ type checking clean"
else
    header "PHASE 3: Static Checks (skipped — run mode)"
fi

# =============================================================================
# PHASE 3b — Eval static checks (all modes except --run)
# =============================================================================

if [[ "$MODE" != "run" ]]; then
    header "PHASE 3b: Eval Static Checks"

    log "Validating dataset…"
    python - <<'PY' || fail "Dataset validation failed" 3
import json
import sys
from pathlib import Path

p = Path("eval/dataset/AutoSRE-Dataset-v3.json")
if not p.is_file():
    print(f"MISSING: {p}", file=sys.stderr)
    sys.exit(1)

data = json.loads(p.read_text())
if data.get("schema_version") != "3.0":
    print(f"Unexpected schema_version: {data.get('schema_version')}", file=sys.stderr)
    sys.exit(1)

incidents = data.get("incidents")
if not isinstance(incidents, list) or not incidents:
    print("Dataset must contain a non-empty 'incidents' list", file=sys.stderr)
    sys.exit(1)

required = {
    "id", "alert_name", "service", "namespace", "severity", "category",
    "trigger", "cleanup", "injected_context", "ground_truth",
    "evaluation_criteria", "baseline_mttr_seconds", "baseline_source",
}

seen: set[str] = set()
for inc in incidents:
    missing = required - set(inc.keys())
    if missing:
        print(f"{inc.get('id')}: missing {sorted(missing)}", file=sys.stderr)
        sys.exit(1)
    iid = inc.get("id")
    if not isinstance(iid, str) or not iid:
        print(f"Invalid id: {iid!r}", file=sys.stderr)
        sys.exit(1)
    if iid in seen:
        print(f"Duplicate id: {iid}", file=sys.stderr)
        sys.exit(1)
    seen.add(iid)

    for k, v in inc["injected_context"].items():
        if not isinstance(v, str):
            print(f"{iid}.injected_context[{k!r}] must be str, got {type(v).__name__}", file=sys.stderr)
            sys.exit(1)

print(f"Dataset OK: {len(incidents)} incidents")
PY
    pass "Dataset valid"

    log "Eval imports…"
    python - <<'PY' || fail "Eval import smoke test failed" 3
import sys
sys.path.insert(0, ".")

from eval.conftest import (
    AgentClient,
    all_incident_ids,
    build_incident_context,
    compute_aggregate_metrics,
    incident_by_id,
)

m = compute_aggregate_metrics()
assert isinstance(m, dict)
for key in ("mttr_reduction_pct", "no_action_count", "baseline_mttr_seconds"):
    assert key in m, f"missing {key}"

first = all_incident_ids()[0]
inc = incident_by_id(first)
ctx = build_incident_context(inc)
assert isinstance(ctx, list) and ctx

AgentClient("http://127.0.0.1:9999", "secret")
print("Eval imports OK")
PY
    pass "Eval imports valid"
else
    header "PHASE 3b: Eval Static Checks (skipped — run mode)"
fi

# =============================================================================
# PHASE 4 — Unit & integration tests (all modes except --run)
#
# CI mode relies on env vars supplied by the calling workflow. Local mode
# uses safe placeholder defaults that only satisfy Settings construction.
# =============================================================================

if [[ "$MODE" != "run" ]]; then
    header "PHASE 4: Unit & Integration Tests"

    export LLM_API_KEY="${LLM_API_KEY:-test-key-for-ci}"
    export AUTOSRE_LLM__API_KEY="${AUTOSRE_LLM__API_KEY:-$LLM_API_KEY}"
    export AUTOSRE_POSTGRES__PASSWORD="${AUTOSRE_POSTGRES__PASSWORD:-test-pass}"
    export AUTOSRE_OPENOBSERVE__EMAIL="${AUTOSRE_OPENOBSERVE__EMAIL:-test@example.com}"
    export AUTOSRE_OPENOBSERVE__PASSWORD="${AUTOSRE_OPENOBSERVE__PASSWORD:-test-pass}"
    export AUTOSRE_ALERT__WEBHOOK_SECRET="${AUTOSRE_ALERT__WEBHOOK_SECRET:-test-secret}"

    pytest tests/ -q --tb=short \
        --cov=src/autosre --cov-report=term-missing \
        || fail "Unit/integration tests failed" 4
    pass "Unit/integration tests passed"
else
    header "PHASE 4: Unit & Integration Tests (skipped — run mode)"
fi

# =============================================================================
# PHASE 5 — Start AutoSRE agent (interactive + test-locally)
# =============================================================================

if [[ "$MODE" != "ci" ]]; then
    header "PHASE 5: Start AutoSRE agent"

    # Re-verify port-forwards before touching the DB.
    for entry in "${PORT_FORWARDS[@]}"; do
        IFS=':' read -r local_port _ _ _ <<< "$entry"
        if ! (echo >/dev/tcp/"$AGENT_HOST"/"$local_port") 2>/dev/null; then
            warn "Port-forward on :$local_port died — restarting"
            pkill -f "kubectl port-forward.*:${local_port}" 2>/dev/null || true
            sleep 1
            for e2 in "${PORT_FORWARDS[@]}"; do
                IFS=':' read -r lp rp ns svc <<< "$e2"
                if [[ "$lp" == "$local_port" ]]; then
                    kubectl port-forward "svc/$svc" "$lp:$rp" -n "$ns" \
                        < /dev/null >>"$(printf '%s/%s-%s.log' "$PF_LOG_DIR" "$ns" "$svc")" 2>&1 &
                    PORT_FORWARD_PIDS+=("$!")
                    break
                fi
            done
            wait_for_port "$AGENT_HOST" "$local_port" 15 \
                || fail "Could not restart port-forward on :$local_port" 5
        fi
    done
    pass "Port-forwards verified"

    PG_SECRET_NAME=""
    if kubectl get secret postgres-rivulet-env -n rivulet >/dev/null 2>&1; then
        PG_SECRET_NAME="postgres-rivulet-env"
    elif kubectl get secret postgres-app-env -n rivulet >/dev/null 2>&1; then
        PG_SECRET_NAME="postgres-app-env"
    else
        fail "No Postgres secret found in namespace rivulet" 5
    fi

    export AUTOSRE_POSTGRES__HOST="$AGENT_HOST"
    export AUTOSRE_POSTGRES__PORT="15432"
    export AUTOSRE_POSTGRES__DB="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGDATABASE}' | base64 -d)"
    export AUTOSRE_POSTGRES__USER="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGUSER}' | base64 -d)"
    export AUTOSRE_POSTGRES__PASSWORD="$(kubectl get secret "$PG_SECRET_NAME" -n rivulet -o jsonpath='{.data.PGPASSWORD}' | base64 -d)"

    export AUTOSRE_VALKEY__HOST="$AGENT_HOST"
    export AUTOSRE_VALKEY__PORT="16379"
    export AUTOSRE_VALKEY__PASSWORD="$(kubectl get secret valkey-auth -n rivulet -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d)"
    export AUTOSRE_VALKEY__TLS="false"

    export AUTOSRE_OPENOBSERVE__URL="http://$AGENT_HOST:15080"
    export AUTOSRE_OPENOBSERVE__EMAIL="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
    export AUTOSRE_OPENOBSERVE__PASSWORD="$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"

    export AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT="http://$AGENT_HOST:14318"
    export AUTOSRE_OTEL__SERVICE_NAME="autosre-agent"
    export AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT="evaluation"
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

    log "Pre-flight Postgres DSN…"
    if PGPASSWORD="$AUTOSRE_POSTGRES__PASSWORD" psql \
            -h "$AUTOSRE_POSTGRES__HOST" -p "$AUTOSRE_POSTGRES__PORT" \
            -U "$AUTOSRE_POSTGRES__USER" -d "$AUTOSRE_POSTGRES__DB" \
            -c "SELECT 1" >/dev/null 2>&1; then
        pass "Postgres reachable via port-forward"
    else
        error "Postgres pre-flight failed. Port-forward log tail:"
        tail -n 30 "$PF_LOG_DIR/rivulet-postgres.log" >&2 || true
        fail "Postgres pre-flight check failed" 5
    fi

    log "Launching agent (uvicorn)…"
    : > "$AGENT_LOG"
    uvicorn autosre.api.main:create_app_factory \
        --factory \
        --host "$AGENT_HOST" \
        --port "$AGENT_PORT" \
        --log-level info \
        >>"$AGENT_LOG" 2>&1 &
    AGENT_PID=$!

    TAIL_AGENT_PID="$(stream_log "$AGENT_LOG" "agent" "$AGENT_PID")"

    set +e
    wait_for_http "http://$AGENT_HOST:$AGENT_PORT/healthz" 60 "$AGENT_PID"
    AGENT_RC=$?
    set -e

    case $AGENT_RC in
        0)  pass "Agent ready (pid $AGENT_PID) on http://$AGENT_HOST:$AGENT_PORT" ;;
        2)  stop_tails
            error "Agent process died during startup. Last 60 lines of $AGENT_LOG:"
            tail -n 60 "$AGENT_LOG" >&2 || true
            fail "Agent startup failed" 5 ;;
        3)  log "Shutdown requested during agent startup"; exit 0 ;;
        *)  stop_tails
            error "Agent did not become ready in 60s. Last 60 lines of $AGENT_LOG:"
            tail -n 60 "$AGENT_LOG" >&2 || true
            fail "Agent startup failed" 5 ;;
    esac
else
    header "PHASE 5: Start AutoSRE agent (skipped — ci mode)"
fi

# =============================================================================
# PHASE 6 — Start UI (interactive + test-locally)
# =============================================================================

if [[ "$MODE" != "ci" ]]; then
    header "PHASE 6: Start UI"

    if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ":$UI_PORT "; then
        warn "Port $UI_PORT in use — killing previous holder"
        pkill -f "vite.*--port $UI_PORT" 2>/dev/null || true
        sleep 1
    fi

    log "Launching Vite dev server (log: $UI_LOG)…"
    : > "$UI_LOG"
    (
        cd "$SCRIPT_DIR/ui" || exit 1
        exec npm run dev -- --host "$UI_HOST" --port "$UI_PORT" --strictPort
    ) >>"$UI_LOG" 2>&1 &
    UI_PID=$!

    TAIL_UI_PID="$(stream_log "$UI_LOG" "ui" "$UI_PID")"

    set +e
    wait_for_http "http://$UI_HOST:$UI_PORT/" 90 "$UI_PID"
    UI_RC=$?
    set -e

    case $UI_RC in
        0)  pass "UI ready (pid $UI_PID) on http://$UI_HOST:$UI_PORT" ;;
        2)  stop_tails
            error "UI process died during startup. Full $UI_LOG:"
            cat "$UI_LOG" >&2 || true
            fail "UI startup failed" 6 ;;
        3)  log "Shutdown requested during UI startup"; exit 0 ;;
        *)  stop_tails
            error "UI did not become ready in 90s. Full $UI_LOG:"
            cat "$UI_LOG" >&2 || true
            fail "UI startup failed" 6 ;;
    esac
else
    header "PHASE 6: Start UI (skipped — ci mode)"
fi

# =============================================================================
# PHASE 7 — Eval suite (test-locally only)
# =============================================================================

if [[ "$MODE" == "test-locally" ]]; then
    header "PHASE 7: Eval Suite"

    stop_tails

    export AGENT_BASE_URL="http://$AGENT_HOST:$AGENT_PORT"
    export ALERT_WEBHOOK_SECRET="test-secret"

    log "EVAL_INCIDENT_IDS=$EVAL_INCIDENT_IDS"
    log "EVAL_FORCE_RERUN=$EVAL_FORCE_RERUN"
    log "EVAL_DELAY_SECONDS=$EVAL_DELAY_SECONDS"

    EVAL_START=$(date +%s)

    set +e
    pytest eval/ -q --tb=short --no-header
    EVAL_EXIT=$?
    set -e

    EVAL_DURATION=$(( $(date +%s) - EVAL_START ))

    case $EVAL_EXIT in
        0) pass  "Eval suite passed in ${EVAL_DURATION}s" ;;
        1) warn  "Eval suite finished with failures (${EVAL_DURATION}s)" ;;
        2) warn  "Eval suite interrupted (${EVAL_DURATION}s)" ;;
        *) error "Eval suite errored (exit $EVAL_EXIT, ${EVAL_DURATION}s)" ;;
    esac
else
    header "PHASE 7: Eval Suite (skipped — $MODE mode)"
fi

# =============================================================================
# PHASE 8 — Aggregate metrics (test-locally only)
# =============================================================================

if [[ "$MODE" == "test-locally" ]]; then
    header "PHASE 8: Aggregate Metrics"

    python - <<'PY'
import sys
sys.path.insert(0, ".")
from eval.conftest import compute_aggregate_metrics

m = compute_aggregate_metrics()

print()
print("=========================================")
print("  EVALUATION RESULTS")
print("=========================================")
print(f"  Total incidents:      {m['total_incidents']}")
print(f"  Resolved:             {m['resolved_count']}")
print(f"  No action:            {m['no_action_count']}")
print(f"  Failed:               {m['failed_count']}")
print()
print(f"  Avg active MTTR:      {m['avg_mttr_seconds']}s")
print(f"  Avg wall clock:       {m['avg_wall_clock_seconds']}s")
print(f"  Avg backoff:          {m['avg_backoff_seconds']}s")
print(f"  Baseline MTTR:        {m['baseline_mttr_seconds']}s")
print(f"  MTTR reduction:       {m['mttr_reduction_pct']}%")
print()
print(f"  Total cost:           ${m['total_cost_usd']:.4f}")
print(f"  Avg cost/incident:    ${m['avg_cost_usd']:.4f}")
print(f"  Total tokens:         {m['total_tokens']:,}")
print(f"  Avg tokens:           {m['avg_tokens']:,}")
print(f"  Safety violations:    {m['safety_violations']}")
print()

if m["per_incident"]:
    print(f"  {'ID':<10} {'Status':<12} {'Active':>8} {'Wall':>8} {'Backoff':>8} {'Cost':>10}")
    print(f"  {'─'*10} {'─'*12} {'─'*8} {'─'*8} {'─'*8} {'─'*10}")
    for inc in m["per_incident"]:
        st = inc["status"]
        badge = ("✓ " if st == "resolved"
                 else "○ " if st == "no_action"
                 else "✗ " if st == "failed"
                 else "? ") + st
        print(
            f"  {inc['incident_id']:<10} {badge:<12} "
            f"{inc['mttr_seconds']:>7.1f}s "
            f"{inc['wall_clock_seconds']:>7.1f}s "
            f"{inc['backoff_seconds']:>7.1f}s "
            f"${inc['cost_usd']:>9.4f}"
        )
    print()
print("=========================================")
PY

    pass "Metrics printed"
else
    header "PHASE 8: Aggregate Metrics (skipped — $MODE mode)"
fi

# =============================================================================
# PHASE 9 — Contract verification (test-locally only)
# =============================================================================

if [[ "$MODE" == "test-locally" ]]; then
    header "PHASE 9: Contract Verification"

    log "Verifying /healthz shape…"
    curl -sf "http://$AGENT_HOST:$AGENT_PORT/healthz" | python -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('status') == 'ok', d
assert 'version' in d, d
assert isinstance(d.get('paused'), bool), d
print('  healthz OK (version={}, paused={})'.format(d.get('version'), d['paused']))
" || fail "/healthz shape violated" 9
    pass "/healthz shape OK"

    log "Verifying /admin/pause → /admin/resume round-trip…"
    curl -sf -X POST "http://$AGENT_HOST:$AGENT_PORT/admin/pause" \
        -H "X-Admin-Secret: $AUTOSRE_ADMIN__SECRET" >/dev/null \
        || fail "/admin/pause failed" 9

    PAUSED=$(curl -sf "http://$AGENT_HOST:$AGENT_PORT/healthz" \
        | python -c "import json,sys; print(json.load(sys.stdin)['paused'])")
    [[ "$PAUSED" == "True" ]] || fail "agent did not reflect paused=true" 9

    curl -sf -X POST "http://$AGENT_HOST:$AGENT_PORT/admin/resume" \
        -H "X-Admin-Secret: $AUTOSRE_ADMIN__SECRET" >/dev/null \
        || fail "/admin/resume failed" 9

    PAUSED=$(curl -sf "http://$AGENT_HOST:$AGENT_PORT/healthz" \
        | python -c "import json,sys; print(json.load(sys.stdin)['paused'])")
    [[ "$PAUSED" == "False" ]] || fail "agent did not reflect paused=false" 9
    pass "Kill switch round-trip OK"

    log "Verifying /metrics/summary contract…"
    curl -sf "http://$AGENT_HOST:$AGENT_PORT/metrics/summary" | python -c "
import json, sys
d = json.load(sys.stdin)
required = {
    'no_action_count', 'baseline_mttr_seconds', 'mttr_reduction_pct',
    'avg_wall_clock_seconds', 'avg_backoff_seconds',
}
missing = required - set(d.keys())
assert not missing, f'missing keys: {sorted(missing)}'
assert d['mttr_reduction_pct'] >= 0
assert d['no_action_count'] >= 0
assert d['baseline_mttr_seconds'] >= 0
print('  summary OK (reduction={}%)'.format(d['mttr_reduction_pct']))
" || fail "/metrics/summary contract violated" 9
    pass "Metrics summary fields present"

    log "Verifying /metrics/timeseries ordering…"
    curl -sf "http://$AGENT_HOST:$AGENT_PORT/metrics/timeseries?range=24h" | python -c "
import json, sys
d = json.load(sys.stdin)
timestamps = [b['timestamp'] for b in d['buckets']]
assert timestamps == sorted(timestamps), 'buckets not chronologically ordered'
print('  timeseries OK ({} buckets in order)'.format(len(timestamps)))
" || fail "/metrics/timeseries ordering violated" 9
    pass "Timeseries ordered"

    log "Verifying per-incident result contracts…"
    INCIDENTS_WITH_RESULTS=$(python - <<'PY'
import sys
sys.path.insert(0, ".")
from eval.conftest import all_incident_ids, load_result
for iid in all_incident_ids():
    if load_result(iid) is not None:
        print(iid)
PY
)

    if [[ -z "$INCIDENTS_WITH_RESULTS" ]]; then
        fail "No incident results found — eval suite produced no output" 9
    fi

    while IFS= read -r iid; do
        [[ -z "$iid" ]] && continue
        RESULT_PATH="eval/results/$iid/result.json"

        python - "$RESULT_PATH" "$iid" <<'PY' || fail "Result contract violated for $iid" 9
import json
import sys

path, iid = sys.argv[1], sys.argv[2]
with open(path) as f:
    doc = json.load(f)
r = doc["result"]

valid = {"resolved", "failed", "no_action", "blocked"}
assert r["status"] in valid, f"{iid}: invalid status {r['status']!r}"

wall = float(r.get("wall_clock_seconds", 0))
active = float(r.get("active_seconds", 0))
backoff = float(r.get("backoff_seconds", 0))
assert wall >= 0 and active >= 0 and backoff >= 0, "negative timing"
assert wall + 1 >= active + backoff, (
    f"{iid}: timing does not close: wall={wall} active={active} backoff={backoff}"
)

executed = r.get("executed_actions") or []

if r["status"] == "resolved":
    assert isinstance(executed, list) and executed, (
        f"{iid}: status=resolved but no executed actions"
    )
    assert any(a.get("success") for a in executed), (
        f"{iid}: status=resolved but no action succeeded"
    )

if r["status"] == "no_action":
    assert not executed, (
        f"{iid}: status=no_action but {len(executed)} actions executed"
    )

mutating = {
    "restart_deployment", "scale_deployment", "delete_pod",
    "terminate_backend", "delete_valkey_key", "set_feature_flag",
}
names = [a.get("tool_name") for a in executed if isinstance(a, dict)]
for tool in mutating:
    count = names.count(tool)
    assert count <= 1, f"{iid}: mutating tool {tool} executed {count} times"

print(
    f"  {iid}: status={r['status']} "
    f"wall={wall:.1f}s active={active:.1f}s "
    f"backoff={backoff:.1f}s actions={len(executed)}"
)
PY
        pass "$iid result contract verified"
    done <<< "$INCIDENTS_WITH_RESULTS"

    log "Verifying dataset baselines…"
    python - <<'PY' || fail "Dataset baseline check failed" 9
import json
import sys
from pathlib import Path

p = Path("eval/dataset/AutoSRE-Dataset-v3.json")
data = json.loads(p.read_text())

for inc in data["incidents"]:
    b = inc.get("baseline_mttr_seconds")
    if b is None:
        print(f"{inc['id']}: missing baseline_mttr_seconds", file=sys.stderr)
        sys.exit(1)
    if not isinstance(b, (int, float)) or b < 0:
        print(f"{inc['id']}: baseline must be non-negative, got {b!r}", file=sys.stderr)
        sys.exit(1)
    if inc["category"] in {"prohibited_action", "webhook_dedup"} and b != 0:
        print(f"{inc['id']}: {inc['category']} should have baseline 0, got {b}", file=sys.stderr)
        sys.exit(1)

print(f"  {len(data['incidents'])} incidents have valid baselines")
PY
    pass "Dataset baselines valid"

    echo ""
    pass "${C_BOLD}GATE PASSED — all contracts verified${C_RESET}"
else
    header "PHASE 9: Contract Verification (skipped — $MODE mode)"
fi

# =============================================================================
# PHASE 10 — Interactive banner (run mode only)
# =============================================================================

if [[ "$MODE" == "run" ]]; then
    header "AutoSRE is running"

    stop_tails

    cat >&2 <<EOF

  ${C_BOLD}${C_GREEN}Open these in your browser:${C_RESET}

    ${C_BOLD}Agent UI${C_RESET}          http://$UI_HOST:$UI_PORT
    ${C_BOLD}Agent API docs${C_RESET}    http://$AGENT_HOST:$AGENT_PORT/docs
    ${C_BOLD}OpenObserve${C_RESET}       http://$AGENT_HOST:15080

  ${C_DIM}Logs:${C_RESET}
    agent     ->  $AGENT_LOG
    ui        ->  $UI_LOG
    pf        ->  $PF_LOG_DIR/*.log
    all       ->  $OUTPUT_FILE

  ${C_DIM}Admin endpoints (X-Admin-Secret: $AUTOSRE_ADMIN__SECRET):${C_RESET}
    curl -X POST http://$AGENT_HOST:$AGENT_PORT/admin/pause  -H "X-Admin-Secret: $AUTOSRE_ADMIN__SECRET"
    curl -X POST http://$AGENT_HOST:$AGENT_PORT/admin/resume -H "X-Admin-Secret: $AUTOSRE_ADMIN__SECRET"
    curl      http://$AGENT_HOST:$AGENT_PORT/admin/status  -H "X-Admin-Secret: $AUTOSRE_ADMIN__SECRET"

  ${C_BOLD}Press Ctrl+C to stop.${C_RESET}

EOF

    EXIT_CODE=0

    while true; do
        if [[ "$SHUTDOWN" == "true" ]]; then
            log "Shutdown signal received"
            break
        fi

        agent_alive=false
        ui_alive=false
        kill -0 "$AGENT_PID" 2>/dev/null && agent_alive=true
        kill -0 "$UI_PID" 2>/dev/null && ui_alive=true

        if [[ "$agent_alive" == "false" || "$ui_alive" == "false" ]]; then
            if [[ "$SHUTDOWN" == "true" ]]; then
                log "Shutdown signal received"
                break
            fi

            if [[ "$agent_alive" == "false" && "$ui_alive" == "false" ]]; then
                error "Both services exited unexpectedly."
                echo "--- agent tail ---" >&2
                tail -n 30 "$AGENT_LOG" >&2 || true
                echo "--- ui tail ---" >&2
                tail -n 30 "$UI_LOG" >&2 || true
            elif [[ "$agent_alive" == "false" ]]; then
                error "Agent exited unexpectedly. Last 30 lines of $AGENT_LOG:"
                tail -n 30 "$AGENT_LOG" >&2 || true
            else
                error "UI exited unexpectedly. Last 30 lines of $UI_LOG:"
                tail -n 30 "$UI_LOG" >&2 || true
            fi

            EXIT_CODE=1
            break
        fi

        sleep 1
    done

    (( EXIT_CODE != 0 )) && exit "$EXIT_CODE"
fi

# =============================================================================
# Done
# =============================================================================

echo ""
echo "============================================================"
echo "  AutoSRE harness complete ($MODE)"
echo "  Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Log:      $OUTPUT_FILE"
echo "============================================================"
echo ""

pass "Done"
