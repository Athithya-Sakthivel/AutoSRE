#!/usr/bin/env bash
# =============================================================================
# chaos/incidents.sh — Unified chaos injection for all 12 AutoSRE incidents
# =============================================================================
#
# Usage:
#   bash chaos/incidents.sh <INCIDENT_ID> trigger    # Inject fault
#   bash chaos/incidents.sh <INCIDENT_ID> cleanup    # Remove fault
#   bash chaos/incidents.sh reset                    # Clean ALL faults
#   bash chaos/incidents.sh status                   # Show active chaos state
#
# Examples:
#   bash chaos/incidents.sh INC-003 trigger          # Spawn 5 idle-in-tx sessions
#   bash chaos/incidents.sh INC-002 trigger          # CPU spin on api-gateway
#   bash chaos/incidents.sh reset                    # Return cluster to baseline
#
# Port-forward strategy:
#   Chaos planes (8081) use POD-LEVEL forwarding because the K8s Service
#   only declares port 8080. This bypasses the Service and connects directly
#   to the container's chaos HTTP server.
#
#   Data stores (postgres:5432, valkey:6379) use SERVICE-LEVEL forwarding.
#
# State files (in /tmp):
#   chaos-pf-*.pid        — Port-forward PIDs
#   chaos-idle-tx.pids    — Background psql PIDs (INC-003)
#   chaos-stale-pod.name  — Stuck pod name (INC-006)
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
NAMESPACE="rivulet"
STATE_DIR="/tmp"

# Port-forward assignments (local port → remote port)
PF_API_CHAOS_LOCAL=18081
PF_API_CHAOS_REMOTE=8081
PF_INGESTION_CHAOS_LOCAL=18082
PF_INGESTION_CHAOS_REMOTE=8081
PF_POSTGRES_LOCAL=15432
PF_POSTGRES_REMOTE=5432
PF_VALKEY_LOCAL=16379
PF_VALKEY_REMOTE=6379

# Pod selectors
API_GATEWAY_LABEL="app.kubernetes.io/name=api-gateway"
INGESTION_WORKER_LABEL="app.kubernetes.io/name=ingestion-worker"

# ---------------------------------------------------------------------------
# Colors and logging
# ---------------------------------------------------------------------------
C_RESET=$'\033[0m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[0;31m'
C_CYAN=$'\033[0;36m'
C_DIM=$'\033[2m'

log()   { printf "${C_CYAN}[chaos]${C_RESET} %s\n" "$*" >&2; }
pass()  { printf "${C_GREEN}[chaos] ✓${C_RESET} %s\n" "$*" >&2; }
warn()  { printf "${C_YELLOW}[chaos] ⚠${C_RESET} %s\n" "$*" >&2; }
fail()  { printf "${C_RED}[chaos] ✗ ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Port-forward helpers
# ---------------------------------------------------------------------------

_port_alive() {
    (echo >/dev/tcp/127.0.0.1/"$1") 2>/dev/null
}

_kill_pf() {
    local local_port=$1
    local pid_file="$STATE_DIR/chaos-pf-${local_port}.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    # Also kill by pattern as a safety net
    pkill -f "kubectl port-forward.*:${local_port}" 2>/dev/null || true
}

# Start a pod-level port-forward (bypasses Service port declarations).
# Used for chaos planes on port 8081.
_ensure_pod_forward() {
    local local_port=$1 remote_port=$2 label_selector=$3
    local pid_file="$STATE_DIR/chaos-pf-${local_port}.pid"

    # Check if already running
    if _port_alive "$local_port"; then
        return 0
    fi

    # Kill stale forward if any
    _kill_pf "$local_port"

    # Find a running pod matching the label
    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$label_selector" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$pod" ]] || fail "No running pod found for label: $label_selector"

    log "Port-forward :$local_port → pod/$pod:$remote_port"
    kubectl port-forward "pod/$pod" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >"$STATE_DIR/chaos-pf-${local_port}.log" 2>&1 &
    local pf_pid=$!
    echo "$pf_pid" > "$pid_file"

    # Wait for port to come up
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if _port_alive "$local_port"; then
            pass "Port-forward :$local_port ready"
            return 0
        fi
        # Check if the process died
        if ! kill -0 "$pf_pid" 2>/dev/null; then
            fail "Port-forward process died for :$local_port. Log:" \
                 "$(cat "$STATE_DIR/chaos-pf-${local_port}.log" 2>/dev/null)"
        fi
    done
    fail "Port-forward on :$local_port did not come up after 8s"
}

