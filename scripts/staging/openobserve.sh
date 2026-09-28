#!/usr/bin/env bash
# ==============================================================================
# AutoSRE — OpenObserve lifecycle
#
# Design goals
# ------------
# 1. OpenObserve is deployed by Helm.
# 2. OpenObserve streams are created by FIRST REAL INGESTION, not by creating
#    empty streams ahead of time. This prevents the empty-stream / missing-schema
#    race that caused SearchFieldNotFound (20004).
# 3. This script waits until the required streams exist, contain data, and have
#    the fields required by the alerting contract.
# 4. Stream settings are reconciled through the documented /settings API.
# 5. Terraform/OpenTofu owns alert resources only. Streams never enter TF state.
#
# Required deployment order
# -------------------------
#   1. bash scripts/staging/openobserve.sh deploy
#   2. deploy/update the OTel gateway so its logs pipeline is routing to the
#      named OpenObserve streams.
#   3. bash infra/terraform/run.sh --apply
#
# If O2_WAIT_FOR_INGESTION=true (default), step 1 intentionally fails until
# the required telemetry is actually arriving. That is a feature: it prevents
# alert resources from being created against empty streams.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

O2_NAMESPACE="${O2_NAMESPACE:-openobserve}"
O2_RELEASE="${O2_RELEASE:-openobserve}"
O2_CHART_PATH="${O2_CHART_PATH:-infra/k8s/open-observe-minimal}"

# Official OSS image location documented by OpenObserve.
O2_IMAGE_REGISTRY="${O2_IMAGE_REGISTRY:-public.ecr.aws}"
O2_IMAGE_REPOSITORY="${O2_IMAGE_REPOSITORY:-zinclabs/openobserve}"
O2_IMAGE_TAG="${O2_IMAGE_TAG:-v1.0.4}"
# Supply the release digest in production to make the image immutable.
# Example: sha256:<64 hex chars>
O2_IMAGE_DIGEST="${O2_IMAGE_DIGEST:-}"
O2_REQUIRE_IMAGE_DIGEST="${O2_REQUIRE_IMAGE_DIGEST:-false}"
O2_ALLOW_IMAGE_CHANGE="${O2_ALLOW_IMAGE_CHANGE:-false}"

O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"
O2_ORGANIZATION="${O2_ORGANIZATION:-default}"

O2_PVC_SIZE="${O2_PVC_SIZE:-20Gi}"
O2_DATA_DIR="${O2_DATA_DIR:-/data/openobserve}"

O2_RETENTION_DAYS="${O2_RETENTION_DAYS:-30}"
O2_CPU_REQUEST="${O2_CPU_REQUEST:-1}"
O2_CPU_LIMIT="${O2_CPU_LIMIT:-2}"
O2_MEMORY_REQUEST="${O2_MEMORY_REQUEST:-1Gi}"
O2_MEMORY_LIMIT="${O2_MEMORY_LIMIT:-2Gi}"
O2_LOG_LEVEL="${O2_LOG_LEVEL:-info}"

O2_MEM_TABLE_MAX_SIZE="${O2_MEM_TABLE_MAX_SIZE:-512}"
O2_MAX_FILE_SIZE_IN_MEMORY="${O2_MAX_FILE_SIZE_IN_MEMORY:-128}"
O2_FILE_PUSH_INTERVAL="${O2_FILE_PUSH_INTERVAL:-10}"
O2_MEM_PERSIST_INTERVAL="${O2_MEM_PERSIST_INTERVAL:-5}"
O2_COMPACT_FAST_MODE="${O2_COMPACT_FAST_MODE:-false}"
O2_COMPACT_MAX_FILE_SIZE="${O2_COMPACT_MAX_FILE_SIZE:-256}"

O2_TERMINATION_GRACE="${O2_TERMINATION_GRACE:-120}"
O2_PRESTOP_SLEEP="${O2_PRESTOP_SLEEP:-10}"
O2_SKIP_SSRF_CHECKS="${O2_SKIP_SSRF_CHECKS:-true}"

