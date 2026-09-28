#!/usr/bin/env bash
# Shared chaos helpers. Sourced by trigger.sh and reset.sh.

set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$CHAOS_DIR/.." && pwd)"
DATASET="$AGENTS_DIR/eval/dataset/AutoSRE-Dataset-v3.json"

NAMESPACE="rivulet"
API_GATEWAY_CHAOS_PORT="${API_GATEWAY_CHAOS_PORT:-18081}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
POSTGRES_PORT="${POSTGRES_PORT:-15432}"

log()  { printf '[chaos] %s\n' "$*" >&2; }
fail() { printf '[chaos] ERROR: %s\n' "$*" >&2; exit 1; }

# Bring up a port-forward if the local port isn't already listening.
# Args: local_port remote_port "svc/name"|"deploy/name"
ensure_forward() {
    local local_port=$1 remote_port=$2 target=$3
    if (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; then
        return 0
    fi
    log "Port-forward $local_port → $target:$remote_port"
    kubectl port-forward "$target" "$local_port:$remote_port" -n "$NAMESPACE" \
        < /dev/null >/tmp/chaos-pf-"$local_port".log 2>&1 &
    for _ in 1 2 3 4 5 6; do
        sleep 1
        (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null && return 0
    done
    cat /tmp/chaos-pf-"$local_port".log >&2
    fail "port-forward on $local_port did not come up"
}

# POST JSON to a chaos endpoint. Returns 0 only on HTTP 200/202.
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

# Read a field from the dataset entry for an incident.
dataset_field() {
    local id=$1 path=$2
    jq -r --arg id "$id" ".incidents[] | select(.id==\$id) | $path" "$DATASET"
}

# Fetch postgres credentials from the in-cluster secret.
pg_env() {
    local name=$1
    kubectl get secret postgres-rivulet-env -n "$NAMESPACE" \
        -o jsonpath="{.data.$name}" 2>/dev/null | base64 -d
}

# ---------------------------------------------------------------------------
# Mechanisms
# ---------------------------------------------------------------------------

# INC-002: cpu-spin on api-gateway. Raises container CPU for 5 minutes.
_trigger_cpu_spin() {
    ensure_forward "$API_GATEWAY_CHAOS_PORT" 8081 svc/api-gateway
    chaos_post "http://127.0.0.1:$API_GATEWAY_CHAOS_PORT/__chaos/cpu-spin" \
        '{"duration_sec": 300}'
    log "cpu-spin active on api-gateway for 300s"
}

# INC-003: 5 psql sessions that BEGIN and sleep 600s, holding a
# connection idle-in-transaction.
_trigger_idle_in_transaction() {
    ensure_forward "$POSTGRES_PORT" 5432 svc/postgres

    local pw user db
    pw=$(pg_env PGPASSWORD)
    user=$(pg_env PGUSER)
    db=$(pg_env PGDATABASE)

    [[ -n "$pw" && -n "$user" && -n "$db" ]] \
        || fail "could not read postgres secret"

    : > /tmp/chaos-idle-tx.pids
    local i
    for i in 1 2 3 4 5; do
        PGPASSWORD="$pw" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
            -U "$user" -d "$db" \
            -c "BEGIN; SELECT 1; SELECT pg_sleep(600);" \
            >/dev/null 2>&1 &
        printf '%s\n' "$!" >> /tmp/chaos-idle-tx.pids
    done
    log "5 idle-in-transaction sessions launched"
}

_cleanup_idle_tx() {
    [[ -f /tmp/chaos-idle-tx.pids ]] || return 0
    while read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < /tmp/chaos-idle-tx.pids
    rm -f /tmp/chaos-idle-tx.pids
}

# Dispatch by incident ID.
apply_trigger() {
    case "$1" in
        INC-002) _trigger_cpu_spin ;;
        INC-003) _trigger_idle_in_transaction ;;
        *) log "no chaos implemented for $1; dataset-only"; return 0 ;;
    esac
}

reset_all() {
    ensure_forward "$API_GATEWAY_CHAOS_PORT" 8081 svc/api-gateway || true
    curl -sf -X POST "http://127.0.0.1:$API_GATEWAY_CHAOS_PORT/__chaos/reset" \
        >/dev/null 2>&1 || true
    _cleanup_idle_tx 2>/dev/null || true
}
