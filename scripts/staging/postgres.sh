#!/usr/bin/env bash
# postgres.sh — Inspect and purge AutoSRE incident checkpoints
#
# Usage:
#   ./postgres.sh --inspect              Show all incidents with status/phase/cost
#   ./postgres.sh --inspect --limit 5    Show last 5 incidents
#   ./postgres.sh --purge --all          Delete ALL incidents (nuclear option)
#   ./postgres.sh --purge --status X     Delete incidents with status X (e.g., "running", "no_action")
#
# Requirements:
#   - kubectl configured with access to the Kind cluster
#   - psql (PostgreSQL client) installed
#   - Rivulet workloads running (kind cluster + port-forwards)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PG_HOST="127.0.0.1"
PG_PORT="5432"
PG_USER="app"
PG_PASS="app"
PG_DB="app"
PG_NAMESPACE="rivulet"
PG_SERVICE="postgres"
DEFAULT_LIMIT="50"

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ACTION=""
LIMIT="$DEFAULT_LIMIT"
PURGE_ALL=false
PURGE_STATUS=""

usage() {
    cat <<EOF
${BOLD}postgres.sh${NC} — Inspect and purge AutoSRE incident checkpoints

${BOLD}USAGE:${NC}
    ./postgres.sh --inspect [--limit N]
    ./postgres.sh --purge --all
    ./postgres.sh --purge --status STATUS

${BOLD}OPTIONS:${NC}
    --inspect              Show all incidents with status, phase, tokens, cost
    --purge                Delete incidents
    --all                  Delete ALL incidents (use with --purge)
    --status STATUS        Delete incidents with specific status (e.g., "running", "no_action", "failed")
    --limit N              Max rows to show with --inspect (default: 50)
    -h, --help             Show this help

${BOLD}EXAMPLES:${NC}
    ./postgres.sh --inspect
    ./postgres.sh --inspect --limit 10
    ./postgres.sh --purge --all
    ./postgres.sh --purge --status running
    ./postgres.sh --purge --status no_action
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inspect)
            ACTION="inspect"
            shift
            ;;
        --purge)
            ACTION="purge"
            shift
            ;;
        --all)
            PURGE_ALL=true
            shift
            ;;
        --status)
            PURGE_STATUS="$2"
            shift 2
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    error "No action specified. Use --inspect or --purge."
    echo ""
    usage
    exit 1
fi

# ---------------------------------------------------------------------------
# Port-forward management
# ---------------------------------------------------------------------------

cleanup_port_forward() {
    # Kill any port-forward we started
    if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}

trap cleanup_port_forward EXIT

