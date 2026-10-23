#!/usr/bin/env bash
# =============================================================================
# chaos/incidents.sh — Unified chaos injection for AutoSRE Dataset v4
# =============================================================================
#
# Usage:
#   bash chaos/incidents.sh <INCIDENT_ID> trigger
#   bash chaos/incidents.sh <INCIDENT_ID> cleanup
#   bash chaos/incidents.sh reset
#
# Stream routing (each push must go to the stream the alert watches):
#   app_logs:    INC-004, INC-006, INC-007, INC-009, INC-012, INC-014
#   valkey_logs: INC-005, INC-013
#   postgres_logs: INC-001, INC-003 (real logs from postgres container)
#   metrics:     INC-002, INC-008 (real metrics from kubelet)
#
# Every synthetic push includes:
#   - "body" field with the text the alert condition matches
#   - "k8s_namespace_name" and "k8s_pod_name" for group_by
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

    # Push to app_logs (the stream the alert watches)
    # body must contain "JSONDecodeError" for the alert condition
    push_o2_logs 12 \
        '{"body":"JSONDecodeError reading cache key poison:session:abc123","level":"error","k8s_namespace_name":"rivulet","k8s_pod_name":"api-gateway-0","error_type":"JSONDecodeError","cache_key":"poison:session:abc123","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-004: Poison key written + 12 logs → app_logs (settle 3s)"
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

    # Push to valkey_logs (the stream the alert watches)
    # body must contain "pending" for the alert condition
    push_o2_logs 12 \
        '{"body":"Consumer group pending backlog exceeding threshold: 1200 pending messages in rivulet.orders.in","level":"warning","k8s_namespace_name":"rivulet","k8s_pod_name":"ingestion-worker-0","stream":"rivulet.orders.in","pending_count":"1200","timestamp":"__TIMESTAMP__"}' \
        valkey_logs

    pass "INC-005: Consumer paused, 500 messages queued + 12 logs → valkey_logs (settle 20s)"
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

    # Push to app_logs (the stream the alert watches)
    # body must contain "Terminating" for the alert condition
    push_o2_logs 12 \
        '{"body":"Pod stuck in Terminating phase for over 60 seconds: finalizer blocking deletion","level":"warning","k8s_namespace_name":"rivulet","k8s_pod_name":"'"$pod"'","error_type":"PodStuckTerminating","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-006: Pod $pod stuck in Terminating + 12 logs → app_logs (settle 10s)"
    sleep 10
}

trigger_inc_007() {
    log "INC-007: Setting bad command on api-gateway → CrashLoopBackOff"
    save_deployment_image "api-gateway"
    kubectl patch deploy api-gateway -n "$NAMESPACE" --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["sh","-c","exit 1"]}]' >/dev/null

    # K8s generates CrashLoopBackOff in pod events, not container logs.
    # Push synthetic signal to app_logs so the alert can match.
    push_o2_logs 12 \
        '{"body":"Back-off restarting failed container: CrashLoopBackOff","level":"error","k8s_namespace_name":"rivulet","k8s_pod_name":"api-gateway-0","error_type":"CrashLoopBackOff","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-007: Bad command set + 12 logs → app_logs (settle 30s)"
    sleep 30
}

trigger_inc_008() { pass "INC-008: Annotation-driven (no chaos needed)"; }
trigger_inc_009() {
    log "INC-009: OOMKilled signal (annotation-driven + synthetic log)"

    # K8s generates OOMKilled in pod events, not container logs.
    # Push synthetic signal to app_logs so the alert can match.
    push_o2_logs 12 \
        '{"body":"Container OOMKilled: memory limit exceeded (256Mi)","level":"error","k8s_namespace_name":"rivulet","k8s_pod_name":"ingestion-worker-0","error_type":"OOMKilled","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-009: 12 OOMKilled logs → app_logs (settle 5s)"
    sleep 5
}
trigger_inc_010() { pass "INC-010: Webhook-only (no chaos needed)"; }
trigger_inc_011() { pass "INC-011: Webhook-only (no chaos needed)"; }

trigger_inc_012() {
    log "INC-012: Setting nonexistent image tag on ingestion-worker"
    save_deployment_image "ingestion-worker"
    kubectl set image deploy/ingestion-worker \
        "ingestion-worker=rivulet/ingestion-worker:v999-nonexistent-$(date +%s)" -n "$NAMESPACE" >/dev/null

    # K8s generates ImagePullBackOff in pod events, not container logs.
    # Push synthetic signal to app_logs so the alert can match.
    push_o2_logs 12 \
        '{"body":"Failed to pull image: ImagePullBackOff - tag v999-nonexistent not found","level":"error","k8s_namespace_name":"rivulet","k8s_pod_name":"ingestion-worker-0","error_type":"ImagePullBackOff","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-012: Bad image tag set + 12 logs → app_logs (settle 15s)"
    sleep 15
}

