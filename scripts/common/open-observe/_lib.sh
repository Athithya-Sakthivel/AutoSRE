#!/usr/bin/env bash
# ==============================================================================
# Shared library for OpenObserve lifecycle scripts.
# Sourced by deploy.sh, backup.sh, restore.sh, inspect.sh, status.sh.
# ==============================================================================

# Prevent double-sourcing
[[ -n "${_O2_LIB_LOADED:-}" ]] && return 0
_O2_LIB_LOADED=1

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------

readonly O2_VERSION="1.2.0"
readonly O2_RUN_ID="$(date -u +"%Y%m%d-%H%M%S")"
readonly O2_LOCK_FD=200

# ------------------------------------------------------------------------------
# Configuration (override via environment variables)
# ------------------------------------------------------------------------------

# Kubernetes
O2_NAMESPACE="${O2_NAMESPACE:-openobserve}"
O2_RELEASE="${O2_RELEASE:-openobserve}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"

# Vendored chart
O2_CHART_PATH="${O2_CHART_PATH:-infra/k8s/open-observe-minimal}"

# Image
O2_IMAGE_REGISTRY="${O2_IMAGE_REGISTRY:-ghcr.io}"
O2_IMAGE_REPOSITORY="${O2_IMAGE_REPOSITORY:-athithya-sakthivel/openobserve}"
O2_IMAGE_TAG="${O2_IMAGE_TAG:-v0.92.2}"
O2_IMAGE_PULL_SECRET="${O2_IMAGE_PULL_SECRET:-ghcr-pull-secret}"

# Secrets (pre-existing; created manually or by ESO)
O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"
O2_STORAGE_SECRET="${O2_STORAGE_SECRET:-openobserve-storage}"

# Storage
O2_S3_PROVIDER="${O2_S3_PROVIDER:-azure}"
O2_S3_BUCKET="${O2_S3_BUCKET:-autosre-telemetry}"
O2_BACKUP_CONTAINER="${O2_BACKUP_CONTAINER:-autosre-backups}"
O2_BACKUP_PREFIX="${O2_BACKUP_PREFIX:-openobserve}"
O2_SQLITE_PATH="${O2_SQLITE_PATH:-/data/metadata.sqlite}"

# Retention
O2_RETENTION_DAYS="${O2_RETENTION_DAYS:-30}"
O2_BACKUP_RETENTION_DAYS="${O2_BACKUP_RETENTION_DAYS:-90}"

# Resources
O2_CPU_REQUEST="${O2_CPU_REQUEST:-100m}"
O2_MEMORY_REQUEST="${O2_MEMORY_REQUEST:-256Mi}"
O2_CPU_LIMIT="${O2_CPU_LIMIT:-500m}"
O2_MEMORY_LIMIT="${O2_MEMORY_LIMIT:-512Mi}"

# Persistence
O2_PVC_SIZE="${O2_PVC_SIZE:-5Gi}"
O2_STORAGE_CLASS="${O2_STORAGE_CLASS:-}"

# Operational
O2_HELM_TIMEOUT="${O2_HELM_TIMEOUT:-600s}"
O2_JOB_TIMEOUT="${O2_JOB_TIMEOUT:-600s}"
O2_SCALE_TIMEOUT="${O2_SCALE_TIMEOUT:-180}"
O2_POD_READY_TIMEOUT="${O2_POD_READY_TIMEOUT:-300}"
O2_LOG_LEVEL="${O2_LOG_LEVEL:-info}"
O2_BACKUP_IMAGE="${O2_BACKUP_IMAGE:-mcr.microsoft.com/azure-cli:2.67.0}"

# Flags (set by entry scripts)
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
YES="${YES:-false}"

# Runtime state
TMP_DIR=""
SCALE_DOWN_IN_PROGRESS="false"
DEPLOYMENT_NAME=""
PVC_NAME=""

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

_o2_log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${level}" "$*" >&2
}
log_info()  { _o2_log INFO  "$@"; }
log_warn()  { _o2_log WARN  "$@"; }
log_error() { _o2_log ERROR "$@"; }
log_debug() { [[ "${O2_LOG_LEVEL}" == "debug" ]] && _o2_log DEBUG "$@" || true; }
die()       { log_error "$@"; exit 1; }

# ------------------------------------------------------------------------------
# Runtime lifecycle
# ------------------------------------------------------------------------------

