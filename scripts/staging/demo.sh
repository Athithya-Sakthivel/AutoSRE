#!/usr/bin/env bash
# =============================================================================
# demo.sh — AutoSRE Event-Driven Demo
# =============================================================================
#
# Options:
#   --incident INC-XXX    Incident to demo (default: INC-013)
#   --skip-wait           Skip the OpenObserve alert countdown (Phase 3)
#                         and the post-demo interactive hold (Phase 8).
#   --no-cleanup          Leave port-forwards alive after exit.
#
# Default behavior: full interactive demo. After the incident reaches a
# terminal state, the script holds open so you can inspect the UI and
# OpenObserve. Press ENTER (or Ctrl+C) to shut down.
# =============================================================================

set -Eeuo pipefail

AGENTS_DIR="/workspace/agents"
AGENT_PORT=18000
AGENT_POD_LABEL="app.kubernetes.io/name=autosre-agent"
O2_API="http://localhost:5080"
O2_AUTH="admin@autosre.local:StagingO2RootPass123!"
ALERT_WAIT="${ALERT_WAIT:-90}"
SKIP_WAIT=0
INCIDENT="INC-013"
NO_CLEANUP=0

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

log()     { printf "${C_CYAN}[+]${C_RESET} %s\n" "$*" >&2; }
success() { printf "${C_GREEN}[✓]${C_RESET} %s\n" "$*" >&2; }
warn()    { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
error()   { printf "${C_RED}[✗]${C_RESET} %s\n" "$*" >&2; }
header()  { printf "\n${C_BOLD}=== %s ===${C_RESET}\n" "$*" >&2; }

agent_curl() {
    if [[ -n "${API_KEY:-}" ]]; then
        curl -sf -H "X-API-Key: ${API_KEY}" "$@"
    else
        curl -sf "$@"
    fi
}

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
            error "Port-forward ${local_port}:${remote_port} (${label}) died"
            return 1
        fi
        sleep 1
    done
    error "Port-forward ${local_port}:${remote_port} (${label}) not ready"
    return 1
}

cleanup_port_forwards() {
    if [[ "$NO_CLEANUP" == "1" ]]; then
        success "Port-forwards kept alive (--no-cleanup)"
        log "Agent UI: http://localhost:${AGENT_PORT}"
        log "OpenObserve: http://localhost:5080"
        log "Kill manually: pkill -f 'kubectl.*port-forward'"
        return 0
    fi

    log "Cleaning up port-forwards..."
    for pid in "${PF_PIDS[@]}"; do
        kill "${pid}" 2>/dev/null || true
    done
    pkill -f "[k]ubectl.*port-forward" 2>/dev/null || true
}

trap cleanup_port_forwards EXIT

declare -A ALERT_MAP=(
    ["INC-013"]="ValkeyEvictionUnderPressure"
    ["INC-004"]="CachePoisonKey"
    ["INC-002"]="HighCPUUtilization"
)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-wait) SKIP_WAIT=1; shift ;;
        --incident) INCIDENT="$2"; shift 2 ;;
        --no-cleanup) NO_CLEANUP=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: bash demo.sh [OPTIONS]

  --incident INC-XXX    Incident to demo (default: INC-013)
  --skip-wait           Skip the OpenObserve alert countdown (Phase 3)
                        and the post-demo interactive hold (Phase 8).
  --no-cleanup          Leave port-forwards alive after exit.
EOF
            exit 0 ;;
        *) error "Unknown option: $1"; exit 2 ;;
    esac
done

ALERT_NAME="${ALERT_MAP[${INCIDENT}]:-${INCIDENT}}"

cd "${AGENTS_DIR}"

# Phase 1: Pre-flight
header "Phase 1: Pre-flight"
kubectl cluster-info >/dev/null 2>&1 || { error "Kind cluster not reachable"; exit 1; }
kubectl get deployment autosre-agent -n sre >/dev/null 2>&1 || { error "Agent deployment not found"; exit 1; }

for entry in "${PORT_FORWARDS[@]}"; do
    IFS=':' read -r lp ns svc rp label <<< "${entry}"
    ensure_pf "${lp}" "${ns}" "${svc}" "${rp}" "${label}" || { error "Port-forward failed: ${label}"; exit 1; }
done
ensure_pf "${AGENT_PORT}" "sre" "autosre-agent" "8000" "agent" || { error "Agent port-forward failed"; exit 1; }

curl -sf "${O2_API}/healthz" >/dev/null 2>&1 || { error "OpenObserve not healthy"; exit 1; }
curl -sf "http://localhost:${AGENT_PORT}/healthz" >/dev/null 2>&1 || { error "Agent not healthy"; exit 1; }
success "All systems ready"

AGENT_POD=$(kubectl get pods -n sre -l "${AGENT_POD_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
API_KEY=$(kubectl get secret autosre-agent-secrets -n sre -o jsonpath='{.data.AUTOSRE_API_KEY}' 2>/dev/null | base64 -d || true)
BASELINE=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null | jq -r '.total // 0' 2>/dev/null || echo "0")

# Phase 2: Trigger Chaos
header "Phase 2: Trigger Chaos (${INCIDENT})"
bash chaos/incidents.sh "${INCIDENT}" trigger 2>&1 | grep -E "^\[chaos\] ✓" | sed 's/^/  /' || true
success "Chaos injected"

