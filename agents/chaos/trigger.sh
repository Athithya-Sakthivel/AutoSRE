#!/usr/bin/env bash
# Apply the chaos trigger for a demo-ready incident.
# Usage: chaos/trigger.sh INC-002

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 1 ]] || fail "usage: $0 <INCIDENT_ID>"
INCIDENT_ID=$1

log "Applying trigger for $INCIDENT_ID"
apply_trigger "$INCIDENT_ID"

SETTLE=$(dataset_field "$INCIDENT_ID" '.trigger.settle_seconds // 5')
log "Settling ${SETTLE}s"
sleep "$SETTLE"
log "Trigger for $INCIDENT_ID applied"
