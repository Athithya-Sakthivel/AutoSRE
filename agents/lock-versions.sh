#!/usr/bin/env bash
# lock-versions.sh — Regenerate uv.lock and sync the venv.
#
# Usage:
#   bash lock-versions.sh                # lock + sync
#   bash lock-versions.sh --upgrade      # upgrade all deps, then sync

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Ensure venv exists on Python 3.14
if [[ ! -d .venv ]]; then
    uv venv --python 3.14
fi

# Lock (with optional upgrade flag)
if [[ "${1:-}" == "--upgrade" ]]; then
    uv lock --upgrade
else
    uv lock
fi

# Sync runtime + dev deps into the venv
uv sync --extra dev

echo "Done. Run 'bash ci.sh' to verify."