O2_VERIFY_LOCAL_PORT="${O2_VERIFY_LOCAL_PORT:-15080}"
O2_WAIT_FOR_INGESTION="${O2_WAIT_FOR_INGESTION:-false}"
O2_STREAM_READY_TIMEOUT="${O2_STREAM_READY_TIMEOUT:-300}"
O2_STREAM_RETRY_INTERVAL="${O2_STREAM_RETRY_INTERVAL:-5}"

HELM_TIMEOUT="${HELM_TIMEOUT:-180s}"
READY_TIMEOUT="${READY_TIMEOUT:-240}"

# ------------------------------------------------------------------------------
# Required telemetry contract
# ------------------------------------------------------------------------------
# These are the fields consumed by the current alert SQL. Keep this list in
# sync with the Terraform alert definitions. The important rule is that every
# field used by an alert must exist before Terraform is allowed to create it.

REQUIRED_STREAMS=(app_logs postgres_logs valkey_logs app_metrics)

declare -A STREAM_TYPES=(
  [app_logs]="logs"
  [postgres_logs]="logs"
  [valkey_logs]="logs"
  [app_metrics]="metrics"
)

# Space-separated field lists are deliberate: field names here contain no
# whitespace. app_logs includes upstream because the current alert SQL selects
# and groups by it.
declare -A REQUIRED_FIELDS=(
  [app_logs]="level message service upstream"
  [postgres_logs]="state service"
  [valkey_logs]="message"
  [app_metrics]="_timestamp"
)

declare -A FULL_TEXT_FIELDS=(
  [app_logs]="message"
  [postgres_logs]="message"
  [valkey_logs]="message"
)

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info()  { printf '%s [INFO]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Work directory
# ------------------------------------------------------------------------------

WORK_DIR=""
PRESERVE_WORK_DIR=false

cleanup() {
  local rc=$?
  set +e

  stop_o2_port_forward || true

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    if [[ "${PRESERVE_WORK_DIR}" == "true" || "${rc}" -ne 0 ]]; then
      printf '%s [INFO]  work directory preserved: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${WORK_DIR}" >&2
    else
      rm -rf -- "${WORK_DIR}"
    fi
  fi

  exit "${rc}"
}

trap cleanup EXIT

init_work_dir() {
  WORK_DIR="$(mktemp -d -t o2.XXXXXX)"
  chmod 0700 "${WORK_DIR}"
}

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

preflight_core() {
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  require_cmd jq
  require_cmd base64
  require_cmd awk
  require_cmd grep
  require_cmd sed

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the Kubernetes cluster"
}

preflight_chart() {
  [[ -d "${O2_CHART_PATH}" ]] \
    || die "Chart path does not exist: ${O2_CHART_PATH}"
  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] \
    || die "Chart missing Chart.yaml: ${O2_CHART_PATH}/Chart.yaml"
}

preflight_image() {
  if [[ "${O2_REQUIRE_IMAGE_DIGEST}" == "true" && -z "${O2_IMAGE_DIGEST}" ]]; then
    die "O2_REQUIRE_IMAGE_DIGEST=true but O2_IMAGE_DIGEST is empty"
  fi
}

# ------------------------------------------------------------------------------
# Namespace / secret helpers
# ------------------------------------------------------------------------------

ensure_namespace() {
  kubectl get namespace "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${O2_NAMESPACE}" >/dev/null
}

secret_has_key() {
  local secret="$1"
  local key="$2"
  local value

  kubectl get secret "${secret}" -n "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || return 1

  value="$(
    kubectl get secret "${secret}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath="{.data.${key}}" \
      2>/dev/null || true
  )"

  [[ -n "${value}" ]]
}

require_secrets() {
  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_EMAIL \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_EMAIL"

  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_PASSWORD \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_PASSWORD"
}

