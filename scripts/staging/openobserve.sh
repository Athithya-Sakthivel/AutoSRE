#!/usr/bin/env bash
# ==============================================================================
# openobserve.sh — OpenObserve lifecycle for AutoSRE (non-Azure, no pull secret)
#
# Subcommands:
#   deploy     Deploy or upgrade OpenObserve (local disk storage).
#   render     Render values and helm output to stdout; keep work dir.
#   delete     Remove the Helm release; retain the PVC and data.
#   purge      Remove release and PVC (destructive).
#   status     Show current state.
#   verify     Health and configuration checks.
#   logs       Tail OpenObserve pod logs.
#   rollout    Restart the deployment.
#
# Design notes
# ------------
# - Local disk storage only. No S3, no Azure.
# - No image pull secrets (image is public on ghcr.io).
# - No StorageClass is created. The cluster default is detected and passed
#   to satisfy the chart's persistence schema.
# - Only Secret consumed is openobserve-auth, produced by ESO.
# - The release is created WITHOUT --wait or rollback flags. We wait with
#   kubectl rollout status so that on failure the pod, its events, and its
#   logs remain on the cluster for diagnosis.
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

O2_IMAGE_REGISTRY="${O2_IMAGE_REGISTRY:-ghcr.io}"
O2_IMAGE_REPOSITORY="${O2_IMAGE_REPOSITORY:-athithya-sakthivel/openobserve}"
O2_IMAGE_TAG="${O2_IMAGE_TAG:-v0.92.2}"
O2_IMAGE_DIGEST="${O2_IMAGE_DIGEST:-sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b}"
O2_ALLOW_IMAGE_CHANGE="${O2_ALLOW_IMAGE_CHANGE:-false}"

O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"

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

HELM_TIMEOUT="${HELM_TIMEOUT:-120s}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info()  { printf '%s [INFO]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Work directory: preserved on failure for inspection
# ------------------------------------------------------------------------------

WORK_DIR=""
PRESERVE_WORK_DIR=false

cleanup() {
  local rc=$?
  set +e
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

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

preflight_core() {
  require_cmd kubectl
  require_cmd helm
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
}

preflight_chart() {
  [[ -d "${O2_CHART_PATH}" ]] || die "Chart path does not exist: ${O2_CHART_PATH}"
  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] || die "Chart missing Chart.yaml"
}

# ------------------------------------------------------------------------------
# Namespace and secrets
# ------------------------------------------------------------------------------

ensure_namespace() {
  kubectl get namespace "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${O2_NAMESPACE}" >/dev/null
}

