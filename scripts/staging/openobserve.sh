#!/usr/bin/env bash
# ==============================================================================
# openobserve.sh — OpenObserve lifecycle for AutoSRE staging
#
# Ownership:
#   - Deploys and verifies the single-node OpenObserve instance.
#   - Owns creation/verification of the external telemetry streams.
#
# Terraform/OpenTofu does NOT manage streams.
# Terraform/OpenTofu manages alerting resources only.
#
# Required external streams:
#   logs/app_logs
#   logs/postgres_logs
#   logs/valkey_logs
#   metrics/k8s_pod_cpu_limit_utilization
#   metrics/k8s_pod_memory_limit_utilization
#
# Commands:
#   deploy     Deploy/upgrade OpenObserve, then ensure required streams exist.
#   render     Render Helm values and templates; do not apply.
#   delete     Remove Helm release; retain PVC/data.
#   purge      Remove Helm release and PVC/data.
#   status     Show Helm/Kubernetes state.
#   verify     Verify OpenObserve, credentials, image, configuration, streams.
#   logs       Tail OpenObserve logs.
#   rollout    Restart OpenObserve and wait for readiness.
#
# API contract:
#   GET  /api/{org}/streams
#   GET  /api/{org}/streams/{stream}/schema?type={type}
#   POST /api/{org}/streams/{stream}?type={type}
#
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

# OpenObserve image is pinned by digest.
O2_IMAGE_REGISTRY="${O2_IMAGE_REGISTRY:-ghcr.io}"
O2_IMAGE_REPOSITORY="${O2_IMAGE_REPOSITORY:-athithya-sakthivel/openobserve}"
O2_IMAGE_TAG="${O2_IMAGE_TAG:-v1.0.4}"
O2_IMAGE_DIGEST="${O2_IMAGE_DIGEST:-sha256:d4a878fac1f6c56003764f7f2a1625668917388f167e222c8c810de3f54c56ba}"
O2_ALLOW_IMAGE_CHANGE="${O2_ALLOW_IMAGE_CHANGE:-false}"

# ESO creates this Secret in the OpenObserve namespace.
O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"

# OpenObserve organization used by OTel and Terraform/OpenTofu.
O2_ORG="${O2_ORG:-${TF_VAR_o2_organization:-default}}"

# OpenObserve service/API port.
O2_SERVICE_PORT="${O2_SERVICE_PORT:-5080}"

# Temporary localhost port used only by this script for the stream API.
O2_STREAM_API_LOCAL_PORT="${O2_STREAM_API_LOCAL_PORT:-15081}"

# Local-disk storage configuration.
O2_PVC_SIZE="${O2_PVC_SIZE:-20Gi}"
O2_DATA_DIR="${O2_DATA_DIR:-/data/openobserve}"
O2_RETENTION_DAYS="${O2_RETENTION_DAYS:-30}"

# Resource configuration.
O2_CPU_REQUEST="${O2_CPU_REQUEST:-1}"
O2_CPU_LIMIT="${O2_CPU_LIMIT:-2}"
O2_MEMORY_REQUEST="${O2_MEMORY_REQUEST:-1Gi}"
O2_MEMORY_LIMIT="${O2_MEMORY_LIMIT:-2Gi}"

# OpenObserve runtime configuration.
O2_LOG_LEVEL="${O2_LOG_LEVEL:-info}"
O2_MEM_TABLE_MAX_SIZE="${O2_MEM_TABLE_MAX_SIZE:-512}"
O2_MAX_FILE_SIZE_IN_MEMORY="${O2_MAX_FILE_SIZE_IN_MEMORY:-128}"
O2_FILE_PUSH_INTERVAL="${O2_FILE_PUSH_INTERVAL:-10}"
O2_MEM_PERSIST_INTERVAL="${O2_MEM_PERSIST_INTERVAL:-5}"
O2_COMPACT_FAST_MODE="${O2_COMPACT_FAST_MODE:-false}"
O2_COMPACT_MAX_FILE_SIZE="${O2_COMPACT_MAX_FILE_SIZE:-256}"

# Internal/private alert destinations are intentionally allowed.
# This is required for the AutoSRE Kubernetes service destination.
O2_SKIP_SSRF_CHECKS="${O2_SKIP_SSRF_CHECKS:-true}"

