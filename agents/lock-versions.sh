#!/usr/bin/env bash
# lock-versions.sh — Regenerate uv.lock and sync the venv.
#
# Usage:
#   bash lock-versions.sh                # lock + sync
#   bash lock-versions.sh --upgrade      # upgrade all deps, then sync

#!/usr/bin/env bash
set -euo pipefail

UV_VERSION="0.12.18"
export UV_LINK_MODE=copy

# Install uv only if missing or wrong version
if ! command -v uv >/dev/null || [[ "$(uv --version | awk '{print $2}')" != "$UV_VERSION" ]]; then
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
      | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

# Ensure venv exists on Python 3.14
[[ -d .venv ]] || uv venv --python 3.14

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