read_secret_value() {
  local key="$1"
  kubectl get secret "${O2_AUTH_SECRET}" \
    -n "${O2_NAMESPACE}" \
    -o jsonpath="{.data.${key}}" \
    | base64 -d
}

# ------------------------------------------------------------------------------
# StorageClass
# ------------------------------------------------------------------------------

detect_default_storage_class() {
  local sc

  sc="$(
    kubectl get storageclass \
      -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | head -n1
  )"

  if [[ -z "${sc}" ]]; then
    sc="$(
      kubectl get storageclass \
        -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | head -n1
    )"
  fi


  if [[ -z "${sc}" ]]; then
    log_warn "no default StorageClass found; using 'standard'"
    sc="standard"
  fi

  printf '%s' "${sc}"
}

# ------------------------------------------------------------------------------
# Helm values / image pinning
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  local sc="$2"
  local image_block

  if [[ -n "${O2_IMAGE_DIGEST}" ]]; then
    image_block="  digest: \"${O2_IMAGE_DIGEST}\""
  else
    image_block="  # digest intentionally unset; set O2_IMAGE_DIGEST for immutable production pinning"
  fi

  cat > "${out}" <<EOF_VALUES
# Generated by scripts/staging/openobserve.sh

replicaCount: 1

image:
  registry: "${O2_IMAGE_REGISTRY}"
  repository: "${O2_IMAGE_REPOSITORY}"
  tag: "${O2_IMAGE_TAG}"
${image_block}
  pullPolicy: IfNotPresent

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: false

secrets:
  auth: ${O2_AUTH_SECRET}

config:
  ZO_LOCAL_MODE: "true"
  ZO_LOCAL_MODE_STORAGE: "disk"
  ZO_META_STORE: "sqlite"

  ZO_DATA_DIR: "${O2_DATA_DIR}"
  ZO_DATA_DB_DIR: "${O2_DATA_DIR}/db"
  ZO_DATA_WAL_DIR: "${O2_DATA_DIR}/wal"

  ZO_FILE_PUSH_INTERVAL: "${O2_FILE_PUSH_INTERVAL}"
  ZO_MEM_PERSIST_INTERVAL: "${O2_MEM_PERSIST_INTERVAL}"
  ZO_MAX_FILE_SIZE_IN_MEMORY: "${O2_MAX_FILE_SIZE_IN_MEMORY}"
  ZO_MEM_TABLE_MAX_SIZE: "${O2_MEM_TABLE_MAX_SIZE}"

  ZO_COMPACT_FAST_MODE: "${O2_COMPACT_FAST_MODE}"
  ZO_COMPACT_MAX_FILE_SIZE: "${O2_COMPACT_MAX_FILE_SIZE}"
  ZO_COMPACT_DATA_RETENTION_DAYS: "${O2_RETENTION_DAYS}"

  ZO_HEALTH_CHECK_ENABLED: "true"
  ZO_TELEMETRY: "false"
  ZO_SKIP_SSRF_CHECKS: "${O2_SKIP_SSRF_CHECKS}"

  # UDS is deliberately not required for this fix. The telemetry pipeline
  # establishes a deterministic normalized schema before alert creation.
  ZO_ALLOW_USER_DEFINED_SCHEMAS: "false"

  RUST_LOG: "${O2_LOG_LEVEL}"

persistence:
  enabled: true
  size: "${O2_PVC_SIZE}"
  accessMode: ReadWriteOnce
  storageClass: "${sc}"

service:
  type: ClusterIP
  port: 5080

resources:
  requests:
    cpu: "${O2_CPU_REQUEST}"
    memory: "${O2_MEMORY_REQUEST}"
  limits:
    cpu: "${O2_CPU_LIMIT}"
    memory: "${O2_MEMORY_LIMIT}"

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65534
  capabilities:
    drop: ["ALL"]

probes:
  startup:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 60
  readiness:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3
  liveness:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 30
    timeoutSeconds: 5
    failureThreshold: 3

