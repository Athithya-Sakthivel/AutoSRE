#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

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