secret_has_key() {
  local secret="$1" key="$2" v
  kubectl get secret "${secret}" -n "${O2_NAMESPACE}" >/dev/null 2>&1 || return 1
  v="$(kubectl get secret "${secret}" -n "${O2_NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
  [[ -n "${v}" ]]
}

require_secrets() {
  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_EMAIL \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_EMAIL"
  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_PASSWORD \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_PASSWORD"
}

# ------------------------------------------------------------------------------
# Default StorageClass detection
# ------------------------------------------------------------------------------

detect_default_storage_class() {
  local sc
  sc="$(kubectl get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -n1)"
  if [[ -z "${sc}" ]]; then
    sc="$(kubectl get storageclass \
      -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | head -n1)"
  fi
  if [[ -z "${sc}" ]]; then
    log_warn "no default StorageClass found; falling back to 'standard'"
    sc="standard"
  fi
  printf '%s' "${sc}"
}

# ------------------------------------------------------------------------------
# Values rendering
# ------------------------------------------------------------------------------

render_values() {
  local out="$1" sc="$2"
  cat > "${out}" <<EOF
# Rendered by openobserve.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
replicaCount: 1

image:
  registry: "${O2_IMAGE_REGISTRY}"
  repository: "${O2_IMAGE_REPOSITORY}"
  tag: "${O2_IMAGE_TAG}"
  digest: "${O2_IMAGE_DIGEST}"
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
EOF
}

# ------------------------------------------------------------------------------
# Image change gate
# ------------------------------------------------------------------------------

check_image_change() {
  if ! kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi
  local current target
  current="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  target="${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}@${O2_IMAGE_DIGEST}"

  [[ "${current}" == "${target}" ]] && return 0

  if [[ "${O2_ALLOW_IMAGE_CHANGE}" == "true" ]]; then
    log_warn "image change approved: ${current} -> ${target}"
    return 0
  fi

  die "Image change detected: ${current} -> ${target}
Re-run with O2_ALLOW_IMAGE_CHANGE=true to proceed."
}

# ------------------------------------------------------------------------------
# Chart validation
# ------------------------------------------------------------------------------

validate_chart() {
  local values="$1"

  log_info "helm lint"
  if ! helm lint "${O2_CHART_PATH}" \
        --namespace "${O2_NAMESPACE}" \
        --values "${values}" \
        --strict; then
    PRESERVE_WORK_DIR=true
    log_error "helm lint failed"
    log_error "  values: ${values}"
    log_error "  reproduce: helm lint ${O2_CHART_PATH} --values ${values} --strict --debug"
    return 1
  fi

  log_info "helm template"
  if ! helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
        --namespace "${O2_NAMESPACE}" \
        --values "${values}" >/dev/null 2>"${WORK_DIR}/template.err"; then
    PRESERVE_WORK_DIR=true
    log_error "helm template failed; stderr follows"
    sed 's/^/  /' "${WORK_DIR}/template.err" >&2 || true
    return 1
  fi

  return 0
}

# ------------------------------------------------------------------------------
# Helm upgrade
#
# Deliberately without --wait, --atomic, --cleanup-on-fail, or
# --rollback-on-failure. Helm creates the resources and returns. We then wait
# explicitly with `kubectl rollout status`. On failure, the pod, its events,
# and its logs remain on the cluster and are captured by collect_diagnostics.
# ------------------------------------------------------------------------------

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
# Diagnostics on failed rollout
# ------------------------------------------------------------------------------

collect_diagnostics() {
  log_error "collecting diagnostics for release ${O2_RELEASE}"

  log_error "--- helm status ---"
  helm status "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>&1 | sed 's/^/  /' || true

  log_error "--- helm history ---"
  helm history "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>&1 | sed 's/^/  /' || true

  log_error "--- pods ---"
  kubectl -n "${O2_NAMESPACE}" get pods -o wide 2>&1 | sed 's/^/  /' || true

  log_error "--- deployment ---"
  kubectl -n "${O2_NAMESPACE}" get deployment "${O2_RELEASE}" -o wide 2>&1 \
    | sed 's/^/  /' || true

  log_error "--- deployment describe (tail 60) ---"
  kubectl -n "${O2_NAMESPACE}" describe deployment "${O2_RELEASE}" 2>&1 \
    | tail -n 60 | sed 's/^/  /' || true

  log_error "--- pvc ---"
  kubectl -n "${O2_NAMESPACE}" get pvc 2>&1 | sed 's/^/  /' || true

  log_error "--- events (last 30, sorted) ---"
  kubectl -n "${O2_NAMESPACE}" get events \
    --sort-by=.lastTimestamp 2>&1 | tail -n 30 | sed 's/^/  /' || true

  local pod
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    log_error "--- describe pod: ${pod} ---"
    kubectl -n "${O2_NAMESPACE}" describe pod "${pod}" 2>&1 \
      | tail -n 60 | sed 's/^/  /' || true
    log_error "--- logs: ${pod} (tail 100) ---"
    kubectl -n "${O2_NAMESPACE}" logs "${pod}" --tail=100 2>&1 \
      | sed 's/^/  /' || true
    log_error "--- previous: ${pod} (tail 100, if any) ---"
    kubectl -n "${O2_NAMESPACE}" logs "${pod}" --previous --tail=100 2>&1 \
      | sed 's/^/  /' || true
  done < <(kubectl -n "${O2_NAMESPACE}" get pods \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o name 2>/dev/null | sed 's|^pod/||')
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
  log_info "default StorageClass: ${sc}"

  local values="${WORK_DIR}/values.yaml"
  log_info "rendering values -> ${values}"
  render_values "${values}" "${sc}"

  validate_chart "${values}" || die "chart validation failed"

  log_info "applying release (helm timeout=${HELM_TIMEOUT})"
  if ! run_helm_upgrade "${values}"; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "helm upgrade failed"
  fi

  log_info "waiting for deployment rollout (timeout=${READY_TIMEOUT}s)"
  if ! kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
       --timeout="${READY_TIMEOUT}s"; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "deployment did not become ready"
  fi

  log_info "deploy complete"
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

  printf '\n===== values.yaml =====\n' >&2
  cat "${values}" >&2

  printf '\n===== helm template =====\n' >&2
  helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}" >&2
}

cmd_delete() {
  preflight_core
  log_info "removing Helm release ${O2_RELEASE} (PVC retained)"
  helm uninstall "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>/dev/null || true
  log_info "release removed; PVC ${O2_RELEASE}-data retained"
}

