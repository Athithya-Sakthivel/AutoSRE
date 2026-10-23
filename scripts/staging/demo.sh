#!/usr/bin/env bash
# =============================================================================
# demo.sh — AutoSRE Event-Driven Demo
#
# Full event-driven loop:
#   Chaos → O2 Alert → Webhook → Agent Investigation → HITL Approval → Remediation
#
# Architecture:
#   - Agent: in-cluster at autosre-agent.sre.svc.cluster.local:8000
#   - O2 webhook: cluster DNS → agent (no localhost hacks in the data path)
#   - Port-forwards: only for local browser access and chaos log push
#
# Usage:
#   bash demo.sh                          # Default: INC-013 with 90s wait
#   bash demo.sh --incident INC-004       # Different incident
#   bash demo.sh --skip-wait              # Skip O2 evaluation wait
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AGENTS_DIR="/workspace/agents"
AGENT_PORT=18000
AGENT_POD_LABEL="app.kubernetes.io/name=autosre-agent"
O2_API="http://localhost:5080"
O2_AUTH="admin@autosre.local:StagingO2RootPass123!"
ALERT_WAIT="${ALERT_WAIT:-90}"
SKIP_WAIT=0
INCIDENT="INC-013"

PORT_FORWARDS=(
    "5080:openobserve:openobserve:5080:o2-api"
    "15080:openobserve:openobserve:5080:o2-chaos"
    "16379:rivulet:valkey:6379:valkey"
    "15432:rivulet:postgres:5432:postgres"
)

PF_PIDS=()