trigger_inc_013() {
    log "INC-013: Filling Valkey to trigger eviction"
    _ensure_svc_forward "$VALKEY_PORT" 6379 valkey
    local pw=$(valkey_password)

    # Set maxmemory to 2MB and allkeys-lru eviction policy
    redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
        CONFIG SET maxmemory 2097152 >/dev/null 2>&1
    redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
        CONFIG SET maxmemory-policy allkeys-lru >/dev/null 2>&1

    # Fill valkey to trigger eviction
    for i in $(seq 1 3000); do
        redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            SET "fill:$i" "$(head -c 384 /dev/urandom | base64 | head -c 512)" >/dev/null 2>&1
    done

    # Read the real eviction counter from valkey
    local evicted
    evicted=$(redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
        INFO stats 2>/dev/null | tr -d '\r' | grep '^evicted_keys:' | cut -d: -f2)
    evicted="${evicted:-0}"

    # Valkey does NOT log eviction events to stdout, so OTel never sees them.
    # Push to valkey_logs (the stream the alert watches) with the real counter.
    # body must contain "evict" for the alert condition.
    push_o2_logs 12 \
        '{"body":"Valkey maxmemory reached: evicted '"${evicted}"' keys under allkeys-lru policy","level":"warning","k8s_namespace_name":"rivulet","k8s_pod_name":"valkey-0","message":"evicted_keys='"${evicted}"'","timestamp":"__TIMESTAMP__"}' \
        valkey_logs

    pass "INC-013: Valkey filled (evicted_keys=${evicted}), 12 logs → valkey_logs (settle 5s)"
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

    # K8s generates quota exceeded in pod events, not container logs.
    # Push synthetic signal to app_logs so the alert can match.
    push_o2_logs 12 \
        '{"body":"Failed to create pod: exceeded quota: eval-quota, requested: pods=1, used: pods=8, limited: pods=8","level":"error","k8s_namespace_name":"rivulet","k8s_pod_name":"ingestion-worker-0","error_type":"ExceededQuota","timestamp":"__TIMESTAMP__"}' \
        app_logs

    pass "INC-014: Quota applied + 12 logs → app_logs (settle 15s)"
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
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            DEL "poison:session:abc123" >/dev/null 2>&1 || true
    fi
    _kill_pf "$VALKEY_PORT"
    pass "INC-004: Cleaned"
}

cleanup_inc_005() {
    log "INC-005 cleanup (requires deployment restart to restore consumer)"
    kubectl rollout restart deploy/ingestion-worker -n "$NAMESPACE" >/dev/null 2>&1 || true

    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            XTRIM rivulet.orders.in MAXLEN 0 >/dev/null 2>&1 || true
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
        kubectl patch pod "$pod" -n "$NAMESPACE" --type=json \
            -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
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
    log "INC-012 cleanup: restoring ingestion-worker image"
    restore_deployment_image "ingestion-worker"

    local current_image
    current_image=$(kubectl get deploy ingestion-worker -n rivulet \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    if [[ "$current_image" == *"v999-nonexistent"* ]]; then
        kubectl set image deploy/ingestion-worker \
            ingestion-worker=rivulet/ingestion-worker:latest -n rivulet
    fi

    kubectl delete pod -n rivulet -l app.kubernetes.io/name=ingestion-worker \
        --field-selector=status.phase=Pending --force --grace-period=0 2>/dev/null || true

    kubectl rollout status deploy/ingestion-worker -n rivulet --timeout=120s 2>/dev/null || true
    pass "INC-012: Cleaned"
}

cleanup_inc_013() {
    log "INC-013 cleanup"
    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        if [[ -n "$pw" ]]; then
            redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
                FLUSHALL >/dev/null 2>&1 || true
            redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
                CONFIG SET maxmemory 0 >/dev/null 2>&1 || true
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

    for inc in 001 002 003 004 005 006 007 012 013 014; do
        local func="cleanup_inc_${inc}"
        [[ "$(type -t "$func")" == "function" ]] && "$func" 2>/dev/null || true
    done

    kubectl patch deploy api-gateway -n "$NAMESPACE" --type=json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1 || true
    reset_deployment_replicas "api-gateway" "$API_GATEWAY_REPLICAS"
    reset_deployment_replicas "ingestion-worker" "$INGESTION_WORKER_REPLICAS"

    restore_deployment_image "api-gateway"
    restore_deployment_image "ingestion-worker"

    kubectl delete resourcequota eval-quota -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

    if ensure_forward_svc "$VALKEY_PORT" 6379 valkey 2>/dev/null; then
        local pw=$(valkey_password)
        [[ -n "$pw" ]] && redis-cli -h 127.0.0.1 -p "$VALKEY_PORT" -a "$pw" --no-auth-warning \
            FLUSHALL >/dev/null 2>&1 || true
    fi

    for port in "$API_GATEWAY_CHAOS_PORT" "$INGESTION_CHAOS_PORT" "$POSTGRES_PORT" "$VALKEY_PORT"; do
        _kill_pf "$port"
    done

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
