#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Verifying repository state..."
if [[ ! -f package.json ]]; then echo "ERROR: package.json not found"; exit 1; fi
if [[ ! -f package-lock.json ]]; then
    echo "ERROR: package-lock.json is required for CI"
    echo "Run 'npm install' once, review the lockfile, and commit it."
    exit 1
fi

echo "==> Installing locked dependencies..."
npm ci --no-audit --no-fund

echo "==> Type checking..."
npm run typecheck

echo "==> Linting..."
npm run lint

echo "==> Building production bundle..."
npm run build

echo "==> Verifying build output..."
if [[ ! -s dist/index.html ]]; then echo "ERROR: dist/index.html is missing or empty"; exit 1; fi
if [[ ! -d dist/assets ]]; then echo "ERROR: dist/assets directory not found"; exit 1; fi
if ! find dist/assets -type f -print -quit | grep -q .; then echo "ERROR: dist/assets contains no files"; exit 1; fi

echo "All checks passed."
echo "Build size: $(du -sh dist | cut -f1)"