O2_TERMINATION_GRACE="${O2_TERMINATION_GRACE:-120}"
O2_PRESTOP_SLEEP="${O2_PRESTOP_SLEEP:-10}"

HELM_TIMEOUT="${HELM_TIMEOUT:-120s}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"

# ------------------------------------------------------------------------------
# Required stream contract
# ------------------------------------------------------------------------------

REQUIRED_LOG_STREAMS=(
  app_logs
  postgres_logs
  valkey_logs
)

REQUIRED_METRIC_STREAMS=(
  k8s_pod_cpu_limit_utilization
  k8s_pod_memory_limit_utilization
)

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info() {
  printf '%s [INFO]  %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

log_warn() {
  printf '%s [WARN]  %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

log_error() {
  printf '%s [ERROR] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

# ------------------------------------------------------------------------------
# Work directory
# ------------------------------------------------------------------------------

WORK_DIR=""
PRESERVE_WORK_DIR=false

cleanup() {
  local rc=$?
  set +e

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    if [[ "${PRESERVE_WORK_DIR}" == "true" || "${rc}" -ne 0 ]]; then
      log_info "work directory preserved: ${WORK_DIR}"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || die "Missing command: $1"
}

# ------------------------------------------------------------------------------
# Core preflight
# ------------------------------------------------------------------------------

preflight_core() {
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  require_cmd jq

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the cluster"

  [[ -n "${O2_ORG}" ]] \
    || die "O2_ORG must not be empty"
}

preflight_chart() {
  [[ -d "${O2_CHART_PATH}" ]] \
    || die "Chart path does not exist: ${O2_CHART_PATH}"

  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] \
    || die "Chart missing Chart.yaml"
}

# ------------------------------------------------------------------------------
# Namespace and Secret checks
# ------------------------------------------------------------------------------

ensure_namespace() {
  kubectl get namespace "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${O2_NAMESPACE}" >/dev/null
}

secret_has_key() {
  local secret="$1"
  local key="$2"
  local value

  kubectl get secret "${secret}" -n "${O2_NAMESPACE}" \
    >/dev/null 2>&1 \
    || return 1

  value="$(
    kubectl get secret "${secret}" -n "${O2_NAMESPACE}" \
      -o jsonpath="{.data.${key}}" \
      2>/dev/null || true
  )"

  [[ -n "${value}" ]]
}

require_secrets() {
  secret_has_key "${O2_AUTH_SECRET}" "ZO_ROOT_USER_EMAIL" \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_EMAIL"

  secret_has_key "${O2_AUTH_SECRET}" "ZO_ROOT_USER_PASSWORD" \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_PASSWORD"

  # This is the Basic auth credential consumed by both OTel collectors.
  secret_has_key "${O2_AUTH_SECRET}" "OPENOBSERVE_AUTH" \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key OPENOBSERVE_AUTH"
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
    log_warn "no default StorageClass found; falling back to 'standard'"
    sc="standard"
  fi

  printf '%s' "${sc}"
}

# ------------------------------------------------------------------------------
# Helm values
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  local sc="$2"

  cat > "${out}" <<EOF
# Rendered by scripts/staging/openobserve.sh
# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)

# The chart intentionally supports one replica only because this deployment
# uses a single local PVC and SQLite metadata.
replicaCount: 1

image:
  registry: "${O2_IMAGE_REGISTRY}"
  repository: "${O2_IMAGE_REPOSITORY}"
  tag: "${O2_IMAGE_TAG}"
  digest: "${O2_IMAGE_DIGEST}"
  pullPolicy: IfNotPresent

imagePullSecrets: []

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: false

# Authentication Secret is produced by ESO.
# It contains:
#   ZO_ROOT_USER_EMAIL
#   ZO_ROOT_USER_PASSWORD
#   OPENOBSERVE_AUTH
secrets:
  auth: ${O2_AUTH_SECRET}

# OpenObserve local-disk configuration.
# No S3/Azure storage is configured by this chart.
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

  # OpenObserve alert destinations include the in-cluster AutoSRE webhook.
  # Kubernetes service names resolve to private cluster addresses, so the
  # OpenObserve SSRF protection must be explicitly disabled for this staging
  # deployment.
  ZO_SKIP_SSRF_CHECKS: "${O2_SKIP_SSRF_CHECKS}"

  RUST_LOG: "${O2_LOG_LEVEL}"

persistence:
  enabled: true
  size: "${O2_PVC_SIZE}"
  accessMode: ReadWriteOnce
  storageClass: "${sc}"

service:
  type: ClusterIP
  port: ${O2_SERVICE_PORT}

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

# Keep podAnnotations defined as an object so templates may safely extend it.
podAnnotations: {}
podLabels: {}

nodeSelector: {}
tolerations: []
affinity: {}

networkPolicy:
  enabled: true
  additionalFrom: []

extraEnv: []
extraEnvFrom: []
extraVolumes: []
extraVolumeMounts: []
EOF

  chmod 0600 "${out}"
}