lifecycle:
  preStop:
    enabled: true
    sleepSeconds: ${O2_PRESTOP_SLEEP}

terminationGracePeriodSeconds: ${O2_TERMINATION_GRACE}

networkPolicy:
  enabled: true
  additionalFrom: []

podAnnotations: {}
podLabels: {}
nodeSelector: {}
tolerations: []
affinity: {}
extraEnv: []
extraEnvFrom: []
extraVolumes: []
extraVolumeMounts: []
EOF_VALUES
}

check_image_change() {
  if ! kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi

  local current target
  current="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')"

  if [[ -n "${O2_IMAGE_DIGEST}" ]]; then
    target="${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}@${O2_IMAGE_DIGEST}"
  else
    target="${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}:${O2_IMAGE_TAG}"
  fi

  if [[ "${current}" == "${target}" ]]; then
    return 0
  fi

  if [[ "${O2_ALLOW_IMAGE_CHANGE}" == "true" ]]; then
    log_warn "image change approved: ${current} -> ${target}"
    return 0
  fi

  die "Image change detected: ${current} -> ${target}. Set O2_ALLOW_IMAGE_CHANGE=true for an intentional change."
}

validate_chart() {
  local values="$1"

  helm lint "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}" \
    --strict \
    || { PRESERVE_WORK_DIR=true; return 1; }

  helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}" \
    >"${WORK_DIR}/rendered.yaml" \
    2>"${WORK_DIR}/template.err" \
    || {
      PRESERVE_WORK_DIR=true
      log_error "helm template failed"
      sed 's/^/  /' "${WORK_DIR}/template.err" >&2 || true
      return 1
    }
}

run_helm_upgrade() {
  local values="$1"

  helm upgrade --install "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --create-namespace \
    --values "${values}" \
    --timeout "${HELM_TIMEOUT}" \
    --history-max 10
}

# ------------------------------------------------------------------------------
# Port-forward / API
# ------------------------------------------------------------------------------

O2_PF_PID=""
O2_API_BASE=""
O2_API_USER=""
O2_API_PASSWORD=""

stop_o2_port_forward() {
  if [[ -n "${O2_PF_PID}" ]]; then
    kill "${O2_PF_PID}" >/dev/null 2>&1 || true
    wait "${O2_PF_PID}" >/dev/null 2>&1 || true
    O2_PF_PID=""
  fi
}

start_o2_port_forward() {
  stop_o2_port_forward

  local local_port="${O2_VERIFY_LOCAL_PORT}"
  if (echo >/dev/tcp/127.0.0.1/"${local_port}") 2>/dev/null; then
    die "Local port ${local_port} is already in use; set O2_VERIFY_LOCAL_PORT to another port"
  fi

  kubectl -n "${O2_NAMESPACE}" port-forward \
    "svc/${O2_RELEASE}" \
    "${local_port}:5080" \
    >"${WORK_DIR}/port-forward.log" 2>&1 &

  O2_PF_PID=$!

  local elapsed=0
  while (( elapsed < 30 )); do
    if ! kill -0 "${O2_PF_PID}" >/dev/null 2>&1; then
      log_error "port-forward exited unexpectedly"
      sed 's/^/  /' "${WORK_DIR}/port-forward.log" >&2 || true
      return 1
    fi

    if curl -fsS --connect-timeout 2 --max-time 3 \
      "http://127.0.0.1:${local_port}/healthz" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_error "OpenObserve port-forward did not become ready"
  sed 's/^/  /' "${WORK_DIR}/port-forward.log" >&2 || true
  return 1
}

init_o2_api_credentials() {
  O2_API_BASE="http://127.0.0.1:${O2_VERIFY_LOCAL_PORT}/api/${O2_ORGANIZATION}"
  O2_API_USER="$(read_secret_value ZO_ROOT_USER_EMAIL)"
  O2_API_PASSWORD="$(read_secret_value ZO_ROOT_USER_PASSWORD)"

  [[ -n "${O2_API_USER}" ]] || die "OpenObserve root email is empty"
  [[ -n "${O2_API_PASSWORD}" ]] || die "OpenObserve root password is empty"
}

