#!/usr/bin/env bash

# This script manages and verifies the OpenObserve alerting Terraform/OpenTofu deployment.
# It checks OpenObserve health, authentication, and the externally-owned telemetry streams.
# It does NOT create, modify, or destroy the OpenObserve log or metric streams.
# It initializes and validates OpenTofu before performing deployment or verification.
# Use `bash infra/terraform/run.sh --plan` to create and validate a deployment plan.
# Use `bash infra/terraform/run.sh --apply` to apply the validated plan and verify 12 alerts.
# Use `bash infra/terraform/run.sh --verify` to check OpenObserve, streams, and deployed alerts only.
# Use `bash infra/terraform/run.sh --destroy` to remove Terraform-managed alerting resources only.
# The script expects TF_VAR_o2_endpoint, TF_VAR_o2_email, TF_VAR_o2_password, and TF_VAR_o2_organization.
# Streams remain external infrastructure, so their data and lifecycle stay outside Terraform/OpenTofu management.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TF_BIN="${TF_BIN:-tofu}"
PLAN_FILE="${PLAN_FILE:-${SCRIPT_DIR}/tfplan}"

O2_ENDPOINT="${TF_VAR_o2_endpoint:-${OPENOBSERVE_ENDPOINT:-}}"
O2_EMAIL="${TF_VAR_o2_email:-${OPENOBSERVE_USERNAME:-}}"
O2_PASSWORD="${TF_VAR_o2_password:-${OPENOBSERVE_PASSWORD:-}}"
O2_ORG="${TF_VAR_o2_organization:-${OPENOBSERVE_ORG_ID:-default}}"

EXPECTED_ALERTS="${EXPECTED_ALERTS:-12}"
EXPECTED_CUSTOM_ALERTS="${EXPECTED_CUSTOM_ALERTS:-6}"
EXPECTED_PROMQL_ALERTS="${EXPECTED_PROMQL_ALERTS:-4}"
EXPECTED_SQL_ALERTS="${EXPECTED_SQL_ALERTS:-2}"

REQUIRED_LOG_STREAMS=(
  app_logs
  postgres_logs
  valkey_logs
)

REQUIRED_METRIC_STREAMS=(
  k8s_pod_cpu_limit_utilization
  k8s_pod_memory_limit_utilization
)

die() {
  echo "  [FAIL] $*" >&2
  exit 1
}

ok() {
  echo "  [OK] $*" >&2
}

info() {
  echo "==> $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  bash run.sh --plan
  bash run.sh --apply
  bash run.sh --verify
  bash run.sh --destroy
EOF
}

require_commands() {
  command -v "${TF_BIN}" >/dev/null 2>&1 || die "${TF_BIN} not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
}

check_config() {
  [[ -n "${O2_ENDPOINT}" ]] || die "TF_VAR_o2_endpoint is not set"
  [[ -n "${O2_EMAIL}" ]] || die "TF_VAR_o2_email is not set"
  [[ -n "${O2_PASSWORD}" ]] || die "TF_VAR_o2_password is not set"
  [[ -n "${O2_ORG}" ]] || die "TF_VAR_o2_organization is not set"

  [[ "${EXPECTED_ALERTS}" =~ ^[0-9]+$ ]] ||
    die "EXPECTED_ALERTS must be an integer"

  [[ "${EXPECTED_CUSTOM_ALERTS}" =~ ^[0-9]+$ ]] ||
    die "EXPECTED_CUSTOM_ALERTS must be an integer"

  [[ "${EXPECTED_PROMQL_ALERTS}" =~ ^[0-9]+$ ]] ||
    die "EXPECTED_PROMQL_ALERTS must be an integer"

  [[ "${EXPECTED_SQL_ALERTS}" =~ ^[0-9]+$ ]] ||
    die "EXPECTED_SQL_ALERTS must be an integer"

  (( EXPECTED_CUSTOM_ALERTS + EXPECTED_PROMQL_ALERTS + EXPECTED_SQL_ALERTS == EXPECTED_ALERTS )) ||
    die "Alert counts do not add up"
}

o2_get() {
  curl -fsS \
    --connect-timeout 10 \
    --max-time 30 \
    -u "${O2_EMAIL}:${O2_PASSWORD}" \
    "$@"
}

check_health() {
  info "Checking OpenObserve health"

  curl -fsS \
    --connect-timeout 10 \
    --max-time 15 \
    "${O2_ENDPOINT%/}/healthz" \
    >/dev/null ||
    die "OpenObserve health check failed"

  ok "OpenObserve is healthy"
}

check_auth() {
  info "Checking OpenObserve authentication"

  local response

  response="$(
    o2_get \
      "${O2_ENDPOINT%/}/api/${O2_ORG}/streams?fetchSchema=false&type=logs"
  )" || die "OpenObserve authentication failed"

  jq -e '
    type == "object"
    and (.list | type == "array")
  ' <<<"${response}" >/dev/null ||
    die "Unexpected OpenObserve stream-list response"

  ok "Authenticated against organization '${O2_ORG}'"
}