# ------------------------------------------------------------------------------
# Image immutability gate
# ------------------------------------------------------------------------------

check_image_change() {
  if ! kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
      >/dev/null 2>&1; then
    return 0
  fi

  local current target

  current="$(
    kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )"

  target="${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}@${O2_IMAGE_DIGEST}"

  [[ "${current}" == "${target}" ]] \
    && return 0

  if [[ "${O2_ALLOW_IMAGE_CHANGE}" == "true" ]]; then
    log_warn "approved image change: ${current} -> ${target}"
    return 0
  fi

  die "Image change detected: ${current} -> ${target}
Re-run with O2_ALLOW_IMAGE_CHANGE=true to approve the change."
}

# ------------------------------------------------------------------------------
# Helm validation
# ------------------------------------------------------------------------------

validate_chart() {
  local values="$1"

  log_info "Running helm lint"

  helm lint "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}" \
    --strict

  log_info "Running helm template"

  if ! helm template \
      "${O2_RELEASE}" \
      "${O2_CHART_PATH}" \
      --namespace "${O2_NAMESPACE}" \
      --values "${values}" \
      >/dev/null \
      2>"${WORK_DIR}/template.err"; then

    PRESERVE_WORK_DIR=true

    log_error "helm template failed:"
    sed 's/^/  /' "${WORK_DIR}/template.err" >&2 || true

    return 1
  fi
}

# ------------------------------------------------------------------------------
# Helm deployment
# ------------------------------------------------------------------------------

run_helm_upgrade() {
  local values="$1"

  helm upgrade --install \
    "${O2_RELEASE}" \
    "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --create-namespace \
    --values "${values}" \
    --timeout "${HELM_TIMEOUT}" \
    --history-max 10
}

# ------------------------------------------------------------------------------
# Rollout diagnostics
# ------------------------------------------------------------------------------

collect_diagnostics() {
  log_error "--- helm status ---"
  helm status "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>&1 | sed 's/^/  /' || true

  log_error "--- helm history ---"
  helm history "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>&1 | sed 's/^/  /' || true

  log_error "--- pods ---"
  kubectl get pods \
    -n "${O2_NAMESPACE}" \
    -o wide \
    2>&1 | sed 's/^/  /' || true

  log_error "--- deployment ---"
  kubectl get deployment \
    "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    -o wide \
    2>&1 | sed 's/^/  /' || true

  log_error "--- deployment describe ---"
  kubectl describe deployment \
    "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>&1 | tail -80 | sed 's/^/  /' || true

  log_error "--- pvc ---"
  kubectl get pvc \
    -n "${O2_NAMESPACE}" \
    2>&1 | sed 's/^/  /' || true

  log_error "--- recent events ---"
  kubectl get events \
    -n "${O2_NAMESPACE}" \
    --sort-by=.lastTimestamp \
    2>&1 | tail -40 | sed 's/^/  /' || true

  local pod

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue

    log_error "--- pod describe: ${pod} ---"
    kubectl describe pod "${pod}" \
      -n "${O2_NAMESPACE}" \
      2>&1 | tail -80 | sed 's/^/  /' || true

    log_error "--- pod logs: ${pod} ---"
    kubectl logs "${pod}" \
      -n "${O2_NAMESPACE}" \
      --tail=120 \
      2>&1 | sed 's/^/  /' || true

    log_error "--- previous pod logs: ${pod} ---"
    kubectl logs "${pod}" \
      -n "${O2_NAMESPACE}" \
      --previous \
      --tail=120 \
      2>&1 | sed 's/^/  /' || true

  done < <(
    kubectl get pods \
      -n "${O2_NAMESPACE}" \
      -l "app.kubernetes.io/instance=${O2_RELEASE}" \
      -o name \
      2>/dev/null \
      | sed 's|^pod/||'
  )
}