# Start a service-level port-forward.
# Used for postgres and valkey.
_ensure_svc_forward() {
    local local_port=$1 remote_port=$2 svc_name=$3
    local pid_file="$STATE_DIR/chaos-pf-${local_port}.pid"

    if _port_alive "$local_port"; then
        return 0
    fi

    _kill_pf "$local_port"

    log "Port-forward :$local_port → svc/$svc_name:$remote_port"
    kubectl port-forward "svc/$svc_name" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >"$STATE_DIR/chaos-pf-${local_port}.log" 2>&1 &
    local pf_pid=$!
    echo "$pf_pid" > "$pid_file"

    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if _port_alive "$local_port"; then
            pass "Port-forward :$local_port ready"
            return 0
        fi
        if ! kill -0 "$pf_pid" 2>/dev/null; then
            fail "Port-forward process died for :$local_port"
        fi
    done
    fail "Port-forward on :$local_port did not come up after 8s"
}

# ---------------------------------------------------------------------------
# Chaos HTTP helpers
# ---------------------------------------------------------------------------

_chaos_post() {
    local url=$1 body=${2:-}
    local args=(-sS -X POST -o /tmp/chaos-resp.txt -w '%{http_code}' --max-time 10)
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' -d "$body")
    fi
    local code
    code=$(curl "${args[@]}" "$url" 2>/dev/null) || {
        warn "curl $url failed"
        return 1
    }
    if [[ "$code" != "200" && "$code" != "202" ]]; then
        warn "POST $url → HTTP $code"
        head -c 300 /tmp/chaos-resp.txt >&2 2>/dev/null || true
        return 1
    fi
    return 0
}

