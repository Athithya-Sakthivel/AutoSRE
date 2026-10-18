#!/usr/bin/env bash
# =============================================================================
# chaos/incidents.sh — Unified chaos injection for AutoSRE Dataset v4 (14 incidents)
# =============================================================================
#
# Usage:
#   bash chaos/incidents.sh <INCIDENT_ID> trigger    # Inject fault
#   bash chaos/incidents.sh <INCIDENT_ID> cleanup    # Remove fault
#   bash chaos/incidents.sh reset                    # Clean ALL faults
#   bash chaos/incidents.sh status                   # Show active chaos state
#
# Port-forward strategy:
#   Chaos planes (8081) use POD-LEVEL forwarding because the K8s Service
#   only declares port 8080. This bypasses the Service and connects directly
#   to the container's chaos HTTP server.
#
#   Data stores (postgres:5432, valkey:6379) use SERVICE-LEVEL forwarding.
#
# State files (in $STATE_DIR, default /tmp):
#   chaos-pf-*.pid                — Port-forward PIDs
#   chaos-stale-pod.name          — Stuck pod name (INC-006)
#   chaos-api-gateway-image.txt   — Saved image for INC-012 restore
#   chaos-ingestion-worker-image.txt — Saved image for INC-007 restore
# =============================================================================

set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAOS_DIR/lib.sh"

die() { printf '[chaos] ✗ ERROR: %s\n' "$*" >&2; exit 1; }
pass() { printf '[chaos] ✓ %s\n' "$*" >&2; }

_ensure_pod_forward() {
    ensure_forward_pod "$1" "$2" "$3" || die "Port-forward on :$1 failed"
}
_ensure_svc_forward() {
    ensure_forward_svc "$1" "$2" "$3" || die "Port-forward on :$1 failed"
}
_chaos_post() {
    chaos_post "$@" || die "Chaos POST to $1 failed"
}
_chaos_reset_endpoint() {
    curl -sf -X POST "$1" --max-time 10 >/dev/null 2>&1 || true
}

# ===========================================================================
# TRIGGERS
# ===========================================================================

trigger_inc_001() {
    log "INC-001: Leaking DB connections on api-gateway (idle-in-tx)"
    _ensure_pod_forward "$API_GATEWAY_CHAOS_PORT" 8081 "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/leak-db"
    pass "INC-001: Connections leaked (settle 8s)"
    sleep 8
}

trigger_inc_002() {
    log "INC-002: Injecting CPU spin on api-gateway"
    _ensure_pod_forward "$API_GATEWAY_CHAOS_PORT" 8081 "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/cpu-spin"
    pass "INC-002: CPU spin active (settle 15s)"
    sleep 15
}

trigger_inc_003() {
    log "INC-003: Leaking DB connections on api-gateway (idle-in-tx)"
    _ensure_pod_forward "$API_GATEWAY_CHAOS_PORT" 8081 "$API_GATEWAY_LABEL"
    _chaos_post "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/leak-db"
    pass "INC-003: Idle-in-tx sessions active (settle 8s)"
    sleep 8
}

trigger_inc_004() {
    log "INC-004: Writing poison key to Valkey + injecting O2 logs"
    _ensure_svc_forward "$VALKEY_PORT" 6379 valkey
    local pw=$(valkey_password)
    redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
        SET "poison:session:abc123" '{invalid json' >/dev/null 2>&1

    push_o2_logs 10 '{"level":"error","service":"api-gateway","namespace":"rivulet","message":"JSONDecodeError reading cache key poison:session:abc123","error_type":"JSONDecodeError","cache_key":"poison:session:abc123","timestamp":"__TIMESTAMP__"}'
    pass "INC-004: Poison key written + 10 O2 logs pushed (settle 3s)"
    sleep 3
}

trigger_inc_005() {
    log "INC-005: Pausing consumer + injecting 500 messages"
    _ensure_pod_forward "$INGESTION_CHAOS_PORT" 8081 "$INGESTION_WORKER_LABEL"
    _chaos_post "http://127.0.0.1:${INGESTION_CHAOS_PORT}/__chaos/pause-consumer"

    _ensure_svc_forward "$VALKEY_PORT" 6379 valkey
    local pw=$(valkey_password)
    for i in $(seq 1 500); do
        redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            XADD rivulet.orders.in '*' event_id "evt-chaos-$i" user_id "user-1" sku "SKU-1" quantity "1" >/dev/null 2>&1
    done
    pass "INC-005: Consumer paused, 500 messages queued (settle 20s)"
    sleep 20
}

