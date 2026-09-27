#!/usr/bin/env bash
# =============================================================================
# AutoSRE — OpenObserve alerting lifecycle
# =============================================================================
#
# Ownership model
# ----------------
# OpenObserve deployment + required streams:
#
#   scripts/staging/openobserve.sh deploy
#
# Terraform/OpenTofu:
#
#   - alert folders
#   - alert template
#   - webhook destination
#   - 12 alert rules
#
# This script NEVER expects streams in Terraform state.
#
# One-shot staging sequence:
#
#   bash scripts/staging/openobserve.sh deploy
#   bash infra/terraform/run.sh --apply
#
# --apply:
#   1. verifies OpenObserve
#   2. verifies required streams through the OpenObserve API
#   3. initializes Terraform/OpenTofu
#   4. validates Terraform
#   5. applies alerting resources
#   6. verifies 12 alert resources in Terraform state
#   7. verifies required streams through the OpenObserve API
#
# --verify:
#   Performs the same external OpenObserve + Terraform checks without apply.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Terraform/OpenTofu binary
# -----------------------------------------------------------------------------

if [[ -z "${TF_BIN:-}" ]]; then
  if command -v tofu >/dev/null 2>&1; then
    TF_BIN="tofu"
  elif command -v terraform >/dev/null 2>&1; then
    TF_BIN="terraform"
  else
    echo "FATAL: neither tofu nor terraform is installed or on PATH" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Expected resources
# -----------------------------------------------------------------------------

EXPECTED_ALERTS=12

REQUIRED_LOG_STREAMS=(
  "app_logs"
  "postgres_logs"
  "valkey_logs"
)

REQUIRED_METRIC_STREAMS=(
  "app_metrics"
)

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log() {
  printf '\033[0;34m==>\033[0m %s\n' "$*" >&2
}

pass() {
  printf '\033[0;32m  [OK]\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[0;33m  [WARN]\033[0m %s\n' "$*" >&2
}

fail() {
  printf '\033[0;31m  [FAIL]\033[0m %s\n' "$*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------

require_env() {
  local name="$1"

  [[ -n "${!name:-}" ]] \
    || fail "${name} is required. Start the staging environment or export it."
}

require_runtime() {
  command -v curl >/dev/null 2>&1 \
    || fail "curl is required"

  command -v jq >/dev/null 2>&1 \
    || fail "jq is required"

  command -v "${TF_BIN}" >/dev/null 2>&1 \
    || fail "${TF_BIN} is required"
}

# -----------------------------------------------------------------------------
# OpenObserve HTTP
# -----------------------------------------------------------------------------

http_status() {
  curl \
    -sS \
    -o /dev/null \
    -w '%{http_code}' \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    "$1" \
    2>/dev/null || printf '000'
}

o2_get_json() {
  curl \
    -sS \
    --fail-with-body \
    --connect-timeout 5 \
    --max-time 20 \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    "$1"
}

# -----------------------------------------------------------------------------
# OpenObserve availability/auth
# -----------------------------------------------------------------------------

check_o2_reachable() {
  log "Checking OpenObserve at ${TF_VAR_o2_endpoint}"

  local elapsed=0
  local code

  while (( elapsed < 30 )); do
    code="$(http_status "${TF_VAR_o2_endpoint}/healthz")"

    if [[ "${code}" == "200" ]]; then
      pass "/healthz → 200"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  fail "/healthz did not return 200 within 30 seconds"
}

check_o2_auth() {
  local org="${TF_VAR_o2_organization:-default}"
  local code

  log "Verifying OpenObserve authentication"

  code="$(
    http_status \
      "${TF_VAR_o2_endpoint}/api/${org}/streams?fetchSchema=false&type=logs"
  )"

  case "${code}" in
    200)
      pass "Authenticated against org '${org}'"
      ;;

    401|403)
      fail "OpenObserve rejected credentials (HTTP ${code})"
      ;;

    000)
      fail "Could not reach OpenObserve stream API"
      ;;

    *)
      fail "Unexpected HTTP ${code} from OpenObserve stream API"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Stream verification
# -----------------------------------------------------------------------------
#
# Streams are deliberately NOT checked in Terraform state.
#
# Bash/Helm owns them:
#
#   scripts/staging/openobserve.sh deploy
#
# OpenObserve itself is the authority.
#
# API:
#   GET /api/{organization}/streams?fetchSchema=false&type=logs
#   GET /api/{organization}/streams?fetchSchema=false&type=metrics
# -----------------------------------------------------------------------------

get_stream_names() {
  local type="$1"
  local org="${TF_VAR_o2_organization:-default}"

  o2_get_json \
    "${TF_VAR_o2_endpoint}/api/${org}/streams?fetchSchema=false&type=${type}" \
    | jq -r '.list[]?.name'
}

verify_stream() {
  local stream="$1"
  local type="$2"
  local names

  names="$(get_stream_names "${type}")"

  if grep -Fxq "${stream}" <<<"${names}"; then
    pass "stream ${stream} (${type})"
    return 0
  fi

  fail "required stream missing: ${stream} (${type})"
}

verify_streams() {
  log "Verifying OpenObserve streams"

  local stream

  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    verify_stream "${stream}" "logs"
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    verify_stream "${stream}" "metrics"
  done

  pass "Required streams: 4/4"
}

# -----------------------------------------------------------------------------
# Terraform/OpenTofu
# -----------------------------------------------------------------------------