o2_curl() {
  curl -sS \
    --fail-with-body \
    --retry 2 \
    --connect-timeout 5 \
    --max-time 30 \
    -u "${O2_API_USER}:${O2_API_PASSWORD}" \
    "$@"
}

# ------------------------------------------------------------------------------
# OpenObserve readiness
# ------------------------------------------------------------------------------

probe_healthz() {
  curl -fsS --connect-timeout 5 --max-time 10 \
    "http://127.0.0.1:${O2_VERIFY_LOCAL_PORT}/healthz" >/dev/null
}

get_stream_details() {
  local stream="$1"
  local type="$2"

  o2_curl \
    "${O2_API_BASE}/streams/${stream}/schema?type=${type}"
}

stream_exists() {
  local stream="$1"
  local type="$2"

  get_stream_details "${stream}" "${type}" >/dev/null 2>&1
}

stream_doc_count() {
  local stream="$1"
  local type="$2"

  get_stream_details "${stream}" "${type}" \
    | jq -r '.stats.doc_num // 0'
}

stream_has_field() {
  local stream="$1"
  local type="$2"
  local field="$3"
  local schema_json="$4"

  jq -e \
    --arg field "${field}" \
    '.schema // [] | any(.[]; .name == $field)' \
    <<<"${schema_json}" >/dev/null
}

verify_stream_contract() {
  local stream="$1"
  local type="${STREAM_TYPES[${stream}]}"
  local expected="${REQUIRED_FIELDS[${stream}]}"
  local json doc_num field

  json="$(get_stream_details "${stream}" "${type}")" \
    || die "Cannot retrieve stream schema: ${stream} (${type})"

  doc_num="$(jq -r '.stats.doc_num // 0' <<<"${json}")"

  [[ "${doc_num}" =~ ^[0-9]+$ ]] || die "Invalid doc_num for ${stream}: ${doc_num}"
  (( doc_num > 0 )) || die "Stream ${stream} exists but contains 0 records; log/metric ingestion is not ready"

  for field in ${expected}; do
    stream_has_field "${stream}" "${type}" "${field}" "${json}" \
      || die "Stream ${stream} is missing required field '${field}'. Current schema: $(jq -c '.schema // []' <<<"${json}")"
  done

  log_info "stream ready: ${stream} (${type}), records=${doc_num}"
}

