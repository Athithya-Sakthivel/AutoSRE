#!/usr/bin/env bash
# chaos/trigger.sh — Convenience wrapper for incidents.sh trigger
set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -eq 1 ]] || { echo "usage: $0 <INCIDENT_ID>" >&2; exit 1; }
INCIDENT_ID=$1

log() { printf '[chaos] %s\n' "$*" >&2; }

INCIDENT_ID=$(echo "$INCIDENT_ID" | tr '[:lower:]' '[:upper:]')
[[ "$INCIDENT_ID" =~ ^[0-9]+$ ]] && INCIDENT_ID="INC-$(printf '%03d' "$INCIDENT_ID")"

if [[ "$INCIDENT_ID" == "INC-010" || "$INCIDENT_ID" == "INC-011" ]]; then
    log "$INCIDENT_ID is webhook-only; no chaos injection needed"
    exit 0
fi

log "Triggering $INCIDENT_ID via incidents.sh"
bash "$CHAOS_DIR/incidents.sh" "$INCIDENT_ID" trigger
log "Trigger for $INCIDENT_ID complete"