cmd_purge() {
  preflight_core
  read -r -p "This deletes the PVC and all OpenObserve data. Type 'yes' to confirm: " ans
  [[ "${ans}" == "yes" ]] || die "cancelled"
  cmd_delete
  kubectl delete pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" \
    --ignore-not-found >/dev/null 2>&1 || true
  log_info "purge complete"
}

cmd_status() {
  preflight_core
  echo "=== Helm release ==="
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

cmd_verify() {
  preflight_core
  ensure_namespace
  require_secrets

  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null \
    || die "deployment not ready"
  log_info "deployment OK"

  local pvc_phase
  pvc_phase="$(kubectl get pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.phase}')"
  [[ "${pvc_phase}" == "Bound" ]] || die "PVC phase ${pvc_phase}, expected Bound"
  log_info "PVC OK"

  local image
  image="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "${image}" == *"${O2_IMAGE_DIGEST}"* ]] || die "image not pinned: ${image}"
  log_info "image OK"

  local pod
  pod="$(kubectl get pods -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || die "no pod found for release ${O2_RELEASE}"

  local env_names
  env_names="$(kubectl get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}{"\n"}{end}')"
  [[ -n "${env_names}" ]] || die "pod has no env entries in spec"

  local required=(ZO_LOCAL_MODE ZO_LOCAL_MODE_STORAGE ZO_META_STORE
                  ZO_DATA_DIR ZO_DATA_DB_DIR ZO_DATA_WAL_DIR RUST_LOG)
  local k missing=0
  for k in "${required[@]}"; do
    grep -qx "${k}" <<< "${env_names}" \
      || { log_error "missing env: ${k}"; missing=1; }
  done
  [[ "${missing}" -eq 0 ]] || die "env check failed"
  log_info "env OK (${#required[@]} keys present)"

  if grep -qE '^AZURE_STORAGE_|^ZO_S3_' <<< "${env_names}"; then
    die "object-storage env vars present; verify secrets.storage is not set"
  fi
  log_info "no object-storage env vars present"

  local ready
  ready="$(kubectl get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].ready}')"
  [[ "${ready}" == "true" ]] || die "container not Ready"
  log_info "container Ready"

  if ! kubectl exec "${pod}" -n "${O2_NAMESPACE}" -- \
       wget -q -O- --timeout=5 http://localhost:5080/healthz >/dev/null 2>&1; then
    die "/healthz check failed"
  fi
  log_info "health OK"

  log_info "all checks passed"
}

cmd_logs() {
  preflight_core
  kubectl logs -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    --tail=200 -f "$@"
}

cmd_rollout() {
  preflight_core
  kubectl rollout restart deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}"
  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s"
  log_info "rollout complete"
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
openobserve.sh — OpenObserve lifecycle for AutoSRE (non-Azure)

Usage: $(basename "$0") <command> [args]

Commands:
  deploy            Deploy or upgrade OpenObserve (local disk storage)
  render            Render values and helm output to stdout; keep work dir
  delete            Remove the Helm release; retain the PVC and data
  purge             Remove release and PVC (destructive)
  status            Show current state
  verify            Health and configuration checks
  logs [args]       Tail logs (extra args passed to kubectl logs)
  rollout           Restart the deployment
  help              Show this help

Environment overrides:
  O2_NAMESPACE              default: openobserve
  O2_RELEASE                default: openobserve
  O2_CHART_PATH             default: infra/k8s/open-observe-minimal
  O2_IMAGE_DIGEST           default: v0.92.2 multi-arch manifest list digest
  O2_ALLOW_IMAGE_CHANGE     default: false (required for image upgrade)
  O2_PVC_SIZE               default: 20Gi
  HELM_TIMEOUT              default: 120s
  READY_TIMEOUT             default: 180

On failure the work directory is preserved and the deployment, pod, and events
are printed before the script exits.

Examples:
  ./openobserve.sh deploy
  ./openobserve.sh render
  ./openobserve.sh verify
  O2_ALLOW_IMAGE_CHANGE=true ./openobserve.sh deploy
EOF
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local cmd="$1"; shift

  case "${cmd}" in
    deploy)  cmd_deploy ;;
    render)  cmd_render ;;
    delete)  cmd_delete ;;
    purge)   cmd_purge ;;
    status)  cmd_status ;;
    verify)  cmd_verify ;;
    logs)    cmd_logs "$@" ;;
    rollout) cmd_rollout ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
