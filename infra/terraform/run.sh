#!/usr/bin/env bash
# ==============================================================================
# AutoSRE — OpenObserve alerting lifecycle (Terraform/OpenTofu)
#
# Ownership
# ---------
# scripts/staging/openobserve.sh
#   - OpenObserve deployment/configuration
#   - required telemetry streams
#
# OTel Helm charts
#   - telemetry ingestion/routing/normalization
#
# Terraform/OpenTofu
#   - folders
#   - alert templates/destinations
#   - 12 alert rules
#
# Critical safeguards
# -------------------
# * Verify OpenObserve health/authentication.
# * Verify required streams contain real records and required fields.
# * Extract the EXACT SQL from the Terraform plan and run each SQL through the
#   OpenObserve Search API BEFORE apply.
# * Apply the validated plan file, not a second unvalidated implicit plan.
# * After apply, read Terraform state and re-run every alert SQL smoke test.
# * Streams are never imported into Terraform state.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="${TF_PLAN_FILE:-${SCRIPT_DIR}/tfplan}"

EXPECTED_ALERTS="${EXPECTED_ALERTS:-12}"
TF_UPGRADE_PROVIDERS="${TF_UPGRADE_PROVIDERS:-false}"
O2_VERIFY_TIMEOUT="${O2_VERIFY_TIMEOUT:-120}"
O2_VERIFY_INTERVAL="${O2_VERIFY_INTERVAL:-5}"
O2_QUERY_TIMEOUT="${O2_QUERY_TIMEOUT:-30}"
O2_QUERY_LOOKBACK_MINUTES="${O2_QUERY_LOOKBACK_MINUTES:-15}"

REQUIRED_LOG_STREAMS=(app_logs postgres_logs valkey_logs)
REQUIRED_METRIC_STREAMS=(app_metrics)

cleanup() {
  rm -f \
    "${SCRIPT_DIR}/.o2-auth-check.json" \
    "${SCRIPT_DIR}/.o2-search-body.json" \
    "${SCRIPT_DIR}/.o2-search-response.json" \
    "${SCRIPT_DIR}/.o2-search-last-error.json" \
    "${SCRIPT_DIR}/.plan-alerts.tsv" \
    "${SCRIPT_DIR}/.state-alerts.tsv"
}
trap cleanup EXIT

# Keep synchronized with the alert contract. This catches the failure even if
# Terraform has not yet created the alert resources.
declare -A REQUIRED_FIELDS=(
  [app_logs]="level message service upstream"
  [postgres_logs]="state service"
  [valkey_logs]="message"
)

# ------------------------------------------------------------------------------
# Terraform/OpenTofu binary
# ------------------------------------------------------------------------------