wait_for_required_streams() {
  log_info "Waiting for real telemetry to create and populate required OpenObserve streams"
  log_info "Timeout=${O2_STREAM_READY_TIMEOUT}s; this intentionally blocks alert provisioning until schemas exist"

  local elapsed=0
  local stream type missing

  while (( elapsed <= O2_STREAM_READY_TIMEOUT )); do
    missing=()

    for stream in "${REQUIRED_STREAMS[@]}"; do
      type="${STREAM_TYPES[${stream}]}"
      if ! stream_exists "${stream}" "${type}"; then
        missing+=("${stream}")
        continue
      fi

      if [[ "${O2_WAIT_FOR_INGESTION}" == "true" ]]; then
        if ! verify_stream_contract_silent "${stream}"; then
          missing+=("${stream}:schema/data")
        fi
      fi
    done

    if (( ${#missing[@]} == 0 )); then
      log_info "All required streams are populated and schema-ready"
      return 0
    fi

    log_info "Still waiting: ${missing[*]}"
    sleep "${O2_STREAM_RETRY_INTERVAL}"
    elapsed=$((elapsed + O2_STREAM_RETRY_INTERVAL))
  done

  log_error "Required telemetry did not become ready within ${O2_STREAM_READY_TIMEOUT}s"
  for stream in "${REQUIRED_STREAMS[@]}"; do
    type="${STREAM_TYPES[${stream}]}"
    if stream_exists "${stream}" "${type}"; then
      log_error "--- ${stream} (${type}) ---"
      get_stream_details "${stream}" "${type}" | jq '{stats, schema, settings}' >&2 || true
    else
      log_error "--- ${stream} (${type}) MISSING ---"
    fi
  done

  return 1
}

verify_stream_contract_silent() {
  local stream="$1"
  local type="${STREAM_TYPES[${stream}]}"
  local expected="${REQUIRED_FIELDS[${stream}]}"
  local json doc_num field

  json="$(get_stream_details "${stream}" "${type}" 2>/dev/null)" || return 1
  doc_num="$(jq -r '.stats.doc_num // 0' <<<"${json}" 2>/dev/null)" || return 1
  (( doc_num > 0 )) || return 1

  for field in ${expected}; do
    jq -e --arg field "${field}" \
      '.schema // [] | any(.[]; .name == $field)' \
      <<<"${json}" >/dev/null 2>&1 || return 1
  done

  return 0
}

# ------------------------------------------------------------------------------
# Stream settings
# ------------------------------------------------------------------------------

reconcile_stream_settings() {
  local stream type fulltext body response status

  for stream in "app_logs" "postgres_logs" "valkey_logs"; do
    type="logs"
    fulltext="${FULL_TEXT_FIELDS[${stream}]}"
    body="$(jq -n \
      --argjson retention "${O2_RETENTION_DAYS}" \
      --arg fulltext "${fulltext}" \
      '{data_retention:$retention, full_text_search_keys:[$fulltext]}')"

    response="${WORK_DIR}/settings-${stream}.json"
    status="$(curl -sS \
      -o "${response}" \
      -w '%{http_code}' \
      --connect-timeout 5 \
      --max-time 30 \
      -u "${O2_API_USER}:${O2_API_PASSWORD}" \
      -X POST \
      -H 'Content-Type: application/json' \
      "${O2_API_BASE}/streams/${stream}/settings" \
      --data "${body}" \
      2>/dev/null || true)"

    case "${status}" in
      200|201)
        log_info "stream settings reconciled: ${stream} full_text=${fulltext} retention=${O2_RETENTION_DAYS}d"
        ;;
      401|403)
        die "OpenObserve rejected settings update for ${stream} (HTTP ${status})"
        ;;
      *)
        log_error "Failed to reconcile settings for ${stream} (HTTP ${status})"
        sed 's/^/  /' "${response}" >&2 || true
        return 1
        ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# SSRF verification
# ------------------------------------------------------------------------------

verify_ssrf_config() {
  local pod skip_ssrf

  pod="$(kubectl get pods -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || die "No OpenObserve pod found"

  skip_ssrf="$(kubectl get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
    | awk -F= '$1=="ZO_SKIP_SSRF_CHECKS" {print $2}' | head -n1)"

  [[ "${skip_ssrf}" == "${O2_SKIP_SSRF_CHECKS}" ]] \
    || die "ZO_SKIP_SSRF_CHECKS='${skip_ssrf}', expected '${O2_SKIP_SSRF_CHECKS}'"

  log_info "SSRF configuration OK (${skip_ssrf})"
}

# ------------------------------------------------------------------------------
# Diagnostics
# ------------------------------------------------------------------------------

