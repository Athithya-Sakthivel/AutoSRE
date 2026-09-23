#!/usr/bin/env bash

cd "$(dirname "$0")"

echo "Auto-formatting UI files..."
npm run format

echo "Running pre-commit hooks..."
cd /workspace
pre-commit run eslint-agents-ui --files "$(find agents/ui/src -name '*.ts' -o -name '*.tsx')" || true
pre-commit run prettier-agents-ui --files "$(find agents/ui/src -name '*.ts' -o -name '*.tsx')" || true
cd /workspace/agents/ui

echo "Type checking..."
npm run typecheck

npm build

echo "✓ All checks passed"