_o2_cleanup() {
  local exit_code=$?
  if [[ "${SCALE_DOWN_IN_PROGRESS}" == "true" && "${DRY_RUN}" != "true" && -n "${DEPLOYMENT_NAME}" ]]; then
    log_warn "Restoring deployment after interruption"
    "${KUBECTL}" scale deployment/"${DEPLOYMENT_NAME}" -n "${O2_NAMESPACE}" \
      --replicas=1 2>/dev/null || true
  fi
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  exit "${exit_code}"
}

_o2_on_error() { log_error "Failed at line $1"; exit 1; }
_o2_on_signal() { log_warn "Signal received: $1"; exit 130; }

_o2_acquire_lock() {
  local lock_file="/var/lock/o2-lifecycle.lock"
  touch "${lock_file}" 2>/dev/null || lock_file="/tmp/o2-lifecycle.lock"
  exec 200>"${lock_file}"
  flock -n 200 || die "Another OpenObserve lifecycle script is running"
}
# Call after sourcing. Installs traps, creates tmpdir, acquires lock.
init_runtime() {
  _o2_acquire_lock
  TMP_DIR="$(mktemp -d -t o2-XXXXXX)"
  trap '_o2_on_error ${LINENO}' ERR
  trap _o2_cleanup EXIT
  trap '_o2_on_signal INT' INT
  trap '_o2_on_signal TERM' TERM
  log_debug "Temp dir: ${TMP_DIR}"
}

# ------------------------------------------------------------------------------
# Utility
# ------------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
  [[ "${YES}" == "true" ]] && return 0
  local response
  read -r -p "$1 [y/N] " response
  case "${response}" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# kubectl wrapper respecting dry-run
k() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[dry-run] kubectl $*"
    return 0
  fi
  "${KUBECTL}" "$@"
}

wait_for() {
  local description="$1" timeout="$2"; shift 2
  local start elapsed
  start="$(date +%s)"
  while true; do
    if "$@" >/dev/null 2>&1; then
      log_debug "Condition met: ${description}"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= timeout )) && { log_error "Timed out: ${description}"; return 1; }
    sleep 2
  done
}

wait_for_job() {
  local job_name="$1" timeout_seconds="$2"
  local start elapsed
  start="$(date +%s)"
  while true; do
    local succeeded failed
    succeeded="$("${KUBECTL}" get job "${job_name}" -n "${O2_NAMESPACE}" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")"
    failed="$("${KUBECTL}" get job "${job_name}" -n "${O2_NAMESPACE}" \
      -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")"
    [[ "${succeeded:-0}" -ge 1 ]] && return 0
    [[ "${failed:-0}" -ge 1 ]] && return 1
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= timeout_seconds )) && return 2
    sleep 2
  done
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

preflight() {
  require_cmd "${KUBECTL}"
  require_cmd "${HELM}"
  "${KUBECTL}" cluster-info >/dev/null 2>&1 || die "kubectl cannot reach cluster"

  local chart_path="${O2_CHART_PATH:-infra/k8s/open-observe-minimal}"
  [[ -d "${chart_path}" ]] || die "Chart not found: ${chart_path}"
  [[ -f "${chart_path}/Chart.yaml" ]] || die "Invalid chart: missing Chart.yaml"
}

preflight_namespace() {
  "${KUBECTL}" get namespace "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || die "Namespace '${O2_NAMESPACE}' does not exist"
}

validate_config() {
  [[ "${O2_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "O2_RETENTION_DAYS must be a positive integer"
  [[ "${O2_BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "O2_BACKUP_RETENTION_DAYS must be a positive integer"
  [[ "${O2_CPU_REQUEST}" =~ ^[0-9]+m?$ ]] || die "Invalid O2_CPU_REQUEST: ${O2_CPU_REQUEST}"
  [[ "${O2_CPU_LIMIT}" =~ ^[0-9]+m?$ ]] || die "Invalid O2_CPU_LIMIT: ${O2_CPU_LIMIT}"
  [[ "${O2_MEMORY_REQUEST}" =~ ^[0-9]+(Mi|Gi)$ ]] || die "Invalid O2_MEMORY_REQUEST: ${O2_MEMORY_REQUEST}"
  [[ "${O2_MEMORY_LIMIT}" =~ ^[0-9]+(Mi|Gi)$ ]] || die "Invalid O2_MEMORY_LIMIT: ${O2_MEMORY_LIMIT}"
  [[ "${O2_PVC_SIZE}" =~ ^[0-9]+(Mi|Gi)$ ]] || die "Invalid O2_PVC_SIZE: ${O2_PVC_SIZE}"
}

# ------------------------------------------------------------------------------
# Discovery
# ------------------------------------------------------------------------------

discover_deployment() {
  local name
  name="$("${KUBECTL}" get deployment -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${name}" ]]; then
    for pattern in "${O2_RELEASE}-openobserve-router" "${O2_RELEASE}-router" "${O2_RELEASE}"; do
      if "${KUBECTL}" get deployment "${pattern}" -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
        name="${pattern}"; break
      fi
    done
  fi
  [[ -n "${name}" ]] || die "Could not discover OpenObserve deployment"
  DEPLOYMENT_NAME="${name}"
}

discover_pvc() {
  local name
  name="$("${KUBECTL}" get pvc -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${name}" ]]; then
    for pattern in "${O2_RELEASE}-data" "${O2_RELEASE}-openobserve-data" "openobserve-data"; do
      if "${KUBECTL}" get pvc "${pattern}" -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
        name="${pattern}"; break
      fi
    done
  fi
  [[ -n "${name}" ]] || die "Could not discover OpenObserve PVC"
  PVC_NAME="${name}"
}