# ------------------------------------------------------------------------------
# OpenObserve API access
# ------------------------------------------------------------------------------

STREAM_PF_PID=""

stop_stream_port_forward() {
  if [[ -n "${STREAM_PF_PID}" ]]; then
    kill "${STREAM_PF_PID}" 2>/dev/null || true
    wait "${STREAM_PF_PID}" 2>/dev/null || true
    STREAM_PF_PID=""
  fi
}

start_stream_port_forward() {
  stop_stream_port_forward

  log_info \
    "Starting temporary OpenObserve port-forward on 127.0.0.1:${O2_STREAM_API_LOCAL_PORT}"

  kubectl port-forward \
    -n "${O2_NAMESPACE}" \
    "svc/${O2_RELEASE}" \
    "${O2_STREAM_API_LOCAL_PORT}:${O2_SERVICE_PORT}" \
    >"${WORK_DIR}/stream-port-forward.log" \
    2>&1 &

  STREAM_PF_PID=$!

  local elapsed=0

  while (( elapsed < 30 )); do
    if curl -fsS \
      --connect-timeout 2 \
      --max-time 5 \
      "http://127.0.0.1:${O2_STREAM_API_LOCAL_PORT}/healthz" \
      >/dev/null 2>&1; then

      log_info "OpenObserve API port-forward ready"
      return 0
    fi

    if ! kill -0 "${STREAM_PF_PID}" 2>/dev/null; then
      log_error "OpenObserve port-forward exited unexpectedly"
      sed 's/^/  /' "${WORK_DIR}/stream-port-forward.log" >&2 || true
      return 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_error "OpenObserve API port-forward did not become ready"
  sed 's/^/  /' "${WORK_DIR}/stream-port-forward.log" >&2 || true
  return 1
}

o2_auth_header() {
  local email password

  email="$(
    kubectl get secret "${O2_AUTH_SECRET}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' \
      | base64 -d
  )"

  password="$(
    kubectl get secret "${O2_AUTH_SECRET}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' \
      | base64 -d
  )"

  printf 'Basic %s' \
    "$(printf '%s:%s' "${email}" "${password}" | base64 | tr -d '\n')"
}

o2_get() {
  local url="$1"

  curl -fsS \
    --connect-timeout 5 \
    --max-time 30 \
    -H "Authorization: $(o2_auth_header)" \
    -H "Accept: application/json" \
    "${url}"
}

o2_get_code() {
  local url="$1"

  curl -sS \
    --connect-timeout 5 \
    --max-time 30 \
    -H "Authorization: $(o2_auth_header)" \
    -H "Accept: application/json" \
    -o "${WORK_DIR}/o2-response.json" \
    -w '%{http_code}' \
    "${url}"
}

o2_stream_base() {
  printf 'http://127.0.0.1:%s/api/%s' \
    "${O2_STREAM_API_LOCAL_PORT}" \
    "${O2_ORG}"
}

stream_schema_json() {
  local stream="$1"
  local type="$2"

  o2_get \
    "$(o2_stream_base)/streams/${stream}/schema?type=${type}"
}

stream_exists() {
  local stream="$1"
  local type="$2"
  local json

  json="$(
    o2_get \
      "$(o2_stream_base)/streams?fetchSchema=false&type=${type}&keyword=${stream}&limit=100" \
      2>/dev/null || true
  )"

  [[ -n "${json}" ]] || return 1

  jq -e \
    --arg stream "${stream}" \
    --arg type "${type}" \
    '
      .list[]?
      | select(.name == $stream and .stream_type == $type)
    ' \
    <<<"${json}" \
    >/dev/null
}

