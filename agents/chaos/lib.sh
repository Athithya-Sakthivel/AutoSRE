#!/usr/bin/env bash
# chaos/lib.sh — Shared chaos helpers
set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$CHAOS_DIR/.." && pwd)"

NAMESPACE="rivulet"
API_GATEWAY_CHAOS_PORT="${API_GATEWAY_CHAOS_PORT:-18081}"
INGESTION_CHAOS_PORT="${INGESTION_CHAOS_PORT:-18082}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
POSTGRES_PORT="${POSTGRES_PORT:-15432}"
VALKEY_HOST="${VALKEY_HOST:-127.0.0.1}"
VALKEY_PORT="${VALKEY_PORT:-16379}"

log()  { printf '[chaos] %s\n' "$*" >&2; }
fail() { printf '[chaos] ERROR: %s\n' "$*" >&2; exit 1; }

ensure_forward_pod() {
    local local_port=$1 remote_port=$2 label_selector=$3
    if (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; then
        return 0
    fi
    local pod
    pod=$(kubectl get pods -n "$NAMESPACE" -l "$label_selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$pod" ]] || fail "no pod found for label: $label_selector"
    log "Port-forward $local_port → pod/$pod:$remote_port"
    kubectl port-forward "pod/$pod" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >/tmp/chaos-pf-"$local_port".log 2>&1 &
    for _ in 1 2 3 4 5 6; do
        sleep 1
        (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null && return 0
    done
    fail "port-forward on $local_port did not come up"
}

ensure_forward_svc() {
    local local_port=$1 remote_port=$2 svc_name=$3
    if (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; then
        return 0
    fi
    log "Port-forward $local_port → svc/$svc_name:$remote_port"
    kubectl port-forward "svc/$svc_name" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >/tmp/chaos-pf-"$local_port".log 2>&1 &
    for _ in 1 2 3 4 5 6; do
        sleep 1
        (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null && return 0
    done
    fail "port-forward on $local_port did not come up"
}

chaos_post() {
    local url=$1 body=${2:-}
    local args=(-sS -X POST -o /tmp/chaos-resp.txt -w '%{http_code}')
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' -d "$body")
    fi
    local code
    code=$(curl "${args[@]}" "$url") || fail "curl $url failed"
    if [[ "$code" != "200" && "$code" != "202" ]]; then
        log "POST $url → $code"
        head -c 500 /tmp/chaos-resp.txt >&2
        return 1
    fi
    return 0
}

pg_env() {
    local name=$1
    kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath="{.data.$name}" 2>/dev/null | base64 -d
}

valkey_password() {
    kubectl get secret valkey-auth -n "$NAMESPACE" \
        -o jsonpath='{.data.VALKEY_PASSWORD}' 2>/dev/null | base64 -d
}