# ------------------------------------------------------------------------------
# Secret validation (references only — never creates)
# ------------------------------------------------------------------------------

_o2_check_secret() {
  local name="$1" key="$2"
  "${KUBECTL}" get secret "${name}" -n "${O2_NAMESPACE}" >/dev/null 2>&1 || return 1
  if [[ -n "${key}" ]]; then
    local v
    v="$("${KUBECTL}" get secret "${name}" -n "${O2_NAMESPACE}" \
      -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
    [[ -n "${v}" ]] || return 1
  fi
  return 0
}

require_secrets() {
  _o2_check_secret "${O2_AUTH_SECRET}" "ZO_ROOT_USER_EMAIL" \
    || die "Secret '${O2_AUTH_SECRET}' missing key ZO_ROOT_USER_EMAIL"
  _o2_check_secret "${O2_AUTH_SECRET}" "ZO_ROOT_USER_PASSWORD" \
    || die "Secret '${O2_AUTH_SECRET}' missing key ZO_ROOT_USER_PASSWORD"
  _o2_check_secret "${O2_STORAGE_SECRET}" "account-name" \
    || die "Secret '${O2_STORAGE_SECRET}' missing key account-name"
  _o2_check_secret "${O2_STORAGE_SECRET}" "account-key" \
    || die "Secret '${O2_STORAGE_SECRET}' missing key account-key"
  log_debug "Required secrets validated"
}

# ------------------------------------------------------------------------------
# Scale helpers
# ------------------------------------------------------------------------------

scale_down() {
  discover_deployment
  local current
  current="$("${KUBECTL}" get deployment "${DEPLOYMENT_NAME}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}')"
  if [[ "${current}" == "0" ]]; then
    log_info "Deployment already scaled to 0"
    return 0
  fi
  log_info "Scaling ${DEPLOYMENT_NAME} to 0"
  SCALE_DOWN_IN_PROGRESS="true"
  k scale deployment/"${DEPLOYMENT_NAME}" -n "${O2_NAMESPACE}" --replicas=0
  wait_for "pods to terminate" "${O2_SCALE_TIMEOUT}" bash -c \
    "[[ \$(${KUBECTL} get pods -n ${O2_NAMESPACE} -l app.kubernetes.io/instance=${O2_RELEASE} --no-headers 2>/dev/null | wc -l) -eq 0 ]]"
}

scale_up() {
  log_info "Scaling ${DEPLOYMENT_NAME} to 1"
  k scale deployment/"${DEPLOYMENT_NAME}" -n "${O2_NAMESPACE}" --replicas=1
  "${KUBECTL}" rollout status deployment/"${DEPLOYMENT_NAME}" \
    -n "${O2_NAMESPACE}" --timeout="${O2_POD_READY_TIMEOUT}s"
  SCALE_DOWN_IN_PROGRESS="false"
}

# ------------------------------------------------------------------------------
# Common arg parsing helper
# ------------------------------------------------------------------------------

# Sets DRY_RUN, FORCE, YES. Prints help if --help seen. Returns non-common args
# by re-exporting to a global array REMAINING_ARGS.
o2_parse_common_flags() {
  REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN="true"; shift ;;
      --force)   FORCE="true"; YES="true"; shift ;;
      --yes|-y)  YES="true"; shift ;;
      *)         REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
}