create_stream() {
  local stream="$1"
  local type="$2"

  # OpenObserve requires both fields and settings in the create request.
  # Empty fields intentionally allow the schema to be inferred from the
  # telemetry actually ingested by the OTel collectors.
  local body_file="${WORK_DIR}/create-${type}-${stream}.json"

  jq -nc \
    '{
      fields: [],
      settings: {
        data_retention: 30
      }
    }' >"${body_file}"

  local code

  code="$(
    curl -sS \
      --connect-timeout 5 \
      --max-time 30 \
      -H "Authorization: $(o2_auth_header)" \
      -H "Content-Type: application/json" \
      -X POST \
      -o "${WORK_DIR}/create-response.json" \
      -w '%{http_code}' \
      "$(o2_stream_base)/streams/${stream}?type=${type}" \
      --data-binary @"${body_file}"
  )"

  case "${code}" in
    200)
      log_info "Created stream ${type}/${stream}"
      return 0
      ;;

    400|409)
      # Ingestion may create the stream between our existence check and POST.
      # Accept the race if the stream now exists with the required type.
      if stream_exists "${stream}" "${type}"; then
        log_info "Stream ${type}/${stream} appeared concurrently; continuing"
        return 0
      fi
      ;;

    *)
      ;;
  esac

  log_error \
    "Failed creating stream ${type}/${stream} (HTTP ${code})"

  if [[ -s "${WORK_DIR}/create-response.json" ]]; then
    sed 's/^/  /' "${WORK_DIR}/create-response.json" >&2 || true
  fi

  return 1
}

ensure_stream() {
  local stream="$1"
  local type="$2"

  if stream_exists "${stream}" "${type}"; then
    log_info "Stream already exists: ${type}/${stream}"
    return 0
  fi

  log_info "Creating required stream: ${type}/${stream}"

  create_stream "${stream}" "${type}" \
    || die "Unable to create required stream ${type}/${stream}"

  stream_exists "${stream}" "${type}" \
    || die "Required stream still not visible after creation: ${type}/${stream}"

  log_info "Verified stream: ${type}/${stream}"
}

