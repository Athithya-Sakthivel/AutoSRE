#!/usr/bin/env bash
# Return the cluster to baseline. Idempotent.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

log "Reset"
reset_all
log "Reset complete"