C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[0;36m'
C_RED=$'\033[0;31m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log()     { printf "${C_CYAN}[+]${C_RESET} %s\n" "$*" >&2; }
success() { printf "${C_GREEN}[✓]${C_RESET} %s\n" "$*" >&2; }
warn()    { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
error()   { printf "${C_RED}[✗]${C_RESET} %s\n" "$*" >&2; }
header()  { printf "\n${C_BOLD}=== %s ===${C_RESET}\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-wait) SKIP_WAIT=1; shift ;;
        --incident) INCIDENT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: bash demo.sh [--skip-wait] [--incident INC-XXX]"
            echo "Default: INC-013 (Valkey eviction + HITL approval)"
            exit 0 ;;
        *) error "Unknown option: $1"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

agent_curl() {
    if [[ -n "${API_KEY:-}" ]]; then
        curl -sf -H "X-API-Key: ${API_KEY}" "$@"
    else
        curl -sf "$@"
    fi
}

o2_curl() { curl -sf -u "${O2_AUTH}" "$@"; }

ensure_pf() {
    local local_port="$1" ns="$2" svc="$3" remote_port="$4" label="$5"
    local log_file="/tmp/pf-${label}.log" pf_pid i

    pkill -f "[k]ubectl.*port-forward.*${local_port}:${remote_port}" 2>/dev/null || true
    fuser -k "${local_port}/tcp" 2>/dev/null || true
    rm -f "${log_file}"

    if (echo >/dev/tcp/127.0.0.1/"${local_port}") 2>/dev/null; then
        return 0
    fi

    nohup kubectl -n "${ns}" port-forward "svc/${svc}" "${local_port}:${remote_port}" \
        >"${log_file}" 2>&1 </dev/null &
    pf_pid=$!
    PF_PIDS+=("${pf_pid}")

    for i in $(seq 1 15); do
        if (echo >/dev/tcp/127.0.0.1/"${local_port}") 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "${pf_pid}" 2>/dev/null; then
            error "Port-forward ${local_port}:${remote_port} (${label}) died:"
            cat "${log_file}" >&2
            return 1
        fi
        sleep 1
    done
    error "Port-forward ${local_port}:${remote_port} (${label}) not ready:"
    cat "${log_file}" >&2
    return 1
}

o2_triggers_query() {
    local alert_name="${1:-}" minutes="${2:-60}"
    local now_us start_us sql result

    now_us=$(($(date +%s) * 1000000))
    start_us=$((now_us - minutes * 60 * 1000000))

    if [[ -n "${alert_name}" ]]; then
        sql="SELECT * FROM triggers WHERE module_key LIKE '%${alert_name}%' OR alert_name='${alert_name}' ORDER BY _timestamp DESC LIMIT 20"
    else
        sql="SELECT * FROM triggers ORDER BY _timestamp DESC LIMIT 20"
    fi

    result=$(o2_curl -X POST "${O2_API}/api/default/_search?type=logs" \
        -H "Content-Type: application/json" \
        -d "{\"query\":{\"sql\":\"${sql}\",\"start_time\":${start_us},\"end_time\":${now_us},\"size\":20}}" \
        2>/dev/null) || true

    if [[ -z "${result}" || "${result}" == "null" ]]; then
        echo '{"hits":[]}'
    else
        echo "${result}"
    fi
}

cleanup() {
    local pid
    log "Cleaning up port-forwards..."
    for pid in "${PF_PIDS[@]}"; do
        kill "${pid}" 2>/dev/null || true
    done
    pkill -f "[k]ubectl.*port-forward" 2>/dev/null || true
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Incident → Alert name mapping
# ---------------------------------------------------------------------------

declare -A ALERT_MAP=(
    ["INC-001"]="DatabaseConnectionPoolExhausted"
    ["INC-002"]="HighCPUUtilization"
    ["INC-003"]="IdleInTransactionBacklog"
    ["INC-004"]="CachePoisonKey"
    ["INC-005"]="ConsumerLagSpike"
    ["INC-006"]="StalePodStuckTerminating"
    ["INC-007"]="PodCrashLoopBackOff"
    ["INC-008"]="MemoryPressure"
    ["INC-009"]="PodOOMKilled"
    ["INC-012"]="ImagePullBackOff"
    ["INC-013"]="ValkeyEvictionUnderPressure"
    ["INC-014"]="ResourceQuotaExceeded"
)

ALERT_NAME="${ALERT_MAP[${INCIDENT}]:-${INCIDENT}}"

# ===========================================================================
# Phase 1: Pre-flight
# ===========================================================================

cd "${AGENTS_DIR}"
header "Phase 1: Pre-flight"

kubectl cluster-info >/dev/null 2>&1 || { error "Kind cluster not reachable"; exit 1; }
success "Kind cluster reachable"

kubectl get deployment autosre-agent -n sre >/dev/null 2>&1 || { error "Agent deployment not found"; exit 1; }
success "Agent deployment exists"

log "Establishing port-forwards..."
for entry in "${PORT_FORWARDS[@]}"; do
    IFS=':' read -r lp ns svc rp label <<< "${entry}"
    ensure_pf "${lp}" "${ns}" "${svc}" "${rp}" "${label}" || { error "Port-forward failed: ${label}"; exit 1; }
    success "  localhost:${lp} → ${ns}/${svc}:${rp}"
done

ensure_pf "${AGENT_PORT}" "sre" "autosre-agent" "8000" "agent" || { error "Agent port-forward failed"; exit 1; }
success "  localhost:${AGENT_PORT} → sre/autosre-agent:8000"

curl -sf "${O2_API}/healthz" >/dev/null 2>&1 || { error "OpenObserve not healthy"; exit 1; }
success "OpenObserve healthy"

curl -sf "http://localhost:${AGENT_PORT}/healthz" >/dev/null 2>&1 || { error "Agent not healthy"; exit 1; }
success "Agent healthy"

AGENT_POD=$(kubectl get pods -n sre -l "${AGENT_POD_LABEL}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "${AGENT_POD}" ]] || { error "Agent pod not found"; exit 1; }
log "Agent pod: ${AGENT_POD}"

API_KEY=$(kubectl get secret autosre-agent-secrets -n sre \
    -o jsonpath='{.data.AUTOSRE_API_KEY}' 2>/dev/null | base64 -d || true)
[[ -n "${API_KEY}" ]] && success "API key loaded" || warn "No API key"

BASELINE=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null \
    | jq -r '.total // 0' 2>/dev/null || echo "0")
BASELINE="${BASELINE:-0}"
log "Baseline incidents: ${BASELINE}"

DATASET_EXISTS=$(kubectl exec -n sre "${AGENT_POD}" -- \
    test -f /app/.venv/lib/python3.14/site-packages/eval/dataset/AutoSRE-Dataset-v4.json \
    && echo "yes" || echo "no" 2>/dev/null || echo "no")
[[ "${DATASET_EXISTS}" == "yes" ]] && success "Dataset v4 present" || warn "Dataset v4 missing"

# ===========================================================================
# Phase 2: Trigger Chaos
# ===========================================================================

header "Phase 2: Trigger Chaos (${INCIDENT})"

log "Running chaos/incidents.sh ${INCIDENT} trigger..."
bash chaos/incidents.sh "${INCIDENT}" trigger 2>&1 | sed 's/^/  /' || true

log "Verifying Valkey state..."
VALKEY_PW=$(kubectl get secret valkey-auth -n rivulet \
    -o jsonpath='{.data.VALKEY_PASSWORD}' 2>/dev/null | base64 -d || true)

if [[ -n "${VALKEY_PW}" ]]; then
    redis-cli -h 127.0.0.1 -p 16379 -a "${VALKEY_PW}" --no-auth-warning \
        INFO memory 2>/dev/null \
        | grep -E "used_memory_human|maxmemory_human|evicted_keys" \
        | sed 's/^/  /' || true
fi

# ===========================================================================
# Phase 3: Wait for O2 Alert
# ===========================================================================

if [[ "${SKIP_WAIT}" == "0" ]]; then
    header "Phase 3: Wait for O2 Alert (1 min evaluation cycle)"
    log "Waiting up to ${ALERT_WAIT}s for O2 scheduler..."

    countdown="${ALERT_WAIT}"
    while [[ "${countdown}" -gt 0 ]]; do
        printf "\r  ${C_CYAN}[%3ds]${C_RESET} Waiting for O2 scheduler..." "${countdown}"
        sleep 10
        countdown=$((countdown - 10))
    done
    echo ""
    success "Wait complete"
else
    header "Phase 3: Wait (SKIPPED)"
fi

# ===========================================================================
# Phase 4: Verify Alert Fired
# ===========================================================================

header "Phase 4: Verify Alert"

log "Checking triggers for: ${ALERT_NAME}"

TRIGGERS=$(o2_triggers_query "${ALERT_NAME}" 120)

TRIGGER_COUNT=$(echo "${TRIGGERS}" | jq '.hits | length' 2>/dev/null || echo "0")
FIRED_COUNT=$(echo "${TRIGGERS}" | jq \
    '[.hits[]? | select(.status == "fired" or .status == "completed")] | length' 2>/dev/null || echo "0")
NOT_MET_COUNT=$(echo "${TRIGGERS}" | jq \
    '[.hits[]? | select(.status == "condition_not_met" or .status == "normal")] | length' 2>/dev/null || echo "0")

log "Trigger evaluations: ${TRIGGER_COUNT}"
log "  Fired/completed: ${FIRED_COUNT}"
log "  Condition not met: ${NOT_MET_COUNT}"

if [[ "${FIRED_COUNT}" -gt 0 ]]; then
    success "O2 alert fired ${FIRED_COUNT} time(s)"
elif [[ "${NOT_MET_COUNT}" -gt 0 ]]; then
    warn "Alert evaluated but condition not met (${NOT_MET_COUNT} time(s))"
else
    warn "No evaluations found"
fi

WEBHOOK_COUNT=$(kubectl logs -n sre "${AGENT_POD}" --tail=200 2>/dev/null \
    | grep -c "Received OpenObserve webhook" || true)
WEBHOOK_COUNT="${WEBHOOK_COUNT:-0}"

[[ "${WEBHOOK_COUNT}" -gt 0 ]] && success "Agent received webhook: ${WEBHOOK_COUNT} time(s)" || warn "No webhooks received"

ENRICH_ERRORS=$(kubectl logs -n sre "${AGENT_POD}" --tail=200 2>/dev/null \
    | grep -c "No dataset file found" || true)
ENRICH_ERRORS="${ENRICH_ERRORS:-0}"
[[ "${ENRICH_ERRORS}" -gt 0 ]] && error "Dataset enrichment failed (${ENRICH_ERRORS} errors)"

# ===========================================================================
# Phase 5: Agent Investigation
# ===========================================================================

header "Phase 5: Agent Investigation"

log "Streaming agent logs (60s)..."
kubectl logs -n sre "${AGENT_POD}" -f --tail=50 2>/dev/null \
    | grep --line-buffered -E \
        "POST /alerts|Alert received|get_valkey_stats|evicted_keys|flush_all|awaiting_approval|proposal|hypothesis|fallback|Pausing for HITL" \
    | head -30 &
LOG_PID=$!

sleep 60
kill "${LOG_PID}" 2>/dev/null || true
wait "${LOG_PID}" 2>/dev/null || true
echo ""

# ===========================================================================
# Phase 6: HITL Approval
# ===========================================================================

header "Phase 6: Check Incident Status"

CURRENT=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null \
    | jq -r '.total // 0' 2>/dev/null || echo "0")
CURRENT="${CURRENT:-0}"
NEW_COUNT=$((CURRENT - BASELINE))

if [[ "${NEW_COUNT}" -gt 0 ]]; then
    success "Agent created ${NEW_COUNT} new incident(s)"

    INCIDENT_DATA=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null \
        | jq '.items[0]' 2>/dev/null || echo "{}")
    INC_ID=$(echo "${INCIDENT_DATA}" | jq -r '.incident_id // "unknown"')
    STATUS=$(echo "${INCIDENT_DATA}" | jq -r '.status // "unknown"')
    ALERT=$(echo "${INCIDENT_DATA}" | jq -r '.alert_name // "unknown"')

    log "Latest incident:"
    log "  ID:     ${INC_ID:0:16}..."
    log "  Alert:  ${ALERT}"
    log "  Status: ${STATUS}"
    echo ""

    if [[ "${STATUS}" == "awaiting_approval" ]]; then
        success "Incident requires human approval (Tier 2)"
        echo ""
        printf "${C_BOLD}${C_GREEN}╔═══════════════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}${C_GREEN}║  Open http://localhost:%-5d in your browser       ║${C_RESET}\n" "${AGENT_PORT}"
        printf "${C_BOLD}${C_GREEN}║  Click the incident → Review evidence → Approve  ║${C_RESET}\n"
        printf "${C_BOLD}${C_GREEN}╚═══════════════════════════════════════════════════╝${C_RESET}\n"
        echo ""
        log "Polling for approval (timeout: 300s)..."

        approved=false
        for i in $(seq 1 60); do
            sleep 5
            REPORT=$(agent_curl "http://localhost:${AGENT_PORT}/incidents/${INC_ID}/report" 2>/dev/null || echo "{}")
            NEW_STATUS=$(echo "${REPORT}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            if [[ "${NEW_STATUS}" == "resolved" ]]; then
                echo ""
                success "Incident approved and resolved!"
                DURATION=$(echo "${REPORT}" | jq -r '.wall_clock_seconds // 0')
                COST=$(echo "${REPORT}" | jq -r '.cost_usd // 0')
                ACTIONS=$(echo "${REPORT}" | jq -r '.executed_actions | length')
                log "  Duration: ${DURATION}s"
                log "  Cost:     \$${COST}"
                log "  Actions:  ${ACTIONS} executed"
                approved=true
                break
            elif [[ "${NEW_STATUS}" == "failed" ]]; then
                echo ""
                error "Incident failed"
                break
            fi
            printf "\r  ${C_DIM}Waiting for approval... (%d/60)${C_RESET}" "${i}"
        done

        [[ "${approved}" == "false" ]] && { echo ""; warn "Approval not received within timeout"; }

    elif [[ "${STATUS}" == "resolved" ]]; then
        success "Incident already resolved"
    else
        warn "Status: ${STATUS}"
    fi
else
    warn "No new incidents created"
    warn "Possible causes:"
    warn "  - Alert in silence window"
    warn "  - Condition not met"
    warn "  - Webhook not received"
fi

# ===========================================================================
# Phase 7: Cleanup
# ===========================================================================

header "Phase 7: Cleanup"

log "Running chaos/incidents.sh ${INCIDENT} cleanup..."
bash chaos/incidents.sh "${INCIDENT}" cleanup 2>&1 | sed 's/^/  /' || true

success "Demo complete"