trigger_inc_006() {
    log "INC-006: Creating stuck Terminating pod"
    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$INGESTION_WORKER_LABEL" \
        -o json | jq -r '.items[] | select(.status.phase == "Running") | select(.metadata.deletionTimestamp == null) | .metadata.name' | head -1)
    [[ -n "$pod" ]] || die "No healthy pod found for INC-006"

    kubectl patch pod "$pod" -n "$NAMESPACE" \
        -p '{"metadata":{"finalizers":["autosre.io/test-finalizer"]}}' --type=merge >/dev/null
    kubectl delete pod "$pod" -n "$NAMESPACE" --grace-period=30 --wait=false >/dev/null
    echo "$pod" > "${STATE_DIR}/chaos-stale-pod.name"

    push_o2_logs 5 '{"level":"warn","service":"ingestion-worker","namespace":"rivulet","message":"Pod stuck in Terminating phase","error_type":"PodStuckTerminating","timestamp":"__TIMESTAMP__"}'
    pass "INC-006: Pod $pod stuck in Terminating (settle 10s)"
    sleep 10
}

trigger_inc_007() {
    log "INC-007: Setting bad command on api-gateway → CrashLoopBackOff"
    save_deployment_image "api-gateway"
    kubectl patch deploy api-gateway -n "$NAMESPACE" --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["sh","-c","exit 1"]}]' >/dev/null
    pass "INC-007: Bad command set, CrashLoopBackOff expected in ~30s (settle 30s)"
    sleep 30
}

trigger_inc_008() { pass "INC-008: Annotation-driven (no chaos needed)"; }
trigger_inc_009() { pass "INC-009: Annotation-driven (no chaos needed)"; }
trigger_inc_010() { pass "INC-010: Webhook-only (no chaos needed)"; }
trigger_inc_011() { pass "INC-011: Webhook-only (no chaos needed)"; }

trigger_inc_012() {
    log "INC-012: Setting nonexistent image tag on ingestion-worker"
    save_deployment_image "ingestion-worker"
    kubectl set image deploy/ingestion-worker \
        "ingestion-worker=rivulet/ingestion-worker:v999-nonexistent-$(date +%s)" -n "$NAMESPACE" >/dev/null
    pass "INC-012: Bad image tag set, ImagePullBackOff expected (settle 15s)"
    sleep 15
}

trigger_inc_013() {
    log "INC-013: Filling Valkey to trigger eviction"
    _ensure_svc_forward "$VALKEY_PORT" 6379 valkey
    local pw=$(valkey_password)

    # Use numeric bytes (2097152 = 2MB) for universal compatibility
    redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning CONFIG SET maxmemory 2097152 >/dev/null 2>&1
    redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning CONFIG SET maxmemory-policy allkeys-lru >/dev/null 2>&1

    for i in $(seq 1 3000); do
        redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            SET "fill:$i" "$(head -c 384 /dev/urandom | base64 | head -c 512)" >/dev/null 2>&1
    done
    pass "INC-013: Valkey filled, eviction active (settle 5s)"
    sleep 5
}

trigger_inc_014() {
    log "INC-014: Applying ResourceQuota + scaling beyond limit"
    kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata: { name: eval-quota, namespace: rivulet }
spec: { hard: { pods: "8" } }
EOF
    kubectl scale deploy ingestion-worker -n "$NAMESPACE" --replicas=10 >/dev/null
    pass "INC-014: Quota applied, pods pending (settle 15s)"
    sleep 15
}

# ===========================================================================
# CLEANUPS
# ===========================================================================

cleanup_inc_001() {
    log "INC-001 cleanup"
    _chaos_reset_endpoint "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/reset"
    _kill_pf "$API_GATEWAY_CHAOS_PORT"
    pass "INC-001: Cleaned"
}

cleanup_inc_002() {
    log "INC-002 cleanup"
    _chaos_reset_endpoint "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/reset"
    _kill_pf "$API_GATEWAY_CHAOS_PORT"
    pass "INC-002: Cleaned"
}

cleanup_inc_003() {
    log "INC-003 cleanup"
    _chaos_reset_endpoint "http://127.0.0.1:${API_GATEWAY_CHAOS_PORT}/__chaos/reset"
    _kill_pf "$API_GATEWAY_CHAOS_PORT"
    pass "INC-003: Cleaned"
}

cleanup_inc_004() {
    log "INC-004 cleanup"
    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning DEL "poison:session:abc123" >/dev/null 2>&1 || true
    fi
    _kill_pf "$VALKEY_PORT"
    pass "INC-004: Cleaned"
}

cleanup_inc_005() {
    log "INC-005 cleanup (requires deployment restart to restore consumer context)"
    kubectl rollout restart deploy/ingestion-worker -n "$NAMESPACE" >/dev/null 2>&1 || true

    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning XTRIM rivulet.orders.in MAXLEN 0 >/dev/null 2>&1 || true
    fi
    _kill_pf "$INGESTION_CHAOS_PORT"
    _kill_pf "$VALKEY_PORT"
    kubectl rollout status deploy/ingestion-worker -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
    pass "INC-005: Cleaned"
}