get_stream_schema() {
  local stream="$1"
  local type="$2"

  o2_get \
    "${O2_ENDPOINT%/}/api/${O2_ORG}/streams/${stream}/schema?type=${type}"
}

check_stream() {
  local stream="$1"
  local type="$2"
  local response
  local doc_num

  info "Checking ${type}/${stream}"

  response="$(
    get_stream_schema "${stream}" "${type}"
  )" || die "Unable to read schema for ${type}/${stream}"

  jq -e \
    --arg expected_name "${stream}" \
    --arg expected_type "${type}" \
    '
      type == "object"
      and .name == $expected_name
      and .stream_type == $expected_type
      and (.stats | type == "object")
      and (.stats.doc_num | type == "number")
      and (.schema | type == "array")
      and all(
        .schema[]?;
        (.name | type == "string")
        and (.type | type == "string")
      )
    ' \
    <<<"${response}" >/dev/null ||
    die "Invalid schema response for ${type}/${stream}"

  doc_num="$(
    jq -r '.stats.doc_num' <<<"${response}"
  )"

  ok "${type}/${stream}: ${doc_num} records"
}

check_external_streams() {
  info "Verifying externally-owned OpenObserve streams"

  local stream

  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    check_stream "${stream}" logs
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    check_stream "${stream}" metrics
  done

  ok "All required external streams verified"
}

tf_init() {
  info "Initializing ${TF_BIN}"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    init \
    -input=false

  ok "${TF_BIN} initialized"
}

tf_validate() {
  info "Validating Terraform/OpenTofu configuration"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    validate

  ok "Configuration is valid"
}

tf_plan() {
  info "Creating Terraform/OpenTofu plan"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    plan \
    -input=false \
    -out="${PLAN_FILE}"

  ok "Plan created: ${PLAN_FILE}"
}

validate_plan() {
  info "Validating saved plan"

  local plan_json
  local stream_count

  plan_json="$(
    "${TF_BIN}" \
      -chdir="${SCRIPT_DIR}" \
      show \
      -json \
      "${PLAN_FILE}"
  )" || die "Unable to read saved plan"

  jq -e '
    type == "object"
    and (.resource_changes | type == "array")
  ' <<<"${plan_json}" >/dev/null ||
    die "OpenTofu produced an invalid plan JSON document"

  stream_count="$(
    jq -r '
      [
        .resource_changes[]?
        | select(.type == "openobserve_stream")
      ]
      | length
    ' <<<"${plan_json}"
  )"

  (( stream_count == 0 )) ||
    die "Plan contains Terraform-managed OpenObserve stream resources"

  ok "Saved plan is valid and does not manage OpenObserve streams"
}

tf_apply() {
  info "Applying saved plan"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    apply \
    -input=false \
    "${PLAN_FILE}"

  ok "Apply complete"
}

verify_state() {
  info "Verifying deployed alerts"

  local state_json
  local alert_count

  state_json="$(
    "${TF_BIN}" \
      -chdir="${SCRIPT_DIR}" \
      show \
      -json
  )" || die "Unable to read Terraform/OpenTofu state"

  alert_count="$(
    jq -r '
      [
        .values.root_module.resources[]?
        | select(.type == "openobserve_alert")
      ]
      | length
    ' <<<"${state_json}"
  )"

  (( alert_count == EXPECTED_ALERTS )) ||
    die "Expected ${EXPECTED_ALERTS} deployed alerts, found ${alert_count}"

  ok "${alert_count} deployed alerts verified"
}

plan_mode() {
  check_config
  require_commands
  check_health
  check_auth
  check_external_streams
  tf_init
  tf_validate
  tf_plan
  validate_plan
}

apply_mode() {
  plan_mode
  tf_apply
  verify_state
  check_external_streams
}

verify_mode() {
  check_config
  require_commands
  check_health
  check_auth
  check_external_streams
  tf_init
  tf_validate
  verify_state
}

destroy_mode() {
  check_config
  require_commands
  tf_init
  tf_validate

  echo "This destroys Terraform/OpenTofu-managed resources only." >&2
  echo "Externally-owned OpenObserve streams are not destroyed." >&2

  read -r -p "Type 'yes' to continue: " answer

  [[ "${answer}" == "yes" ]] ||
    die "Destroy cancelled"

  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    destroy \
    -input=false \
    -auto-approve

  ok "Destroy complete"
}

case "${1:-}" in
  --plan)
    plan_mode
    ;;

  --apply)
    apply_mode
    ;;

  --verify)
    verify_mode
    ;;

  --destroy)
    destroy_mode
    ;;

  -h|--help)
    usage
    ;;

  *)
    usage
    exit 2
    ;;
esac
