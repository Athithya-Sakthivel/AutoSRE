#!/usr/bin/env bash
# =============================================================================
# chaos/lib.sh — Shared chaos helpers for AutoSRE Dataset v4
# =============================================================================

set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="rivulet"
STATE_DIR="${CHAOS_STATE_DIR:-/tmp}"

# Port assignments
API_GATEWAY_CHAOS_PORT="${API_GATEWAY_CHAOS_PORT:-18081}"
INGESTION_CHAOS_PORT="${INGESTION_CHAOS_PORT:-18082}"
POSTGRES_PORT="${POSTGRES_PORT:-15432}"
VALKEY_PORT="${VALKEY_PORT:-16379}"

# Labels
API_GATEWAY_LABEL="app.kubernetes.io/name=api-gateway"
INGESTION_WORKER_LABEL="app.kubernetes.io/name=ingestion-worker"

# Baselines
API_GATEWAY_REPLICAS="${API_GATEWAY_REPLICAS:-2}"
INGESTION_WORKER_REPLICAS="${INGESTION_WORKER_REPLICAS:-2}"

# O2 Config
O2_AUTH="${O2_AUTH:-admin@autosre.local:StagingO2RootPass123!}"

log()  { printf '[chaos] %s\n' "$*" >&2; }
fail() { printf '[chaos] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Port-forward management
# ---------------------------------------------------------------------------

_kill_pf() {
    local local_port=$1
    pkill -f "kubectl port-forward.*:${local_port}" 2>/dev/null || true
    rm -f "${STATE_DIR}/chaos-pf-${local_port}.pid" "${STATE_DIR}/chaos-pf-${local_port}.log"
    sleep 1
}

ensure_forward_pod() {
    local local_port=$1 remote_port=$2 label_selector=$3

    _kill_pf "$local_port"

    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$label_selector" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    [[ -n "$pod" ]] || { log "No running pod for $label_selector"; return 1; }

    log "Port-forward :$local_port → pod/$pod:$remote_port"
    kubectl port-forward "pod/$pod" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >"${STATE_DIR}/chaos-pf-${local_port}.log" 2>&1 &
    echo $! > "${STATE_DIR}/chaos-pf-${local_port}.pid"

    local attempt
    for attempt in $(seq 1 15); do
        if curl -sf --max-time 2 "http://127.0.0.1:${local_port}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    log "Port-forward on :$local_port failed healthz check"
    _kill_pf "$local_port"
    return 1
}

ensure_forward_svc() {
    local local_port=$1 remote_port=$2 svc_name=$3
    _kill_pf "$local_port"

    log "Port-forward :$local_port → svc/$svc_name:$remote_port"
    kubectl port-forward "svc/$svc_name" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >"${STATE_DIR}/chaos-pf-${local_port}.log" 2>&1 &
    echo $! > "${STATE_DIR}/chaos-pf-${local_port}.pid"

    for attempt in $(seq 1 10); do
        if (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    log "Port-forward on :$local_port failed TCP check"
    _kill_pf "$local_port"
    return 1
}

# ---------------------------------------------------------------------------
# Chaos HTTP Helpers
# ---------------------------------------------------------------------------

chaos_post() {
    local url=$1 body=${2:-}
    local args=(-sS -X POST -o "${STATE_DIR}/chaos-resp.txt" -w '%{http_code}' --max-time 15)
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")

    local code
    code=$(curl "${args[@]}" "$url" 2>/dev/null) || { log "curl $url failed"; return 1; }
    if [[ "$code" != "200" && "$code" != "202" ]]; then
        log "POST $url → HTTP $code"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Credential Helpers
# ---------------------------------------------------------------------------

pg_env() {
    kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d || true
}

valkey_password() {
    kubectl get secret valkey-auth -n "$NAMESPACE" \
        -o jsonpath='{.data.VALKEY_PASSWORD}' 2>/dev/null | base64 -d || true
}

# ---------------------------------------------------------------------------
# OpenObserve Log Injection
# ---------------------------------------------------------------------------
# Usage: push_o2_logs <count> '<json_template>' [stream]
#   stream defaults to "app_logs" if not specified
#   Template supports __TIMESTAMP__ placeholder (replaced with ISO8601)
#
# Each template MUST include a "body" field containing the text the O2
# alert condition matches on. K8s label fields (k8s_namespace_name,
# k8s_pod_name) must also be present for multi-alert group_by.
push_o2_logs() {
    local count="$1"
    local template="$2"
    local stream="${3:-app_logs}"
    local ts i entry batch_file
    local stream_url="http://127.0.0.1:15080/api/default/${stream}/_json"

    batch_file=$(mktemp) || return 0
    printf '[' > "$batch_file"

    for i in $(seq 1 "$count"); do
        ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)" || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        entry=$(echo "$template" | sed "s/__TIMESTAMP__/$ts/g")
        [[ "$i" -gt 1 ]] && printf ',' >> "$batch_file"
        printf '%s' "$entry" >> "$batch_file"
    done
    printf ']' >> "$batch_file"

    curl -sf -u "$O2_AUTH" -X POST "$stream_url" \
        -H "Content-Type: application/json" \
        --data-binary "@$batch_file" >/dev/null 2>&1 || true

    rm -f "$batch_file"
    return 0
}

# ---------------------------------------------------------------------------
# Deployment State Management
# ---------------------------------------------------------------------------

save_deployment_image() {
    local deploy="$1"
    local img_file="${STATE_DIR}/chaos-${deploy}-image.txt"
    local image
    image=$(kubectl get deploy "$deploy" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
    [[ -n "$image" ]] && echo "$image" > "$img_file"
}

restore_deployment_image() {
    local deploy="$1"
    local img_file="${STATE_DIR}/chaos-${deploy}-image.txt"
    [[ -f "$img_file" ]] || return 0
    local image=$(cat "$img_file")
    [[ -n "$image" ]] && kubectl set image "deploy/$deploy" "${deploy}=${image}" -n "$NAMESPACE" 2>/dev/null || true
    rm -f "$img_file"
}

reset_deployment_replicas() {
    local deploy="$1" target="$2"
    local current
    current=$(kubectl get deploy "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
    [[ "$current" == "$target" ]] && return 0
    kubectl scale "deploy/$deploy" -n "$NAMESPACE" --replicas="$target" 2>/dev/null || true
    kubectl rollout status "deploy/$deploy" -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
}
