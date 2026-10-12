#!/usr/bin/env bash
# chaos/trigger.sh INC-003
set -Eeuo pipefail
CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -eq 1 ]] || { echo "usage: $0 <INCIDENT_ID>" >&2; exit 1; }
INCIDENT_ID=$1

log() { printf '[chaos] %s\n' "$*" >&2; }

SCRIPT_MAP=(
    "INC-001:inc-001-db-leak.sh"
    "INC-002:inc-002-cpu-spin.sh"
    "INC-003:inc-003-idle-tx.sh"
    "INC-004:inc-004-cache-poison.sh"
    "INC-005:inc-005-consumer-pause.sh"
    "INC-006:inc-006-stale-pod.sh"
    "INC-007:inc-007-latency.sh"
    "INC-008:inc-008-memory.sh"
    "INC-009:inc-009-oom.sh"
    "INC-012:inc-012-cascade.sh"
)

if [[ "$INCIDENT_ID" == "INC-010" || "$INCIDENT_ID" == "INC-011" ]]; then
    log "$INCIDENT_ID is webhook-only; no chaos injection needed"
    exit 0
fi

SCRIPT_NAME=""
for entry in "${SCRIPT_MAP[@]}"; do
    id="${entry%%:*}"
    name="${entry#*:}"
    if [[ "$id" == "$INCIDENT_ID" ]]; then
        SCRIPT_NAME="$name"
        break
    fi
done

if [[ -z "$SCRIPT_NAME" ]]; then
    log "No chaos script for $INCIDENT_ID"
    exit 0
fi

SCRIPT_PATH="$CHAOS_DIR/$SCRIPT_NAME"
[[ -f "$SCRIPT_PATH" ]] || { log "Script not found: $SCRIPT_PATH"; exit 1; }

log "Applying trigger for $INCIDENT_ID"
bash "$SCRIPT_PATH"
log "Trigger for $INCIDENT_ID applied"
