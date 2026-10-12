#!/usr/bin/env bash
set -Eeuo pipefail
CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAOS_DIR/lib.sh"

log "Resetting all chaos state"

# Kill idle-in-tx sessions
if [[ -f /tmp/chaos-idle-tx.pids ]]; then
    while read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < /tmp/chaos-idle-tx.pids
    rm -f /tmp/chaos-idle-tx.pids
    log "Killed idle-in-tx sessions"
fi

# Remove stale pod finalizers
if [[ -f /tmp/chaos-stale-pod.name ]]; then
    POD_NAME=$(cat /tmp/chaos-stale-pod.name)
    kubectl patch pod "$POD_NAME" -n rivulet \
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete pod "$POD_NAME" -n rivulet --ignore-not-found 2>/dev/null || true
    rm -f /tmp/chaos-stale-pod.name
    log "Cleaned stale pod $POD_NAME"
fi

# Delete poison key
ensure_forward_svc "$VALKEY_PORT" 6379 valkey || true
pw=$(valkey_password)
if [[ -n "$pw" ]]; then
    redis-cli -h "$VALKEY_HOST" -p "$VALKEY_PORT" -a "$pw" \
        DEL "poison:session:abc123" 2>/dev/null || true
fi

# Reset chaos planes
ensure_forward_pod "$API_GATEWAY_CHAOS_PORT" 8081 "app.kubernetes.io/name=api-gateway" || true
curl -sf -X POST "http://127.0.0.1:$API_GATEWAY_CHAOS_PORT/__chaos/reset" >/dev/null 2>&1 || true

ensure_forward_pod "$INGESTION_CHAOS_PORT" 8081 "app.kubernetes.io/name=ingestion-worker" || true
curl -sf -X POST "http://127.0.0.1:$INGESTION_CHAOS_PORT/__chaos/reset" >/dev/null 2>&1 || true

log "Reset complete"