tf_init() {
  log "Initializing ${TF_BIN}"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    init \
    -input=false \
    -upgrade >/dev/null

  pass "${TF_BIN} initialization complete"
}

tf_validate() {
  log "Validating Terraform configuration"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    validate

  pass "Terraform configuration valid"
}

# -----------------------------------------------------------------------------
# Terraform state verification
# -----------------------------------------------------------------------------

alert_state_count() {
  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    state list 2>/dev/null \
    | grep -c '^openobserve_alert\.incidents\[' \
    || true
}

verify_alerts() {
  log "Verifying Terraform alert state"

  local count

  count="$(alert_state_count)"

  if [[ "${count}" != "${EXPECTED_ALERTS}" ]]; then
    fail "Expected ${EXPECTED_ALERTS} alerts in Terraform state; found ${count}"
  fi

  pass "Alerts in state: ${count}/${EXPECTED_ALERTS}"

  if "${TF_BIN}" \
      -chdir="${SCRIPT_DIR}" \
      output -json alert_ids >/dev/null 2>&1; then

    log "Alert IDs:"

    "${TF_BIN}" \
      -chdir="${SCRIPT_DIR}" \
      output -json alert_ids \
      | jq -r \
        'to_entries[] | "  \(.key): \(.value)"'
  fi
}

# -----------------------------------------------------------------------------
# Full verification
# -----------------------------------------------------------------------------

do_verify() {
  require_env TF_VAR_o2_endpoint
  require_env TF_VAR_o2_email
  require_env TF_VAR_o2_password

  require_runtime

  check_o2_reachable
  check_o2_auth

  # Streams are externally managed by openobserve.sh.
  verify_streams

  tf_init
  tf_validate

  verify_alerts

  pass "OpenObserve deployment, streams, and Terraform alerts verified"
}

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------

tf_plan() {
  require_env TF_VAR_o2_endpoint
  require_env TF_VAR_o2_email
  require_env TF_VAR_o2_password

  require_runtime

  check_o2_reachable
  check_o2_auth
  verify_streams

  tf_init
  tf_validate

  log "Planning Terraform alert configuration"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    plan \
    -input=false \
    -out=tfplan

  pass "Plan saved to ${SCRIPT_DIR}/tfplan"
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------

tf_apply() {
  require_env TF_VAR_o2_endpoint
  require_env TF_VAR_o2_email
  require_env TF_VAR_o2_password

  require_runtime

  check_o2_reachable
  check_o2_auth

  # The Bash deployment script is responsible for creating streams.
  # Confirm they exist before Terraform attempts alert creation.
  verify_streams

  tf_init
  tf_validate

  log "Applying Terraform/OpenTofu alert configuration"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    apply \
    -input=false \
    -auto-approve

  echo

  # The apply above succeeded in your latest run. Verify the final state
  # without expecting Bash-managed streams to exist in Terraform state.
  verify_alerts
  verify_streams

  pass "OpenObserve alerting reconciled successfully"
}

# -----------------------------------------------------------------------------
# Destroy
# -----------------------------------------------------------------------------

tf_destroy() {
  require_env TF_VAR_o2_endpoint
  require_env TF_VAR_o2_email
  require_env TF_VAR_o2_password

  require_runtime

  check_o2_reachable
  check_o2_auth

  tf_init
  tf_validate

  warn "This destroys Terraform-managed alerting resources."
  warn "It does NOT destroy the four OpenObserve streams."
  warn "Stream lifecycle belongs to scripts/staging/openobserve.sh."

  warn "Ctrl+C within 5 seconds to abort."
  sleep 5

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    destroy \
    -input=false \
    -auto-approve

  pass "Terraform destroy complete"
}

# -----------------------------------------------------------------------------
# List
# -----------------------------------------------------------------------------

do_list() {
  require_runtime

  tf_init

  echo
  echo "=== Terraform-managed alerts ==="

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    state list 2>/dev/null \
    | grep '^openobserve_alert\.incidents\[' \
    | sort || true

  echo
  echo "=== OpenObserve streams ==="

  local stream

  echo "logs:"
  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    echo "  ${stream}"
  done

  echo "metrics:"
  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    echo "  ${stream}"
  done
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  bash run.sh --plan
  bash run.sh --apply
  bash run.sh --verify
  bash run.sh --destroy
  bash run.sh --list

Ownership:
  scripts/staging/openobserve.sh
      - OpenObserve deployment
      - OpenObserve configuration
      - required streams

  infra/terraform/run.sh
      - alert folders
      - alert template
      - webhook destination
      - 12 alert rules

Modes:
  --plan
      Verify O2 + streams, then plan Terraform changes.

  --apply
      Verify O2 + streams, apply Terraform alerts, then verify.

  --verify
      Verify O2 + streams + 12 Terraform alerts.

  --destroy
      Destroy Terraform-managed alerting resources only.

  --list
      List Terraform alerts and required streams.

Required environment:
  TF_VAR_o2_endpoint
  TF_VAR_o2_email
  TF_VAR_o2_password

Optional:
  TF_VAR_o2_organization
      default: default

  TF_BIN
      default: tofu if available, otherwise terraform
EOF
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------

main() {
  case "${1:-}" in
    --plan)
      tf_plan
      ;;

    --apply)
      tf_apply
      ;;

    --verify)
      do_verify
      ;;

    --destroy)
      tf_destroy
      ;;

    --list)
      do_list
      ;;

    -h|--help)
      usage
      ;;

    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
