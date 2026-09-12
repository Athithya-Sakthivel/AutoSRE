#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
status.sh — Show current state of OpenObserve deployment

Usage: $(basename "$0") [--help]

Environment:
  O2_NAMESPACE   Default: openobserve
  O2_RELEASE     Default: openobserve
EOF
}

action_status() {
  echo
  echo "=== Namespace ==="
  "${KUBECTL}" get namespace "${O2_NAMESPACE}" 2>/dev/null || echo "not found"
  echo
  echo "=== Helm releases ==="
  "${HELM}" list -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Pods ==="
  "${KUBECTL}" get pods -n "${O2_NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Deployments ==="
  "${KUBECTL}" get deployments -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== PVCs ==="
  "${KUBECTL}" get pvc -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Services ==="
  "${KUBECTL}" get svc -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Secrets ==="
  "${KUBECTL}" get secrets -n "${O2_NAMESPACE}" 2>/dev/null || true
}

main() {
  for arg in "$@"; do
    case "${arg}" in
      --help|-h) usage; exit 0 ;;
    esac
  done
  require_cmd "${KUBECTL}"
  require_cmd "${HELM}"
  action_status
}

main "$@"
