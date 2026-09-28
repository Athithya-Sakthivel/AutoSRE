#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v node >/dev/null 2>&1 || {
  echo "ERROR: node is required" >&2
  exit 1
}

command -v npm >/dev/null 2>&1 || {
  echo "ERROR: npm is required" >&2
  exit 1
}

[[ -f package.json ]] || {
  echo "ERROR: package.json not found" >&2
  exit 1
}

rm -rf node_modules package-lock.json

npm install

echo "✓ Dependencies locked"
