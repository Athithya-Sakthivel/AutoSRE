#!/usr/bin/env bash
# chaos/reset.sh — Clean all chaos state and restore cluster baseline
set -Eeuo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAOS_DIR/lib.sh"

log "Resetting all chaos state"
bash "$CHAOS_DIR/incidents.sh" reset
log "Reset complete"