if [[ -z "${TF_BIN:-}" ]]; then
  if command -v tofu >/dev/null 2>&1; then
    TF_BIN="tofu"
  elif command -v terraform >/dev/null 2>&1; then
    TF_BIN="terraform"
  else
    echo "FATAL: neither tofu nor terraform is installed" >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[0;32m  [OK]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m  [WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[0;31m  [FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "${name} is required"
}

require_runtime() {
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v date >/dev/null 2>&1 || fail "date is required"
  command -v grep >/dev/null 2>&1 || fail "grep is required"
  command -v sed >/dev/null 2>&1 || fail "sed is required"
  command -v "${TF_BIN}" >/dev/null 2>&1 || fail "${TF_BIN} is required"
}

require_inputs() {
  require_env TF_VAR_o2_endpoint
  require_env TF_VAR_o2_email
  require_env TF_VAR_o2_password
}

# ------------------------------------------------------------------------------
# OpenObserve HTTP
# ------------------------------------------------------------------------------

O2_ORG="${TF_VAR_o2_organization:-default}"

http_request() {
  local method="$1"
  local url="$2"
  local output="$3"
  shift 3

  curl -sS \
    --retry 2 \
    --connect-timeout 5 \
    --max-time "${O2_QUERY_TIMEOUT}" \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    -X "${method}" \
    -o "${output}" \
    -w '%{http_code}' \
    "$@"
}

o2_get_json() {
  curl -sS \
    --fail-with-body \
    --retry 2 \
    --connect-timeout 5 \
    --max-time "${O2_QUERY_TIMEOUT}" \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    "$@"
}

check_o2_reachable() {
  log "Checking OpenObserve health: ${TF_VAR_o2_endpoint}"

  local elapsed=0 code
  while (( elapsed <= O2_VERIFY_TIMEOUT )); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 --max-time 10 \
      "${TF_VAR_o2_endpoint}/healthz" 2>/dev/null || true)"

    if [[ "${code}" == "200" ]]; then
      pass "/healthz -> 200"
      return 0
    fi

    sleep "${O2_VERIFY_INTERVAL}"
    elapsed=$((elapsed + O2_VERIFY_INTERVAL))
  done

  fail "OpenObserve /healthz did not return 200 within ${O2_VERIFY_TIMEOUT}s"
}

check_o2_auth() {
  log "Verifying OpenObserve authentication (org=${O2_ORG})"

  local body="${SCRIPT_DIR}/.o2-auth-check.json"
  local code

  code="$(curl -sS -o "${body}" -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    "${TF_VAR_o2_endpoint}/api/${O2_ORG}/streams?fetchSchema=false&type=logs" \
    2>/dev/null || true)"

  case "${code}" in
    200) pass "Authenticated against '${O2_ORG}'" ;;
    401|403) fail "OpenObserve rejected credentials (HTTP ${code})" ;;
    000) fail "OpenObserve stream API is unreachable" ;;
    *)
      if [[ -s "${body}" ]]; then
        sed 's/^/  /' "${body}" >&2 || true
      fi
      rm -f "${body}"
      fail "Unexpected HTTP ${code} from OpenObserve stream API"
      ;;
  esac

  rm -f "${body}"
}


# ------------------------------------------------------------------------------
# Stream contract
# ------------------------------------------------------------------------------

stream_schema_json() {
  local stream="$1" type="$2"
  o2_get_json \
    "${TF_VAR_o2_endpoint}/api/${O2_ORG}/streams/${stream}/schema?type=${type}"
}

verify_stream_exists() {
  local stream="$1" type="$2"
  stream_schema_json "${stream}" "${type}" >/dev/null \
    || fail "Required stream missing/unreadable: ${stream} (${type})"
}

verify_stream_data_and_schema() {
  local stream="$1" type="$2"
  local json doc_num field

  json="$(stream_schema_json "${stream}" "${type}")" \
    || fail "Cannot retrieve schema for ${stream} (${type})"

  doc_num="$(jq -r '.stats.doc_num // 0' <<<"${json}")"
  [[ "${doc_num}" =~ ^[0-9]+$ ]] || fail "Invalid doc_num for ${stream}: ${doc_num}"
  (( doc_num > 0 )) || fail "Stream ${stream} contains 0 records"

  if [[ "${type}" == "logs" && -n "${REQUIRED_FIELDS[${stream}]:-}" ]]; then
    for field in ${REQUIRED_FIELDS[${stream}]}; do
      jq -e --arg field "${field}" \
        '.schema // [] | any(.[]; .name == $field)' \
        <<<"${json}" >/dev/null \
        || fail "Stream ${stream} missing required field '${field}'. Schema=$(jq -c '.schema // []' <<<"${json}")"
    done
  fi

  pass "stream ${stream} (${type}): records=${doc_num}, schema contract OK"
}

verify_streams() {
  log "Verifying OpenObserve streams, data, and schemas"

  local stream
  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    verify_stream_exists "${stream}" "logs"
    verify_stream_data_and_schema "${stream}" "logs"
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    verify_stream_exists "${stream}" "metrics"
    verify_stream_data_and_schema "${stream}" "metrics"
  done

  pass "Required streams and schemas verified"
}

# ------------------------------------------------------------------------------
# Search smoke tests
# ------------------------------------------------------------------------------

now_us() {
  printf '%s000000' "$(date +%s)"
}