ensure_required_streams() {
  log_info "Ensuring required OpenObserve telemetry streams"

  start_stream_port_forward \
    || die "Cannot reach OpenObserve stream API"

  local stream

  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    ensure_stream "${stream}" "logs"
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    ensure_stream "${stream}" "metrics"
  done

  stop_stream_port_forward

  log_info "All required OpenObserve streams exist"
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------

cmd_deploy() {
  init_work_dir
  preflight_core
  preflight_chart

  ensure_namespace
  require_secrets
  check_image_change

  local sc
  sc="$(detect_default_storage_class)"

  log_info "Default StorageClass: ${sc}"

  local values="${WORK_DIR}/values.yaml"
  render_values "${values}" "${sc}"

  log_info "Running helm lint"

  if ! helm lint \
      "${O2_CHART_PATH}" \
      --namespace "${O2_NAMESPACE}" \
      --values "${values}" \
      --strict; then

    PRESERVE_WORK_DIR=true
    die "helm lint failed"
  fi

  log_info "Running helm template"

  if ! helm template \
      "${O2_RELEASE}" \
      "${O2_CHART_PATH}" \
      --namespace "${O2_NAMESPACE}" \
      --values "${values}" \
      >/dev/null \
      2>"${WORK_DIR}/template.err"; then

    PRESERVE_WORK_DIR=true

    log_error "helm template failed:"
    sed 's/^/  /' "${WORK_DIR}/template.err" >&2 || true

    die "helm template failed"
  fi

  log_info "Installing/upgrading ${O2_RELEASE}"

  if ! run_helm_upgrade "${values}"; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "helm upgrade failed"
  fi

  log_info \
    "Waiting for deployment rollout (timeout=${READY_TIMEOUT}s)"

  if ! kubectl rollout status \
      "deployment/${O2_RELEASE}" \
      -n "${O2_NAMESPACE}" \
      --timeout="${READY_TIMEOUT}s"; then

    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "deployment did not become ready"
  fi

  ensure_required_streams

  log_info "OpenObserve deploy complete"
}

cmd_render() {
  init_work_dir
  preflight_core
  preflight_chart

  PRESERVE_WORK_DIR=true

  local sc
  sc="$(detect_default_storage_class)"

  local values="${WORK_DIR}/values.yaml"
  render_values "${values}" "${sc}"

  echo "===== values.yaml =====" >&2
  cat "${values}" >&2

  echo "===== helm template =====" >&2

  helm template \
    "${O2_RELEASE}" \
    "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}"
}

cmd_delete() {
  preflight_core

  log_info \
    "Removing Helm release ${O2_RELEASE}; PVC/data are retained"

  helm uninstall \
    "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>/dev/null || true

  log_info "Helm release removed"
}

cmd_purge() {
  preflight_core

  printf \
    "This deletes the OpenObserve PVC and all local data. Type 'yes' to confirm: "

  local answer
  read -r answer

  [[ "${answer}" == "yes" ]] \
    || die "cancelled"

  cmd_delete

  kubectl delete pvc \
    "${O2_RELEASE}-data" \
    -n "${O2_NAMESPACE}" \
    --ignore-not-found

  log_info "purge complete"
}

cmd_status() {
  preflight_core

  echo "=== Helm release ==="
  helm list \
    -n "${O2_NAMESPACE}" \
    2>/dev/null || true

  echo
  echo "=== Deployment ==="
  kubectl get deployment \
    -n "${O2_NAMESPACE}" \
    -o wide \
    2>/dev/null || true

  echo
  echo "=== Pods ==="
  kubectl get pods \
    -n "${O2_NAMESPACE}" \
    -o wide \
    2>/dev/null || true

  echo
  echo "=== PVC ==="
  kubectl get pvc \
    -n "${O2_NAMESPACE}" \
    2>/dev/null || true

  echo
  echo "=== Service ==="
  kubectl get svc \
    -n "${O2_NAMESPACE}" \
    2>/dev/null || true
}

cmd_verify() {
  init_work_dir
  preflight_core
  ensure_namespace
  require_secrets

  kubectl rollout status \
    "deployment/${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" \
    >/dev/null \
    || die "OpenObserve deployment is not ready"

  log_info "OpenObserve deployment ready"

  local pvc_phase
  pvc_phase="$(
    kubectl get pvc \
      "${O2_RELEASE}-data" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.status.phase}'
  )"

  [[ "${pvc_phase}" == "Bound" ]] \
    || die "PVC phase is ${pvc_phase}; expected Bound"

  log_info "PVC ready"

  local image
  image="$(
    kubectl get deployment \
      "${O2_RELEASE}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )"

  [[ "${image}" == *"${O2_IMAGE_DIGEST}"* ]] \
    || die "OpenObserve image is not pinned to expected digest: ${image}"

  log_info "Image digest verified"

  local pod
  pod="$(
    kubectl get pods \
      -n "${O2_NAMESPACE}" \
      -l "app.kubernetes.io/instance=${O2_RELEASE}" \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  [[ -n "${pod}" ]] \
    || die "No OpenObserve pod found"

  local env_names
  env_names="$(
    kubectl get pod "${pod}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{range .spec.containers[0].env[*]}{.name}{"\n"}{end}'
  )"

  local required_env=(
    ZO_LOCAL_MODE
    ZO_LOCAL_MODE_STORAGE
    ZO_META_STORE
    ZO_DATA_DIR
    ZO_DATA_DB_DIR
    ZO_DATA_WAL_DIR
    ZO_HEALTH_CHECK_ENABLED
    ZO_TELEMETRY
    ZO_SKIP_SSRF_CHECKS
    RUST_LOG
  )

  local key missing=0

  for key in "${required_env[@]}"; do
    if ! grep -qx "${key}" <<<"${env_names}"; then
      log_error "missing OpenObserve env: ${key}"
      missing=1
    fi
  done

  (( missing == 0 )) \
    || die "OpenObserve environment validation failed"

  log_info "OpenObserve environment verified"

  if grep -qE '^AZURE_STORAGE_|^ZO_S3_' <<<"${env_names}"; then
    die "Object-storage environment variables are present; this deployment is local-disk only"
  fi

  log_info "No object-storage environment variables present"

  local ready
  ready="$(
    kubectl get pod "${pod}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.status.containerStatuses[0].ready}'
  )"

  [[ "${ready}" == "true" ]] \
    || die "OpenObserve container is not Ready"

  log_info "Container Ready"

  kubectl exec \
    "${pod}" \
    -n "${O2_NAMESPACE}" \
    -- wget -q -O- \
      --timeout=5 \
      "http://localhost:${O2_SERVICE_PORT}/healthz" \
      >/dev/null \
      2>&1 \
    || die "OpenObserve /healthz check failed"

  log_info "OpenObserve health endpoint OK"

  start_stream_port_forward \
    || die "OpenObserve stream API unavailable"

  local stream

  for stream in "${REQUIRED_LOG_STREAMS[@]}"; do
    stream_schema_json "${stream}" logs >/dev/null \
      || die "Missing/unreadable logs stream: ${stream}"
    log_info "Verified logs/${stream}"
  done

  for stream in "${REQUIRED_METRIC_STREAMS[@]}"; do
    stream_schema_json "${stream}" metrics >/dev/null \
      || die "Missing/unreadable metrics stream: ${stream}"
    log_info "Verified metrics/${stream}"
  done

  stop_stream_port_forward

  log_info "all OpenObserve checks passed"
}

