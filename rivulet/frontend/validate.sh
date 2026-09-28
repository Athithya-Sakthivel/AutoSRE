#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

cd "$SCRIPT_DIR"

[[ -d node_modules ]] || {
  echo "ERROR: node_modules is missing. Run rivulet/frontend/lock_versions.sh first." >&2
  exit 1
}

echo "==> Type checking..."
npm run typecheck

echo "==> Linting..."
npm run lint

echo "==> Building..."
npm run build

[[ -s dist/index.html ]] || {
  echo "ERROR: dist/index.html is missing or empty" >&2
  exit 1
}

[[ -d dist/assets ]] || {
  echo "ERROR: dist/assets directory is missing" >&2
  exit 1
}

echo "==> Running pre-commit ESLint..."
cd "$REPO_ROOT"
pre-commit run eslint-frontend --all-files

echo "✓ All checks passed"
echo "Build size: $(du -sh "$SCRIPT_DIR/dist" | cut -f1)"
