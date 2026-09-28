#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -d node_modules ]] || {
  echo "ERROR: node_modules is missing. Run agents/ui/lock-versions.sh first." >&2
  exit 1
}

echo "==> Formatting..."
npm run format

echo "==> Type checking..."
npm run typecheck

echo "==> Linting..."
npm run lint

echo "==> Building..."
npm run build

echo "==> Running pre-commit ESLint..."
cd "$REPO_ROOT"
pre-commit run eslint-agents-ui --all-files

echo "==> Running pre-commit Prettier..."
pre-commit run prettier-agents-ui --all-files

echo "✓ All checks passed"
