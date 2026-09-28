#!/usr/bin/env bash
# lock-versions.sh — Regenerate uv.lock and sync the venv.
#
# Usage:
#   bash agents/lock-versions.sh
#   bash agents/lock-versions.sh --upgrade

set -Eeuo pipefail

# Always run from the directory containing this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UV_VERSION="0.12.18"
export UV_LINK_MODE=copy

# Ensure pyproject.toml exists
[[ -f pyproject.toml ]] || {
  echo "ERROR: pyproject.toml not found in $SCRIPT_DIR" >&2
  exit 1
}

# Install pinned uv if missing or wrong version
if ! command -v uv >/dev/null 2>&1 \
  || [[ "$(uv --version | awk '{print $2}')" != "$UV_VERSION" ]]; then
  echo "Installing uv $UV_VERSION..."
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

# Create the virtual environment if needed
if [[ ! -d .venv ]]; then
  echo "Creating Python 3.14 virtual environment..."
  uv venv --python 3.14
fi

# Regenerate lockfile
if [[ "${1:-}" == "--upgrade" ]]; then
  echo "Upgrading dependencies..."
  uv lock --upgrade
else
  echo "Regenerating lockfile..."
  uv lock
fi

# Sync runtime + development dependencies
echo "Syncing environment..."
uv sync --extra dev

echo "✓ Dependencies locked and virtual environment synced"
echo "Activate with: source $SCRIPT_DIR/.venv/bin/activate"