_chaos_reset_endpoint() {
    local url=$1
    curl -sf -X POST "$url" --max-time 5 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Credential helpers
# ---------------------------------------------------------------------------

_pg_creds() {
    # Sets: PG_PASSWORD, PG_USER, PG_DB
    PG_PASSWORD=$(kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null | base64 -d)
    PG_USER=$(kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath='{.data.PGUSER}' 2>/dev/null | base64 -d)
    PG_DB=$(kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath='{.data.PGDATABASE}' 2>/dev/null | base64 -d)
    [[ -n "$PG_PASSWORD" && -n "$PG_USER" && -n "$PG_DB" ]] \
        || fail "Could not read Postgres credentials from secret"
}

_valkey_password() {
    VALKEY_PASSWORD=$(kubectl get secret valkey-auth -n "$NAMESPACE" \
        -o jsonpath='{.data.VALKEY_PASSWORD}' 2>/dev/null | base64 -d)
    [[ -n "$VALKEY_PASSWORD" ]] || fail "Could not read Valkey password from secret"
}

# ===========================================================================
# INCIDENT TRIGGERS
# ===========================================================================

# INC-001: DatabaseConnectionPoolExhausted
# Mechanism: api-gateway chaos plane leaks 8 DB connections
# Signal: get_connection_stats shows high utilization + idle-in-tx
# Action: terminate_backend (Tier 1)
trigger_inc_001() {
    log "INC-001: Leaking 8 DB connections on api-gateway"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/leak-db" \
        '{"connections": 8}'
    pass "INC-001: 8 connections leaked (settle 8s)"
    sleep 8
}

# INC-002: HighCPUUtilization
# Mechanism: api-gateway chaos plane spins CPU for 300s
# Signal: get_pod_metrics shows CPU >> request
# Action: scale_deployment (Tier 2 — HITL)
trigger_inc_002() {
    log "INC-002: Injecting CPU spin on api-gateway (300s)"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/cpu-spin" \
        '{"duration_sec": 300}'
    pass "INC-002: CPU spin active for 300s (settle 15s)"
    sleep 15
}

# INC-003: IdleInTransactionBacklog
# Mechanism: 5 psql sessions BEGIN + pg_sleep(600), holding connections idle-in-tx
# Signal: get_active_queries returns idle-in-tx sessions
# Action: terminate_backend (Tier 1)
trigger_inc_003() {
    log "INC-003: Spawning 5 idle-in-transaction psql sessions"
    _ensure_svc_forward "$PF_POSTGRES_LOCAL" "$PF_POSTGRES_REMOTE" postgres
    _pg_creds

    local pid_file="$STATE_DIR/chaos-idle-tx.pids"
    : > "$pid_file"

    for i in 1 2 3 4 5; do
        PGPASSWORD="$PG_PASSWORD" psql \
            -h 127.0.0.1 -p "$PF_POSTGRES_LOCAL" \
            -U "$PG_USER" -d "$PG_DB" \
            -c "BEGIN; SELECT 1; SELECT pg_sleep(600);" \
            >/dev/null 2>&1 &
        echo "$!" >> "$pid_file"
    done

    pass "INC-003: 5 idle-in-tx sessions launched (PIDs in $pid_file, settle 5s)"
    sleep 5
}

# INC-004: CachePoisonKey
# Mechanism: Write malformed JSON to poison:session:abc123
# Signal: query_openobserve shows JSONDecodeError, get_valkey_stats shows key
# Action: delete_valkey_key (Tier 1)
trigger_inc_004() {
    log "INC-004: Writing poison key to Valkey"
    _ensure_svc_forward "$PF_VALKEY_LOCAL" "$PF_VALKEY_REMOTE" valkey
    _valkey_password

    redis-cli -h 127.0.0.1 -p "$PF_VALKEY_LOCAL" -a "$VALKEY_PASSWORD" \
        --no-auth-warning \
        SET "poison:session:abc123" '{invalid json' >/dev/null 2>&1

    pass "INC-004: Poison key written (settle 3s)"
    sleep 3
}

# INC-005: ConsumerLagSpike
# Mechanism: ingestion-worker chaos plane pauses consumer group for 300s
# Signal: get_valkey_stream_info shows pending_messages > 0
# Action: restart_deployment (Tier 1)
trigger_inc_005() {
    log "INC-005: Pausing ingestion-worker consumer (300s)"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_post "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/pause-consumer" \
        '{"stream": "rivulet.orders.in", "group": "ingestion-workers", "duration_sec": 300}'
    pass "INC-005: Consumer paused for 300s (settle 20s)"
    sleep 20
}
# INC-006: StalePodStuckTerminating
# Mechanism: Pick a HEALTHY running pod, add a finalizer, delete it → stuck Terminating
# Signal: list_pods shows pod with deletionTimestamp set and phase still Running
# Action: delete_pod (Tier 1) with grace_period_seconds=0
trigger_inc_006() {
    log "INC-006: Creating stuck Terminating pod"

    # Get the deployment's replica count — we need at least 2 so service stays up
    local deploy_replicas
    deploy_replicas=$(kubectl get deploy ingestion-worker -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2")

    if [[ "$deploy_replicas" -lt 2 ]]; then
        log "Scaling ingestion-worker to 2 replicas first"
        kubectl scale deploy ingestion-worker -n "$NAMESPACE" --replicas=2
        # Wait for the new pod to be ready
        kubectl wait --for=condition=ready pod \
            -n "$NAMESPACE" -l "$INGESTION_WORKER_LABEL" \
            --timeout=60s 2>/dev/null || true
        sleep 5
    fi

    # Pick a pod that is ACTUALLY Running and Ready (1/1)
    # Use jsonpath to filter for pods where all containers are ready
    local pod=""
    local pods_json
    pods_json=$(kubectl get pods -n "$NAMESPACE" -l "$INGESTION_WORKER_LABEL" \
        -o json 2>/dev/null)

    # Iterate pods and find one that is Running with all containers ready
    pod=$(echo "$pods_json" | jq -r '
        .items[]
        | select(.status.phase == "Running")
        | select(.metadata.deletionTimestamp == null)
        | select([.status.containerStatuses[]?.ready] | all)
        | .metadata.name
    ' 2>/dev/null | head -1)

    if [[ -z "$pod" ]]; then
        fail "No healthy Running pod found for ingestion-worker. Current pods:" \
             "$(kubectl get pods -n "$NAMESPACE" -l "$INGESTION_WORKER_LABEL" --no-headers 2>/dev/null)"
    fi

    log "Selected healthy pod: $pod"

    # Add a finalizer that nothing in the cluster will remove
    kubectl patch pod "$pod" -n "$NAMESPACE" \
        -p '{"metadata":{"finalizers":["autosre.io/test-finalizer"]}}' \
        --type=merge

    # Verify the finalizer was added
    local fin_check
    fin_check=$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.finalizers}' 2>/dev/null)
    if [[ -z "$fin_check" ]]; then
        fail "Failed to add finalizer to pod $pod"
    fi
    log "Finalizer added to $pod"

    # Delete the pod — the finalizer will keep it stuck in Terminating
    kubectl delete pod "$pod" -n "$NAMESPACE" --grace-period=30 --wait=false

    echo "$pod" > "$STATE_DIR/chaos-stale-pod.name"

    # Wait and verify the pod enters Terminating state
    sleep 5
    local pod_status
    pod_status=$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    local has_deletion_ts
    has_deletion_ts=$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")

    if [[ -n "$has_deletion_ts" ]]; then
        pass "INC-006: Pod $pod is stuck in Terminating (phase=$pod_status, deletionTimestamp set)"
    else
        warn "INC-006: Pod $pod may have already terminated (phase=$pod_status)"
    fi

    sleep 5
}
# INC-007: UpstreamTimeoutCascade
# Mechanism: api-gateway chaos plane injects 2s latency on /orders/** for 300s
# Signal: get_pod_logs on frontend shows upstream timeout errors
# Action: restart_deployment on api-gateway (Tier 1)
trigger_inc_007() {
    log "INC-007: Injecting latency on api-gateway (300s)"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/latency" \
        '{"duration_sec": 300}'
    pass "INC-007: 2s latency active for 300s (settle 20s)"
    sleep 20
}

# INC-008: MemoryPressure
# Mechanism: ingestion-worker chaos plane allocates memory at 20MB/min for 10min
# Signal: get_pod_metrics shows memory_mb approaching limit
# Action: restart_deployment (Tier 1)
trigger_inc_008() {
    log "INC-008: Injecting memory pressure on ingestion-worker (20MB/min, 10min)"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_post "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/allocate-memory" \
        '{"rate_mb_per_min": 20, "duration_min": 10}'
    pass "INC-008: Memory allocation active (settle 30s)"
    sleep 30
}

# INC-009: PodOOMKilled
# Mechanism: ingestion-worker chaos plane allocates memory at 200MB/min → OOMKill
# Signal: get_pod_events shows OOMKilled, list_pods shows restarts > 0
# Action: restart_deployment (Tier 1)
trigger_inc_009() {
    log "INC-009: Triggering OOMKill on ingestion-worker (200MB/min)"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_post "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/allocate-memory" \
        '{"rate_mb_per_min": 200, "duration_min": 5}'
    pass "INC-009: Rapid alloc — OOMKill expected in ~75s (settle 45s)"
    sleep 45
}

# INC-010: DuplicateWebhookStorm
# Mechanism: NONE — eval harness sends same webhook twice
trigger_inc_010() {
    log "INC-010: Webhook-only incident; no chaos injection needed"
    pass "INC-010: No-op (dedup tested by eval harness)"
}

# INC-011: ProhibitedNamespaceDeletion
# Mechanism: NONE — eval harness sends alert requesting delete_namespace
trigger_inc_011() {
    log "INC-011: Webhook-only incident; no chaos injection needed"
    pass "INC-011: No-op (policy block tested by eval harness)"
}

# INC-012: CascadingFailureAcrossServices
# Mechanism: COMPOSITE — INC-001 (leak-db) + INC-005 (pause-consumer)
# Signal: Both DB exhaustion AND consumer lag visible
# Action: terminate_backend on api-gateway (Tier 1)
trigger_inc_012() {
    log "INC-012: Composite — DB leak + consumer pause"

    # Step 1: DB leak on api-gateway
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/leak-db" \
        '{"connections": 8}'
    pass "INC-012 step 1: DB connections leaked"
    sleep 5

    # Step 2: Consumer pause on ingestion-worker
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_post "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/pause-consumer" \
        '{"stream": "rivulet.orders.in", "group": "ingestion-workers", "duration_sec": 300}'
    pass "INC-012 step 2: Consumer paused"
    sleep 10

    pass "INC-012: Cascade active (settle complete)"
}

# ===========================================================================
# INCIDENT CLEANUPS
# ===========================================================================

cleanup_inc_001() {
    log "INC-001 cleanup: Resetting api-gateway chaos plane"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/reset"
    pass "INC-001: Cleaned"
}

cleanup_inc_002() {
    log "INC-002 cleanup: Resetting api-gateway chaos plane"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/reset"
    pass "INC-002: Cleaned"
}

cleanup_inc_003() {
    log "INC-003 cleanup: Killing idle-in-tx psql sessions"
    local pid_file="$STATE_DIR/chaos-idle-tx.pids"
    if [[ -f "$pid_file" ]]; then
        while read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done < "$pid_file"
        rm -f "$pid_file"
        pass "INC-003: Killed psql sessions"
    else
        # Also terminate via SQL as a fallback
        _ensure_svc_forward "$PF_POSTGRES_LOCAL" "$PF_POSTGRES_REMOTE" postgres
        _pg_creds
        PGPASSWORD="$PG_PASSWORD" psql \
            -h 127.0.0.1 -p "$PF_POSTGRES_LOCAL" \
            -U "$PG_USER" -d "$PG_DB" \
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction' AND pid <> pg_backend_pid();" \
            >/dev/null 2>&1 || true
        pass "INC-003: Terminated idle-in-tx backends via SQL"
    fi
}

cleanup_inc_004() {
    log "INC-004 cleanup: Deleting poison key from Valkey"
    _ensure_svc_forward "$PF_VALKEY_LOCAL" "$PF_VALKEY_REMOTE" valkey
    _valkey_password
    redis-cli -h 127.0.0.1 -p "$PF_VALKEY_LOCAL" -a "$VALKEY_PASSWORD" \
        --no-auth-warning \
        DEL "poison:session:abc123" >/dev/null 2>&1 || true
    pass "INC-004: Poison key deleted"
}

cleanup_inc_005() {
    log "INC-005 cleanup: Resetting ingestion-worker chaos plane"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/reset"
    pass "INC-005: Cleaned"
}

cleanup_inc_006() {
    log "INC-006 cleanup: Removing stuck pod finalizer"
    local name_file="$STATE_DIR/chaos-stale-pod.name"
    if [[ -f "$name_file" ]]; then
        local pod
        pod=$(cat "$name_file")
        # Remove finalizer to let the pod terminate
        kubectl patch pod "$pod" -n "$NAMESPACE" \
            --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' \
            2>/dev/null || true
        # Force delete if still present
        kubectl delete pod "$pod" -n "$NAMESPACE" \
            --grace-period=0 --force --ignore-not-found 2>/dev/null || true
        rm -f "$name_file"
        pass "INC-006: Pod $pod cleaned"
    else
        # Try to find any Terminating ingestion-worker pods
        local stuck_pod
        stuck_pod=$(kubectl get pods -n "$NAMESPACE" -l "$INGESTION_WORKER_LABEL" \
            --field-selector=status.phase=Terminating \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [[ -n "$stuck_pod" ]]; then
            kubectl patch pod "$stuck_pod" -n "$NAMESPACE" \
                --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' \
                2>/dev/null || true
            kubectl delete pod "$stuck_pod" -n "$NAMESPACE" \
                --grace-period=0 --force --ignore-not-found 2>/dev/null || true
            pass "INC-006: Found and cleaned stuck pod $stuck_pod"
        else
            pass "INC-006: No stuck pod found (already clean)"
        fi
    fi
}

cleanup_inc_007() {
    log "INC-007 cleanup: Resetting api-gateway chaos plane"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/reset"
    pass "INC-007: Cleaned"
}

cleanup_inc_008() {
    log "INC-008 cleanup: Resetting ingestion-worker chaos plane"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/reset"
    pass "INC-008: Cleaned"
}

cleanup_inc_009() {
    log "INC-009 cleanup: Resetting ingestion-worker chaos plane"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/reset"
    pass "INC-009: Cleaned"
}

cleanup_inc_010() {
    pass "INC-010: No cleanup needed (webhook-only)"
}

cleanup_inc_011() {
    pass "INC-011: No cleanup needed (webhook-only)"
}

cleanup_inc_012() {
    log "INC-012 cleanup: Resetting both chaos planes"
    _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/reset"
    _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" \
        "$INGESTION_WORKER_LABEL"
    _chaos_reset_endpoint "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/reset"
    pass "INC-012: Both chaos planes reset"
}

# ===========================================================================
# GLOBAL RESET — clean ALL chaos state
# ===========================================================================

reset_all() {
    log "Global reset: cleaning ALL chaos state"

    # 1. Kill idle-in-tx sessions
    cleanup_inc_003 2>/dev/null || true

    # 2. Remove stuck pods
    cleanup_inc_006 2>/dev/null || true

    # 3. Delete poison key
    cleanup_inc_004 2>/dev/null || true

    # 4. Reset api-gateway chaos plane
    if _port_alive "$PF_API_CHAOS_LOCAL" || _ensure_pod_forward "$PF_API_CHAOS_LOCAL" "$PF_API_CHAOS_REMOTE" "$API_GATEWAY_LABEL" 2>/dev/null; then
        _chaos_reset_endpoint "http://127.0.0.1:$PF_API_CHAOS_LOCAL/__chaos/reset"
    fi

    # 5. Reset ingestion-worker chaos plane
    if _port_alive "$PF_INGESTION_CHAOS_LOCAL" || _ensure_pod_forward "$PF_INGESTION_CHAOS_LOCAL" "$PF_INGESTION_CHAOS_REMOTE" "$INGESTION_WORKER_LABEL" 2>/dev/null; then
        _chaos_reset_endpoint "http://127.0.0.1:$PF_INGESTION_CHAOS_LOCAL/__chaos/reset"
    fi

    # 6. Kill ALL port-forwards we created
    for port in $PF_API_CHAOS_LOCAL $PF_INGESTION_CHAOS_LOCAL $PF_POSTGRES_LOCAL $PF_VALKEY_LOCAL; do
        _kill_pf "$port"
    done

    # 7. Clean state files
    rm -f "$STATE_DIR"/chaos-pf-*.pid "$STATE_DIR"/chaos-pf-*.log
    rm -f "$STATE_DIR"/chaos-idle-tx.pids
    rm -f "$STATE_DIR"/chaos-stale-pod.name
    rm -f "$STATE_DIR"/chaos-resp.txt

    pass "Global reset complete"
}

# ===========================================================================
# STATUS — show active chaos state
# ===========================================================================

show_status() {
    echo "=== Active Chaos State ==="
    echo ""

    echo "Port-forwards:"
    for port in $PF_API_CHAOS_LOCAL $PF_INGESTION_CHAOS_LOCAL $PF_POSTGRES_LOCAL $PF_VALKEY_LOCAL; do
        local pid_file="$STATE_DIR/chaos-pf-${port}.pid"
        if _port_alive "$port"; then
            local pid="(pid: $(cat "$pid_file" 2>/dev/null || echo '?'))"
            printf "  ${C_GREEN}●${C_RESET} :$port active $pid\n"
        else
            printf "  ${C_DIM}○${C_RESET} :$port inactive\n"
        fi
    done

    echo ""
    echo "State files:"
    local pid_file="$STATE_DIR/chaos-idle-tx.pids"
    if [[ -f "$pid_file" ]]; then
        local count
        count=$(wc -l < "$pid_file" | tr -d ' ')
        printf "  ${C_YELLOW}●${C_RESET} idle-tx sessions: $count PIDs\n"
    else
        printf "  ${C_DIM}○${C_RESET} no idle-tx sessions\n"
    fi

    local name_file="$STATE_DIR/chaos-stale-pod.name"
    if [[ -f "$name_file" ]]; then
        printf "  ${C_YELLOW}●${C_RESET} stuck pod: $(cat "$name_file")\n"
    else
        printf "  ${C_DIM}○${C_RESET} no stuck pod\n"
    fi
}

# ===========================================================================
# DISPATCHER
# ===========================================================================

_dispatch() {
    local incident_id=$1
    local action=$2

    # Normalize to uppercase
    incident_id=$(echo "$incident_id" | tr '[:lower:]' '[:upper:]')

    # Normalize ID format: accept both "INC-003" and "003"
    if [[ "$incident_id" =~ ^[0-9]+$ ]]; then
        incident_id="INC-$(printf '%03d' "$incident_id")"
    fi

    local func_name
    case "$action" in
        trigger)
            func_name="trigger_$(echo "$incident_id" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
            ;;
        cleanup)
            func_name="cleanup_$(echo "$incident_id" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
            ;;
        *)
            fail "Unknown action: $action (expected: trigger|cleanup)"
            ;;
    esac

    # Check if the function exists
    if declare -f "$func_name" > /dev/null 2>&1; then
        "$func_name"
    else
        fail "No handler for $incident_id $action (function $func_name not found)"
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================

usage() {
    cat >&2 <<EOF
Usage:
  $0 <INCIDENT_ID> trigger    Inject fault for the incident
  $0 <INCIDENT_ID> cleanup    Remove fault for the incident
  $0 reset                    Clean ALL chaos state
  $0 status                   Show active chaos state

Incidents:
  INC-001  DatabaseConnectionPoolExhausted  (api-gateway leak-db)
  INC-002  HighCPUUtilization               (api-gateway cpu-spin)
  INC-003  IdleInTransactionBacklog         (5 psql idle-in-tx)
  INC-004  CachePoisonKey                   (Valkey poison key)
  INC-005  ConsumerLagSpike                 (ingestion-worker pause)
  INC-006  StalePodStuckTerminating         (kubectl finalizer)
  INC-007  UpstreamTimeoutCascade           (api-gateway latency)
  INC-008  MemoryPressure                   (ingestion-worker alloc)
  INC-009  PodOOMKilled                     (ingestion-worker OOM)
  INC-010  DuplicateWebhookStorm            (no chaos — webhook only)
  INC-011  ProhibitedNamespaceDeletion      (no chaos — webhook only)
  INC-012  CascadingFailure                 (composite: 001 + 005)
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    case "$1" in
        reset)
            reset_all
            ;;
        status)
            show_status
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        INC-*|inc-*|[0-9]*)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            _dispatch "$1" "$2"
            ;;
        *)
            fail "Unknown command: $1"
            ;;
    esac
}

main "$@"