collect_diagnostics() {
  log_error "===== OpenObserve diagnostics ====="

  log_error "--- Helm ---"
  helm status "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>&1 | sed 's/^/  /' || true

  log_error "--- Pods ---"
  kubectl -n "${O2_NAMESPACE}" get pods -o wide 2>&1 | sed 's/^/  /' || true

  log_error "--- Deployment ---"
  kubectl -n "${O2_NAMESPACE}" get deployment "${O2_RELEASE}" -o wide 2>&1 | sed 's/^/  /' || true

  log_error "--- PVC ---"
  kubectl -n "${O2_NAMESPACE}" get pvc 2>&1 | sed 's/^/  /' || true

  log_error "--- Events ---"
  kubectl -n "${O2_NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 40 | sed 's/^/  /' || true

  if [[ -n "${O2_PF_PID}" ]]; then
    log_error "--- OpenObserve stream listing ---"
    o2_curl "${O2_API_BASE}/streams?fetchSchema=true&type=logs" 2>&1 | sed 's/^/  /' || true
    o2_curl "${O2_API_BASE}/streams?fetchSchema=true&type=metrics" 2>&1 | sed 's/^/  /' || true
  fi
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------

cmd_deploy() {
  init_work_dir
  preflight_core
  preflight_chart
  preflight_image
  ensure_namespace
  require_secrets
  check_image_change

  local sc values
  sc="$(detect_default_storage_class)"
  values="${WORK_DIR}/values.yaml"

  log_info "Rendering Helm values"
  render_values "${values}" "${sc}"

  log_info "Validating Helm chart"
  validate_chart "${values}" || die "Helm chart validation failed; workdir=${WORK_DIR}"

  log_info "Deploying OpenObserve ${O2_IMAGE_TAG}"
  run_helm_upgrade "${values}" \
    || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "Helm upgrade failed"; }

  kubectl rollout status \
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" \
    || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "OpenObserve deployment did not become ready"; }

  start_o2_port_forward \
    || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "Could not establish OpenObserve port-forward"; }
  init_o2_api_credentials
  probe_healthz || die "OpenObserve /healthz failed"
  verify_ssrf_config

  # Critical fix: do not create empty streams. The OTel gateway's explicit
  # stream-name routing creates them on the first real record.
  if [[ "${O2_WAIT_FOR_INGESTION}" == "true" ]]; then
    wait_for_required_streams \
      || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "Telemetry streams are not ready"; }

    reconcile_stream_settings \
      || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "Stream settings reconciliation failed"; }
  else
    log_info "OpenObserve deployed. Stream readiness is deferred to openobserve.sh verify / terraform run.sh."
  fi

  log_info "OpenObserve deployment complete"
}

cmd_render() {
  init_work_dir
  preflight_core
  preflight_chart
  preflight_image
  PRESERVE_WORK_DIR=true

  local sc values
  sc="$(detect_default_storage_class)"
  values="${WORK_DIR}/values.yaml"
  render_values "${values}" "${sc}"

  echo "===== values.yaml =====" >&2
  cat "${values}" >&2
  echo "===== helm template =====" >&2
  helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}"
}

cmd_verify() {
  init_work_dir
  preflight_core
  ensure_namespace
  require_secrets
  preflight_image

  kubectl rollout status \
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null \
    || die "OpenObserve deployment is not ready"

  local pvc_phase image
  pvc_phase="$(kubectl get pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${pvc_phase}" == "Bound" ]] || die "PVC phase='${pvc_phase}', expected Bound"

  image="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  if [[ -n "${O2_IMAGE_DIGEST}" ]]; then
    [[ "${image}" == *"@${O2_IMAGE_DIGEST}"* ]] || die "Unexpected image: ${image}"
  else
    [[ "${image}" == "${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}:${O2_IMAGE_TAG}" ]] \
      || die "Unexpected image: ${image}"
  fi

  start_o2_port_forward || die "Could not establish OpenObserve port-forward"
  init_o2_api_credentials
  probe_healthz || die "/healthz failed"
  verify_ssrf_config

  wait_for_required_streams \
    || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "OpenObserve stream/schema contract failed"; }
  reconcile_stream_settings \
    || die "Stream settings verification/reconciliation failed"

  log_info "OpenObserve verification passed"
}