kill_stale_port_forwards() {
    # Kill any existing port-forwards to port 5432
    local pids
    pids=$(pgrep -f "kubectl.*port-forward.*5432" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        info "Killing stale port-forwards: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

start_port_forward() {
    kill_stale_port_forwards

    info "Starting port-forward to ${PG_SERVICE}:${PG_PORT} in namespace ${PG_NAMESPACE}..."

    kubectl port-forward "svc/${PG_SERVICE}" "${PG_PORT}:${PG_PORT}" \
        -n "${PG_NAMESPACE}" &>/dev/null &
    PF_PID=$!

    # Wait for port to be ready
    local max_wait=10
    local waited=0
    while ! PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT 1" &>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            error "Port-forward failed to establish within ${max_wait}s"
            error "Check: kubectl get svc ${PG_SERVICE} -n ${PG_NAMESPACE}"
            exit 1
        fi
    done

    ok "Port-forward ready (${PG_HOST}:${PG_PORT})"
}

# ---------------------------------------------------------------------------
# PSQL wrapper
# ---------------------------------------------------------------------------

run_sql() {
    PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --no-psqlrc --pset=footer=off -t -A "$@"
}

run_sql_pretty() {
    PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        --no-psqlrc "$@"
}

# ---------------------------------------------------------------------------
# --inspect
# ---------------------------------------------------------------------------

do_inspect() {
    info "Fetching last ${LIMIT} incidents (ordered by checkpoint_id DESC)..."
    echo ""

    run_sql_pretty -c "
        WITH latest_checkpoints AS (
            SELECT DISTINCT ON (thread_id)
                thread_id,
                checkpoint_id,
                channel_values,
                metadata
            FROM checkpoints
            ORDER BY thread_id, checkpoint_id DESC
        )
        SELECT
            thread_id::text AS incident_id,
            channel_values->>'status' AS status,
            channel_values->>'current_phase' AS phase,
            COALESCE((channel_values->>'tokens_used')::int, 0) AS tokens,
            ROUND(COALESCE((channel_values->>'cost_usd')::float, 0)::numeric, 4) AS cost_usd,
            ROUND(COALESCE((channel_values->>'estimated_paid_cost_usd')::float, 0)::numeric, 4) AS estimated,
            COALESCE((channel_values->>'iteration_count')::int, 0) AS iters,
            jsonb_array_length(COALESCE(channel_values->'executed_actions', '[]'::jsonb)) AS actions,
            LEFT(checkpoint_id, 8) AS last_cp
        FROM latest_checkpoints
        WHERE channel_values IS NOT NULL
        ORDER BY checkpoint_id DESC
        LIMIT ${LIMIT};
    "

    echo ""

    # Summary counts
    info "Summary:"
    run_sql_pretty -c "
        WITH latest_checkpoints AS (
            SELECT DISTINCT ON (thread_id)
                thread_id,
                channel_values
            FROM checkpoints
            ORDER BY thread_id, checkpoint_id DESC
        )
        SELECT
            COUNT(*) AS total_incidents,
            COUNT(*) FILTER (WHERE channel_values->>'status' = 'resolved') AS resolved,
            COUNT(*) FILTER (WHERE channel_values->>'status' = 'no_action') AS assessed,
            COUNT(*) FILTER (WHERE channel_values->>'status' = 'failed') AS failed,
            COUNT(*) FILTER (WHERE channel_values->>'status' = 'running') AS running,
            COUNT(*) FILTER (
                WHERE channel_values->>'requires_human_approval' = 'true'
                  AND channel_values->>'approval_granted' IS NULL
            ) AS awaiting_approval
        FROM latest_checkpoints
        WHERE channel_values IS NOT NULL;
    "

    # Stale running incidents (check by checkpoint_id age - last 100 checkpoints)
    local stale_count
    stale_count=$(run_sql -c "
        WITH latest_checkpoints AS (
            SELECT DISTINCT ON (thread_id)
                thread_id,
                checkpoint_id,
                channel_values
            FROM checkpoints
            ORDER BY thread_id, checkpoint_id DESC
        )
        SELECT COUNT(*)
        FROM latest_checkpoints
        WHERE channel_values->>'status' = 'running'
          AND checkpoint_id NOT IN (
              SELECT checkpoint_id
              FROM checkpoints
              ORDER BY checkpoint_id DESC
              LIMIT 10
          );
    " 2>/dev/null || echo "0")

    if [[ "$stale_count" -gt 0 ]]; then
        echo ""
        warn "Found ${stale_count} stale 'running' incident(s)."
        warn "Run './postgres.sh --purge --status running' to clean up."
    fi
}

# ---------------------------------------------------------------------------
# --purge
# ---------------------------------------------------------------------------

do_purge() {
    local where_clause=""
    local description=""

    if [[ "$PURGE_ALL" == "true" ]]; then
        where_clause="1=1"
        description="ALL incidents"
    elif [[ -n "$PURGE_STATUS" ]]; then
        # Use latest checkpoint per thread to check status
        where_clause="thread_id IN (
            SELECT DISTINCT ON (thread_id) thread_id
            FROM checkpoints
            WHERE channel_values->>'status' = '${PURGE_STATUS}'
            ORDER BY thread_id, checkpoint_id DESC
        )"
        description="incidents with status='${PURGE_STATUS}'"
    else
        error "Must specify --all or --status with --purge"
        usage
        exit 1
    fi

    # Count what will be deleted
    local count
    count=$(run_sql -c "
        SELECT COUNT(DISTINCT thread_id)
        FROM checkpoints
        WHERE ${where_clause};
    ")

    if [[ "$count" -eq 0 ]]; then
        ok "No ${description} found. Nothing to purge."
        return 0
    fi

    warn "About to delete ${count} incident(s) (${description})."
    echo ""

    # Show what will be deleted
    run_sql_pretty -c "
        WITH latest_checkpoints AS (
            SELECT DISTINCT ON (thread_id)
                thread_id,
                checkpoint_id,
                channel_values
            FROM checkpoints
            WHERE ${where_clause}
            ORDER BY thread_id, checkpoint_id DESC
        )
        SELECT
            thread_id::text AS incident_id,
            channel_values->>'status' AS status,
            channel_values->>'current_phase' AS phase,
            LEFT(checkpoint_id, 8) AS last_cp
        FROM latest_checkpoints
        ORDER BY checkpoint_id DESC;
    "

    echo ""
    read -rp "Delete these ${count} incidents? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Aborted."
        return 0
    fi

    info "Deleting from writes table..."
    run_sql -c "DELETE FROM writes WHERE ${where_clause};" 2>/dev/null || true

    info "Deleting from checkpoints table..."
    local deleted
    deleted=$(run_sql -c "
        WITH deleted AS (
            DELETE FROM checkpoints
            WHERE ${where_clause}
            RETURNING *
        )
        SELECT COUNT(*) FROM deleted;
    ")

    ok "Purged ${deleted} checkpoint row(s) (${count} incidents)."

    echo ""
    info "Remaining incidents:"
    local remaining
    remaining=$(run_sql -c "SELECT COUNT(DISTINCT thread_id) FROM checkpoints;")
    ok "  ${remaining} incident(s) remaining in database."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Verify prerequisites
if ! command -v kubectl &>/dev/null; then
    error "kubectl not found. Install it first."
    exit 1
fi

if ! command -v psql &>/dev/null; then
    error "psql not found. Install PostgreSQL client: apt install postgresql-client"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    error "Cannot reach Kubernetes cluster. Is Kind running?"
    exit 1
fi

# Start port-forward
start_port_forward

# Execute action
case "$ACTION" in
    inspect)
        do_inspect
        ;;
    purge)
        do_purge
        ;;
esac

# cleanup_port_forward runs via trap
