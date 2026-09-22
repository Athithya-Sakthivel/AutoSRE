#!/usr/bin/env bash
set -euo pipefail

cd /workspace

echo "Auto-formatting UI files..."
npx prettier --write agents/ui

echo "Running pre-commit hooks..."
pre-commit run eslint-agents-ui --all-files
pre-commit run prettier-agents-ui --all-files

cd agents/ui

echo "Type checking..."
npm run typecheck

echo "Building..."
npm run build

echo "✓ Local UI validation passed"