run_o2_sql() {
  local stream="$1"
  local sql="$2"
  local start_time end_time body_file response_file http_code body

  end_time="$(now_us)"
  start_time="$((end_time - O2_QUERY_LOOKBACK_MINUTES * 60 * 1000000))"

  body="$(jq -n \
    --arg sql "${sql}" \
    --argjson start "${start_time}" \
    --argjson end "${end_time}" \
    '{query:{sql:$sql,start_time:$start,end_time:$end,from:0,size:0},search_type:"ui",timeout:0}')"

  body_file="${SCRIPT_DIR}/.o2-search-body.json"
  response_file="${SCRIPT_DIR}/.o2-search-response.json"
  printf '%s' "${body}" >"${body_file}"

  http_code="$(curl -sS \
    --connect-timeout 5 \
    --max-time "${O2_QUERY_TIMEOUT}" \
    -u "${TF_VAR_o2_email}:${TF_VAR_o2_password}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -o "${response_file}" \
    -w '%{http_code}' \
    "${TF_VAR_o2_endpoint}/api/${O2_ORG}/_search" \
    --data-binary @"${body_file}" \
    2>/dev/null || true)"

  case "${http_code}" in
    2*)
      body="$(cat "${response_file}")"
      # Fail even if the HTTP transport succeeded but the API returned its own
      # structured SearchFieldNotFound error.
      if jq -e '.code? == 20004 or (.message? // "" | contains("Search field not found"))' \
        <<<"${body}" >/dev/null 2>&1; then
        rm -f "${body_file}" "${response_file}"
        return 2
      fi
      ;;
    400|401|403|404|422|429|500|502|503|504)
      body="$(cat "${response_file}" 2>/dev/null || true)"
      printf '%s' "${body}" >"${SCRIPT_DIR}/.o2-search-last-error.json"
      rm -f "${body_file}" "${response_file}"
      return 1
      ;;
    *)
      rm -f "${body_file}" "${response_file}"
      return 1
      ;;
  esac

  rm -f "${body_file}" "${response_file}"
  return 0
}

validate_sql() {
  local address="$1"
  local stream="$2"
  local sql="$3"

  [[ -n "${stream}" ]] || fail "${address}: alert has no stream_name"
  [[ -n "${sql}" ]] || fail "${address}: SQL query is empty"

  log "SQL smoke test: ${address} -> ${stream}"

  local rc=0
  run_o2_sql "${stream}" "${sql}" || rc=$?

  if (( rc == 0 )); then
    pass "${address}: SQL accepted by OpenObserve"
    return 0
  fi

  if (( rc == 2 )); then
    fail "${address}: OpenObserve returned SearchFieldNotFound (20004). SQL=${sql}"
  fi

  if [[ -f "${SCRIPT_DIR}/.o2-search-last-error.json" ]]; then
    log "OpenObserve search response:"
    sed 's/^/  /' "${SCRIPT_DIR}/.o2-search-last-error.json" >&2 || true
    rm -f "${SCRIPT_DIR}/.o2-search-last-error.json"
  fi

  fail "${address}: OpenObserve rejected the SQL query"
}


# ------------------------------------------------------------------------------
# Terraform/OpenTofu
# ------------------------------------------------------------------------------

tf_init() {
  log "Initializing ${TF_BIN}"

  local args=(
    -chdir="${SCRIPT_DIR}"
    init
    -input=false
  )

  if [[ "${TF_UPGRADE_PROVIDERS}" == "true" ]]; then
    args+=( -upgrade )
  fi

  "${TF_BIN}" "${args[@]}"
  pass "${TF_BIN} initialization complete"
}

tf_validate() {
  log "Validating Terraform configuration"
  "${TF_BIN}" -chdir="${SCRIPT_DIR}" validate
  pass "Terraform configuration valid"
}

tf_plan() {
  log "Creating Terraform plan: ${PLAN_FILE}"
  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    plan \
    -input=false \
    -out="${PLAN_FILE}"
  pass "Plan created"
}

tf_show_plan_json() {
  "${TF_BIN}" \
    -chdir="${SCRIPT_DIR}" \
    show \
    -json \
    "${PLAN_FILE}"
}