cleanup_inc_006() {
    log "INC-006 cleanup"
    local name_file="${STATE_DIR}/chaos-stale-pod.name"
    if [[ -f "$name_file" ]]; then
        local pod=$(cat "$name_file")
        kubectl patch pod "$pod" -n "$NAMESPACE" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
        kubectl delete pod "$pod" -n "$NAMESPACE" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
        rm -f "$name_file"
    fi
    pass "INC-006: Cleaned"
}

cleanup_inc_007() {
    log "INC-007 cleanup"
    kubectl patch deploy api-gateway -n "$NAMESPACE" --type=json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1 || true
    reset_deployment_replicas "api-gateway" "$API_GATEWAY_REPLICAS"
    pass "INC-007: Cleaned"
}

cleanup_inc_008() { pass "INC-008: No cleanup needed"; }
cleanup_inc_009() { pass "INC-009: No cleanup needed"; }
cleanup_inc_010() { pass "INC-010: No cleanup needed"; }
cleanup_inc_011() { pass "INC-011: No cleanup needed"; }

cleanup_inc_012() {
    log "INC-012 cleanup"
    restore_deployment_image "ingestion-worker"
    kubectl rollout status deploy/ingestion-worker -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
    pass "INC-012: Cleaned"
}

cleanup_inc_013() {
    log "INC-013 cleanup"
    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        if [[ -n "$pw" ]]; then
            redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning FLUSHALL >/dev/null 2>&1 || true
            redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning CONFIG SET maxmemory 0 >/dev/null 2>&1 || true
        fi
    fi
    _kill_pf "$VALKEY_PORT"
    pass "INC-013: Cleaned"
}

cleanup_inc_014() {
    log "INC-014 cleanup"
    kubectl scale deploy ingestion-worker -n "$NAMESPACE" --replicas="$INGESTION_WORKER_REPLICAS" >/dev/null 2>&1 || true
    kubectl delete resourcequota eval-quota -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    kubectl rollout status deploy/ingestion-worker -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
    pass "INC-014: Cleaned"
}

# ===========================================================================
# GLOBAL RESET
# ===========================================================================
reset_all() {
    log "Global reset: cleaning ALL chaos state"

    # 1. Clean specific incident states
    for inc in 001 002 003 004 005 006 007 012 013 014; do
        local func="cleanup_inc_${inc}"
        [[ "$(type -t "$func")" == "function" ]] && "$func" 2>/dev/null || true
    done

    # 2. Restore deployment baselines
    kubectl patch deploy api-gateway -n "$NAMESPACE" --type=json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1 || true
    reset_deployment_replicas "api-gateway" "$API_GATEWAY_REPLICAS"
    reset_deployment_replicas "ingestion-worker" "$INGESTION_WORKER_REPLICAS"

    # 3. Restore images
    restore_deployment_image "api-gateway"
    restore_deployment_image "ingestion-worker"

    # 4. Clean K8s resources
    kubectl delete resourcequota eval-quota -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

    # 5. Flush Valkey
    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning FLUSHALL >/dev/null 2>&1 || true
    fi

    # 6. Kill all port-forwards
    for port in "$API_GATEWAY_CHAOS_PORT" "$INGESTION_CHAOS_PORT" "$POSTGRES_PORT" "$VALKEY_PORT"; do
        _kill_pf "$port"
    done

    # 7. Clean state files
    rm -f "${STATE_DIR}"/chaos-*.txt "${STATE_DIR}"/chaos-*.log "${STATE_DIR}"/chaos-resp.txt
    pass "Global reset complete"
}

# ===========================================================================
# DISPATCHER
# ===========================================================================
_dispatch() {
    local incident_id=$1 action=$2
    incident_id=$(echo "$incident_id" | tr '[:lower:]' '[:upper:]')
    [[ "$incident_id" =~ ^[0-9]+$ ]] && incident_id="INC-$(printf '%03d' "$incident_id")"

    local func_name="${action}_$(echo "$incident_id" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    [[ "$(type -t "$func_name")" == "function" ]] || die "No handler for $incident_id $action"
    "$func_name"
}

main() {
    case "${1:-}" in
        reset) reset_all ;;
        INC-*|inc-*|[0-9]*)
            [[ $# -ge 2 ]] || { echo "Usage: $0 <INCIDENT_ID> <trigger|cleanup>"; exit 1; }
            _dispatch "$1" "$2" ;;
        *) echo "Usage: $0 <INCIDENT_ID> <trigger|cleanup> | reset"; exit 1 ;;
    esac
}

main "$@"