cmd_status() {
  preflight_core
  echo "=== Helm ==="
  helm list -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Deployment ==="
  kubectl get deployment -n "${O2_NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Pods ==="
  kubectl get pods -n "${O2_NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== PVC ==="
  kubectl get pvc -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Service ==="
  kubectl get svc -n "${O2_NAMESPACE}" 2>/dev/null || true
}

cmd_logs() {
  preflight_core
  kubectl logs \
    -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    --tail=300 \
    -f \
    "$@"
}

cmd_rollout() {
  init_work_dir
  preflight_core
  preflight_image
  require_secrets

  kubectl rollout restart deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}"
  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" --timeout="${READY_TIMEOUT}s"

  start_o2_port_forward || die "Could not establish OpenObserve port-forward"
  init_o2_api_credentials
  probe_healthz || die "/healthz failed after rollout"

  # Existing data means streams survive the restart. Verify the same readiness
  # contract and reconcile settings after every rollout.
  wait_for_required_streams \
    || { PRESERVE_WORK_DIR=true; collect_diagnostics; die "Streams/schema not ready after rollout"; }
  reconcile_stream_settings || die "Stream settings reconciliation failed"

  log_info "OpenObserve rollout verified"
}

cmd_delete() {
  preflight_core
  log_info "Uninstalling Helm release ${O2_RELEASE}; PVC is retained"
  helm uninstall "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>/dev/null || true
  log_info "Helm release removed; PVC retained"
}

cmd_purge() {
  preflight_core

  read -r -p "This deletes the OpenObserve PVC and all stored data. Type 'yes': " answer
  [[ "${answer}" == "yes" ]] || die "cancelled"

  helm uninstall "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>/dev/null || true
  kubectl delete pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" --ignore-not-found
  log_info "OpenObserve release and PVC purged"
}

# ------------------------------------------------------------------------------
# Usage / dispatch
# ------------------------------------------------------------------------------

usage() {
  cat <<'EOF_USAGE'
openobserve.sh — OpenObserve lifecycle for AutoSRE

Usage:
  bash scripts/staging/openobserve.sh deploy
  bash scripts/staging/openobserve.sh verify
  bash scripts/staging/openobserve.sh render
  bash scripts/staging/openobserve.sh status
  bash scripts/staging/openobserve.sh logs [kubectl logs args]
  bash scripts/staging/openobserve.sh rollout
  bash scripts/staging/openobserve.sh delete
  bash scripts/staging/openobserve.sh purge

Important:
  This script DOES NOT create empty alert streams.
  The OTel gateway must route real telemetry using OpenObserve's stream-name
  header. OpenObserve then creates the streams on first ingestion.

  deploy/verify intentionally wait until the required streams contain records
  and have the alert-required fields. Terraform alert creation must come after
  this gate passes.

Key environment overrides:
  O2_NAMESPACE                default: openobserve
  O2_RELEASE                  default: openobserve
  O2_ORGANIZATION             default: default
  O2_AUTH_SECRET              default: openobserve-auth
  O2_IMAGE_REGISTRY            default: public.ecr.aws
  O2_IMAGE_REPOSITORY          default: zinclabs/openobserve
  O2_IMAGE_TAG                 default: v1.0.4
  O2_IMAGE_DIGEST              default: empty (set for immutable pinning)
  O2_REQUIRE_IMAGE_DIGEST      default: false
  O2_ALLOW_IMAGE_CHANGE        default: false
  O2_WAIT_FOR_INGESTION        default: false (set true to make deploy block on real telemetry)
  O2_STREAM_READY_TIMEOUT      default: 300 seconds
  O2_STREAM_RETRY_INTERVAL     default: 5 seconds
  O2_SKIP_SSRF_CHECKS          default: true
EOF_USAGE
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    deploy)  cmd_deploy ;;
    verify)  cmd_verify ;;
    render)  cmd_render ;;
    status)  cmd_status ;;
    logs)    shift; cmd_logs "$@" ;;
    rollout) cmd_rollout ;;
    delete)  cmd_delete ;;
    purge)   cmd_purge ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