# Extract only SQL alerts from the exact saved plan.
extract_plan_alerts() {
  tf_show_plan_json | jq -r '
    .resource_changes[]?
    | select(.type == "openobserve_alert")
    | select(.change.after != null)
    | .address as $address
    | .change.after as $after
    | ($after.stream_name // "") as $stream
    | [($after.query_condition[]? // empty)
        | select((.type // "") == "sql")
        | (.sql // "")
      ] as $sqls
    | $sqls[]?
    | [$address, $stream, .]
    | @tsv
  '
}

validate_plan_alerts() {
  log "Validating EXACT SQL queries from Terraform plan against OpenObserve"

  local count=0 address stream sql
  local plan_alerts="${SCRIPT_DIR}/.plan-alerts.tsv"
  extract_plan_alerts >"${plan_alerts}"

  while IFS=$'\t' read -r address stream sql; do
    [[ -n "${address}" ]] || continue
    count=$((count + 1))
    validate_sql "${address}" "${stream}" "${sql}"
  done <"${plan_alerts}"

  rm -f "${plan_alerts}"

  (( count == EXPECTED_ALERTS )) \
    || fail "Expected ${EXPECTED_ALERTS} SQL alerts in the Terraform plan; found ${count}"

  pass "Validated ${count}/${EXPECTED_ALERTS} planned alert SQL queries"
}

alert_state_count() {
  "${TF_BIN}" -chdir="${SCRIPT_DIR}" state list 2>/dev/null \
    | grep -c '^openobserve_alert\.incidents\[' || true
}

verify_alerts_in_state() {
  log "Verifying Terraform alert state"

  local count
  count="$(alert_state_count)"

  [[ "${count}" == "${EXPECTED_ALERTS}" ]] \
    || fail "Expected ${EXPECTED_ALERTS} alerts in Terraform state; found ${count}"

  pass "Alerts in Terraform state: ${count}/${EXPECTED_ALERTS}"

  if "${TF_BIN}" -chdir="${SCRIPT_DIR}" output -json alert_ids >/dev/null 2>&1; then
    log "Alert IDs:"
    "${TF_BIN}" -chdir="${SCRIPT_DIR}" output -json alert_ids \
      | jq -r 'to_entries[] | "  \(.key): \(.value)"'
  fi
}

extract_state_alerts() {
  "${TF_BIN}" -chdir="${SCRIPT_DIR}" show -json \
    | jq -r '
      def all_resources:
        (.resources // []) + [((.child_modules // [])[]? | all_resources)[]];

      .values.root_module
      | all_resources[]
      | select(.type? == "openobserve_alert")
      | .address as $address
      | .values as $v
      | ($v.stream_name // "") as $stream
      | [($v.query_condition[]? // empty)
          | select((.type // "") == "sql")
          | (.sql // "")
        ] as $sqls
      | $sqls[]?
      | [$address, $stream, .]
      | @tsv
    '
}


validate_state_alerts() {
  log "Re-validating deployed alert SQL against the live OpenObserve schema"

  local count=0 address stream sql
  local state_alerts="${SCRIPT_DIR}/.state-alerts.tsv"
  extract_state_alerts >"${state_alerts}"

  while IFS=$'\t' read -r address stream sql; do
    [[ -n "${address}" ]] || continue
    count=$((count + 1))
    validate_sql "${address}" "${stream}" "${sql}"
  done <"${state_alerts}"

  rm -f "${state_alerts}"

  (( count == EXPECTED_ALERTS )) \
    || fail "Expected ${EXPECTED_ALERTS} SQL alerts in Terraform state; found ${count}"

  pass "Validated ${count}/${EXPECTED_ALERTS} deployed alert SQL queries"
}

# ------------------------------------------------------------------------------
# Full verification / modes
# ------------------------------------------------------------------------------

preflight_all() {
  require_inputs
  require_runtime
  check_o2_reachable
  check_o2_auth
  verify_streams
  tf_init
  tf_validate
}

do_verify() {
  preflight_all
  verify_alerts_in_state
  validate_state_alerts
  pass "OpenObserve + schemas + Terraform alerts are healthy"
}

tf_plan_mode() {
  preflight_all
  tf_plan
  validate_plan_alerts
  pass "Plan is safe to apply: OpenObserve schemas accept every planned alert SQL query"
}

tf_apply_mode() {
  preflight_all

  # Never apply an unvalidated implicit plan. Produce, validate, then apply the
  # exact same saved plan file.
  tf_plan
  validate_plan_alerts

  log "Applying the already-validated Terraform plan"
  "${TF_BIN}" -chdir="${SCRIPT_DIR}" apply -input=false "${PLAN_FILE}"
  pass "Terraform apply complete"

  verify_alerts_in_state
  validate_state_alerts
  verify_streams
  pass "OpenObserve alerting reconciled and post-apply SQL validation passed"
}

tf_destroy_mode() {
  require_inputs
  require_runtime
  check_o2_reachable
  check_o2_auth
  tf_init
  tf_validate

  warn "This destroys Terraform-managed alert resources only."
  warn "OpenObserve streams and stored telemetry are NOT destroyed."
  warn "Set TF_CONFIRM_DESTROY=yes to confirm non-interactively."

  if [[ "${TF_CONFIRM_DESTROY:-}" != "yes" ]]; then
    read -r -p "Type 'yes' to destroy Terraform alerting resources: " answer
    [[ "${answer}" == "yes" ]] || fail "cancelled"
  fi

  "${TF_BIN}" -chdir="${SCRIPT_DIR}" destroy -input=false -auto-approve
  pass "Terraform destroy complete"
}

do_list() {
  require_runtime
  tf_init

  echo "=== Terraform-managed alerts ==="
  "${TF_BIN}" -chdir="${SCRIPT_DIR}" state list 2>/dev/null \
    | grep '^openobserve_alert\.incidents\[' | sort || true

  echo
  echo "=== External OpenObserve streams ==="
  require_inputs
  check_o2_reachable
  check_o2_auth

  local stream type json
  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    type="logs"
    json="$(stream_schema_json "${stream}" "${type}" 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      echo "logs/${stream}: $(jq -r '.stats.doc_num // 0' <<<"${json}") records"
    else
      echo "logs/${stream}: MISSING"
    fi
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    type="metrics"
    json="$(stream_schema_json "${stream}" "${type}" 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      echo "metrics/${stream}: $(jq -r '.stats.doc_num // 0' <<<"${json}") records"
    else
      echo "metrics/${stream}: MISSING"
    fi
  done
}

# ------------------------------------------------------------------------------
# Usage / dispatch
# ------------------------------------------------------------------------------

usage() {
  cat <<'EOF_USAGE'
Usage:
  bash run.sh --plan
  bash run.sh --apply
  bash run.sh --verify
  bash run.sh --destroy
  bash run.sh --list

Required environment:
  TF_VAR_o2_endpoint
  TF_VAR_o2_email
  TF_VAR_o2_password

Optional:
  TF_VAR_o2_organization        default: default
  TF_BIN                        default: tofu if installed, otherwise terraform
  TF_PLAN_FILE                  default: infra/terraform/tfplan
  TF_UPGRADE_PROVIDERS          default: false
  TF_CONFIRM_DESTROY            default: interactive
  EXPECTED_ALERTS               default: 12
  O2_VERIFY_TIMEOUT              default: 120s
  O2_QUERY_LOOKBACK_MINUTES     default: 15

Behavior:
  --plan
    Verifies live O2 stream/data/schema readiness, creates a saved TF plan,
    extracts the SQL from that exact plan, and executes every SQL query through
    the live OpenObserve Search API. It does NOT apply.

  --apply
    Performs the same checks, creates the plan, validates every planned alert
    SQL query against O2, then applies that exact saved plan. It performs a
    second SQL validation pass after apply.

  --verify
    Verifies live O2 streams/schemas and every SQL alert in Terraform state.

  --destroy
    Destroys Terraform-managed alerting only. O2 data/streams remain.

  --list
    Lists Terraform alerts and live OpenObserve stream record counts.
EOF_USAGE
}

main() {
  case "${1:-}" in
    --plan)    tf_plan_mode ;;
    --apply)   tf_apply_mode ;;
    --verify)  do_verify ;;
    --destroy) tf_destroy_mode ;;
    --list)    do_list ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