cmd_logs() {
  preflight_core

  kubectl logs \
    -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    --tail=200 \
    -f \
    "$@"
}

cmd_rollout() {
  preflight_core

  kubectl rollout restart \
    "deployment/${O2_RELEASE}" \
    -n "${O2_NAMESPACE}"

  kubectl rollout status \
    "deployment/${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s"

  log_info "rollout complete"
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
openobserve.sh — OpenObserve lifecycle for AutoSRE staging

Usage:
  $(basename "$0") <command> [args]

Commands:
  deploy
      Deploy or upgrade OpenObserve and ensure required streams exist.

  render
      Render values and Helm manifests without applying them.

  delete
      Remove the Helm release while retaining the PVC/data.

  purge
      Remove the Helm release and PVC/data.

  status
      Show Helm/Kubernetes state.

  verify
      Verify deployment, image, local-disk config, secret contract,
      health endpoint, and all required telemetry streams.

  logs [args]
      Tail OpenObserve logs.

  rollout
      Restart OpenObserve and wait for rollout completion.

Environment:
  O2_NAMESPACE
      default: openobserve

  O2_RELEASE
      default: openobserve

  O2_CHART_PATH
      default: infra/k8s/open-observe-minimal

  O2_IMAGE_TAG
      default: v1.0.4

  O2_IMAGE_DIGEST
      default: sha256:d4a878fac1f6c56003764f7f2a1625668917388f167e222c8c810de3f54c56ba

  O2_ALLOW_IMAGE_CHANGE
      default: false

  O2_AUTH_SECRET
      default: openobserve-auth

  O2_ORG
      default: default

  O2_SKIP_SSRF_CHECKS
      default: true

  O2_STREAM_API_LOCAL_PORT
      default: 15081

  O2_PVC_SIZE
      default: 20Gi

  HELM_TIMEOUT
      default: 120s

  READY_TIMEOUT
      default: 180

Required streams managed here:
  logs/app_logs
  logs/postgres_logs
  logs/valkey_logs
  metrics/k8s_pod_cpu_limit_utilization
  metrics/k8s_pod_memory_limit_utilization
EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] \
    || {
      usage
      exit 2
    }

  local cmd="$1"
  shift

  case "${cmd}" in
    deploy)
      [[ $# -eq 0 ]] \
        || die "deploy accepts no positional arguments"
      cmd_deploy
      ;;

    render)
      [[ $# -eq 0 ]] \
        || die "render accepts no positional arguments"
      cmd_render
      ;;

    delete)
      [[ $# -eq 0 ]] \
        || die "delete accepts no positional arguments"
      cmd_delete
      ;;

    purge)
      [[ $# -eq 0 ]] \
        || die "purge accepts no positional arguments"
      cmd_purge
      ;;

    status)
      [[ $# -eq 0 ]] \
        || die "status accepts no positional arguments"
      cmd_status
      ;;

    verify)
      [[ $# -eq 0 ]] \
        || die "verify accepts no positional arguments"
      cmd_verify
      ;;

    logs)
      cmd_logs "$@"
      ;;

    rollout)
      [[ $# -eq 0 ]] \
        || die "rollout accepts no positional arguments"
      cmd_rollout
      ;;

    help|--help|-h)
      [[ $# -eq 0 ]] \
        || die "help accepts no positional arguments"
      usage
      ;;

    *)
      log_error "unknown command: ${cmd}"
      usage
      exit 2
      ;;
  esac
}

main "$@"