# Phase 3: Wait for O2 Alert
if [[ "${SKIP_WAIT}" == "0" ]]; then
    header "Phase 3: Wait for O2 Alert"
    countdown="${ALERT_WAIT}"
    while [[ "${countdown}" -gt 0 ]]; do
        printf "\r  ${C_CYAN}[%3ds]${C_RESET} Waiting..." "${countdown}" >&2
        sleep 10
        countdown=$((countdown - 10))
    done
    printf "\r%60s\r" "" >&2
    success "Wait complete"
fi

# Phase 4: Verify Webhook
header "Phase 4: Verify Webhook"
WEBHOOK_COUNT=$(kubectl logs -n sre "${AGENT_POD}" --tail=200 2>/dev/null | grep -c "Received OpenObserve webhook" || true)
[[ "${WEBHOOK_COUNT}" -gt 0 ]] && success "Webhook delivered" || warn "Webhook not yet received"

# Phase 5: Agent Investigation
header "Phase 5: Agent Investigation"
log "Agent investigating alert..."

INC_ID=""
STATUS="unknown"
for i in $(seq 1 20); do
    CURRENT=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null | jq -r '.total // 0' 2>/dev/null || echo "0")
    if [[ "${CURRENT}" -gt "${BASELINE}" ]]; then
        INCIDENT_DATA=$(agent_curl "http://localhost:${AGENT_PORT}/incidents" 2>/dev/null | jq '.items[0]' 2>/dev/null || echo "{}")
        INC_ID=$(echo "${INCIDENT_DATA}" | jq -r '.incident_id // "unknown"')
        STATUS=$(echo "${INCIDENT_DATA}" | jq -r '.status // "unknown"')
        success "Incident created (status: ${STATUS})"
        break
    fi
    sleep 5
done

if [[ -z "${INC_ID}" ]]; then
    warn "No incident was created within 100s"
fi

# Phase 6: Wait for Incident Terminal State (quiet polling)
header "Phase 6: Human-in-the-Loop Approval"

if [[ -n "${INC_ID}" ]]; then
    if [[ "${STATUS}" == "resolved" ]]; then
        success "Incident already resolved"
    elif [[ "${STATUS}" == "failed" || "${STATUS}" == "no_action" ]]; then
        warn "Incident terminal: ${STATUS}"
    else
        # Running or awaiting approval — enter quiet polling.
        if [[ "${STATUS}" == "awaiting_approval" ]]; then
            log "Awaiting human approval for incident ${INC_ID}"
            log "Open http://localhost:${AGENT_PORT} in your browser to approve"
        else
            log "Incident ${INC_ID} investigating (status: ${STATUS})"
        fi

        printf "  ${C_CYAN}[~]${C_RESET} Waiting for completion (up to 5 min)..." >&2

        RESOLVED=0
        FAILED=0
        REPORT=""
        NEW_STATUS="${STATUS}"

        for i in $(seq 1 60); do
            REPORT=$(agent_curl "http://localhost:${AGENT_PORT}/incidents/${INC_ID}/report" 2>/dev/null || echo "{}")
            NEW_STATUS=$(echo "${REPORT}" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            if [[ "${NEW_STATUS}" == "resolved" ]]; then
                RESOLVED=1
                printf " ${C_GREEN}✓ resolved${C_RESET}\n" >&2
                break
            elif [[ "${NEW_STATUS}" == "failed" ]]; then
                FAILED=1
                printf " ${C_RED}✗ failed${C_RESET}\n" >&2
                break
            elif [[ "${NEW_STATUS}" == "no_action" ]]; then
                printf " ${C_YELLOW}no_action${C_RESET}\n" >&2
                break
            fi
            sleep 5
        done

        if [[ "${RESOLVED}" == "1" ]]; then
            DURATION=$(echo "${REPORT}" | jq -r '.wall_clock_seconds // 0')
            COST=$(echo "${REPORT}" | jq -r '.cost_usd // 0')
            ACTIONS=$(echo "${REPORT}" | jq -r '.executed_actions | length' 2>/dev/null || echo "0")
            success "Incident resolved"
            log "Duration: ${DURATION}s | Cost: \$${COST} | Actions: ${ACTIONS}"
        elif [[ "${FAILED}" == "1" ]]; then
            error "Incident failed"
        elif [[ "${NEW_STATUS}" != "no_action" ]]; then
            printf "\r%60s\r" "" >&2
            warn "Incident did not reach a terminal state within 5 min (last: ${NEW_STATUS})"
        fi
    fi
fi

# Phase 7: Cleanup Chaos
header "Phase 7: Cleanup Chaos"
bash chaos/incidents.sh "${INCIDENT}" cleanup 2>&1 | grep -E "^\[chaos\] ✓" | sed 's/^/  /' || true
success "Chaos cleanup complete"

# Phase 8: Hold open (unless --skip-wait)
if [[ "${SKIP_WAIT}" == "1" ]]; then
    log "Skipping interactive hold (--skip-wait)"
else
    header "Demo Complete"
    cat >&2 <<EOF

  ${C_BOLD}${C_GREEN}Services are still running:${C_RESET}

    ${C_BOLD}Agent UI${C_RESET}     http://localhost:${AGENT_PORT}
    ${C_BOLD}OpenObserve${C_RESET}  http://localhost:5080

  ${C_DIM}Port-forward logs:${C_RESET} /tmp/pf-*.log

  ${C_BOLD}Press ENTER to shut down (or Ctrl+C).${C_RESET}

EOF
    read -r || true
    echo "" >&2
    if [[ "${NO_CLEANUP}" == "1" ]]; then
        log "Exiting without cleanup (--no-cleanup)"
    else
        log "Shutting down port-forwards…"
    fi
fi
