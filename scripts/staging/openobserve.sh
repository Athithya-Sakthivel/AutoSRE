#!/usr/bin/env bash
# ==============================================================================
# openobserve.sh — OpenObserve lifecycle for AutoSRE
#
# Subcommands:
#   deploy     Deploy/upgrade OpenObserve, then ensure required streams exist.
#   render     Render values and Helm output; keep work directory.
#   delete     Remove Helm release; retain PVC and data.
#   purge      Remove Helm release and PVC (destructive, requires approval).
#   status     Show current state.
#   verify     Health, auth, SSRF, and required-stream checks.
#   logs       Tail OpenObserve pod logs.
#   rollout    Restart the deployment.
#
# Design
# ------
# - Local disk storage only. Single node is sufficient for agent telemetry.
# - No S3/Azure configuration.
# - No image pull secret.
# - openobserve-auth Secret must already exist.
# - OpenObserve SSRF guard is skipped by default so alert destinations can
#   target in-cluster Kubernetes services.
# - REQUIRED STREAMS ARE MANAGED HERE, NOT BY TERRAFORM.
#
# One-shot staging flow:
#
#   bash scripts/staging/openobserve.sh deploy
#   bash infra/terraform/run.sh --apply
#
# `deploy` guarantees these streams exist before Terraform creates alerts:
#
#   app_logs        logs
#   postgres_logs   logs
#   valkey_logs     logs
#   app_metrics     metrics
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

# Correct OpenObserve SSRF setting.
O2_SKIP_SSRF_CHECKS="${O2_SKIP_SSRF_CHECKS:-true}"

# Local verification/stream-management port.
O2_VERIFY_LOCAL_PORT="${O2_VERIFY_LOCAL_PORT:-15080}"

# How long to wait for OpenObserve to clear a stale "being deleted" stream.
O2_STREAM_DELETE_TIMEOUT="${O2_STREAM_DELETE_TIMEOUT:-180}"
O2_STREAM_RETRY_INTERVAL="${O2_STREAM_RETRY_INTERVAL:-5}"

HELM_TIMEOUT="${HELM_TIMEOUT:-120s}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"

# ------------------------------------------------------------------------------
# Required streams
# ------------------------------------------------------------------------------

REQUIRED_STREAMS=(
  "app_logs:logs"
  "postgres_logs:logs"
  "valkey_logs:logs"
  "app_metrics:metrics"
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

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the cluster"
}

preflight_chart() {
  [[ -d "${O2_CHART_PATH}" ]] \
    || die "Chart path does not exist: ${O2_CHART_PATH}"

  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] \
    || die "Chart missing Chart.yaml"
}

# ------------------------------------------------------------------------------
# Namespace and secrets
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
    >/dev/null 2>&1 || return 1

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
      2>/dev/null \
      | head -n1
  )"

  if [[ -z "${sc}" ]]; then
    sc="$(
      kubectl get storageclass \
        -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null \
        | head -n1
    )"
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
  local out="$1"
  local sc="$2"

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

  # Required for the local Kind alert destination:
  # autosre-agent.sre.svc.cluster.local
  ZO_SKIP_SSRF_CHECKS: "${O2_SKIP_SSRF_CHECKS}"

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
# Image change protection
# ------------------------------------------------------------------------------

check_image_change() {
  if ! kubectl get deployment "${O2_RELEASE}" \
      -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi

  local current
  local target

  current="$(
    kubectl get deployment "${O2_RELEASE}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )"

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
    return 1
  fi

  log_info "helm template"

  if ! helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
      --namespace "${O2_NAMESPACE}" \
      --values "${values}" \
      >/dev/null \
      2>"${WORK_DIR}/template.err"; then

    PRESERVE_WORK_DIR=true

    log_error "helm template failed; stderr follows"
    sed 's/^/  /' "${WORK_DIR}/template.err" >&2 || true

    return 1
  fi
}

# ------------------------------------------------------------------------------
# Helm
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
# Pod / service endpoint
# ------------------------------------------------------------------------------

wait_for_pod() {
  kubectl rollout status \
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s"
}

# ------------------------------------------------------------------------------
# OpenObserve local API tunnel
# ------------------------------------------------------------------------------

O2_PF_PID=""

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

  while (( elapsed < 20 )); do
    if ! kill -0 "${O2_PF_PID}" >/dev/null 2>&1; then
      log_error "port-forward exited unexpectedly"
      sed 's/^/  /' "${WORK_DIR}/port-forward.log" >&2 || true
      return 1
    fi

    if curl -sS \
      "http://127.0.0.1:${local_port}/healthz" \
      >/dev/null 2>&1; then

      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_error "OpenObserve port-forward did not become ready"
  sed 's/^/  /' "${WORK_DIR}/port-forward.log" >&2 || true

  return 1
}

# ------------------------------------------------------------------------------
# OpenObserve API helpers
# ------------------------------------------------------------------------------

O2_API_BASE=""
O2_API_USER=""
O2_API_PASSWORD=""

init_o2_api_credentials() {
  O2_API_BASE="http://127.0.0.1:${O2_VERIFY_LOCAL_PORT}/api/${O2_ORGANIZATION}"

  O2_API_USER="$(read_secret_value ZO_ROOT_USER_EMAIL)"
  O2_API_PASSWORD="$(read_secret_value ZO_ROOT_USER_PASSWORD)"

  [[ -n "${O2_API_USER}" ]] \
    || die "OpenObserve root email resolved to empty value"

  [[ -n "${O2_API_PASSWORD}" ]] \
    || die "OpenObserve root password resolved to empty value"
}

o2_curl() {
  curl \
    -sS \
    --fail-with-body \
    --retry 2 \
    --connect-timeout 5 \
    --max-time 20 \
    -u "${O2_API_USER}:${O2_API_PASSWORD}" \
    "$@"
}

o2_stream_exists() {
  local stream="$1"
  local type="$2"

  local json

  json="$(
    o2_curl \
      "${O2_API_BASE}/streams?fetchSchema=false&type=${type}" \
      2>/dev/null \
      || true
  )"

  [[ -n "${json}" ]] || return 1

  jq -e \
    --arg name "${stream}" \
    '.list // [] | any(.[]; .name == $name)' \
    <<<"${json}" \
    >/dev/null 2>&1
}

o2_stream_names() {
  local type="$1"

  o2_curl \
    "${O2_API_BASE}/streams?fetchSchema=false&type=${type}" \
    | jq -r '.list[]?.name'
}

# ------------------------------------------------------------------------------
# Stream creation
# ------------------------------------------------------------------------------

create_stream_once() {
  local stream="$1"
  local type="$2"

  local url
  local response
  local status

  url="${O2_API_BASE}/streams/${stream}?type=${type}"

  # OpenObserve's stream-create endpoint accepts a stream definition with
  # fields/settings. We deliberately leave both empty: these alert streams
  # only need to exist; schemas can be inferred later from ingestion.
  response="$(
    curl \
      -sS \
      -o "${WORK_DIR}/stream-create-response.json" \
      -w '%{http_code}' \
      -u "${O2_API_USER}:${O2_API_PASSWORD}" \
      -X POST \
      -H 'Content-Type: application/json' \
      "${url}" \
      --data '{"fields":[],"settings":{}}' \
      2>/dev/null || true
  )"

  status="${response}"

  case "${status}" in
    200|201)
      log_info "stream created: ${stream} (${type})"
      return 0
      ;;

    409)
      if o2_stream_exists "${stream}" "${type}"; then
        log_info "stream already exists: ${stream} (${type})"
        return 0
      fi
      ;;

    400)
      if grep -qi 'already exists' \
        "${WORK_DIR}/stream-create-response.json" 2>/dev/null; then

        if o2_stream_exists "${stream}" "${type}"; then
          log_info "stream already exists: ${stream} (${type})"
          return 0
        fi
      fi

      if grep -qi 'being deleted' \
        "${WORK_DIR}/stream-create-response.json" 2>/dev/null; then

        return 2
      fi
      ;;

    404)
      log_error "OpenObserve stream API returned 404 for ${stream}"
      ;;

    401|403)
      log_error "OpenObserve rejected stream creation credentials for ${stream}"
      ;;

    *)
      log_error "unexpected HTTP ${status} creating stream ${stream}"
      ;;
  esac

  if [[ -s "${WORK_DIR}/stream-create-response.json" ]]; then
    sed 's/^/  /' \
      "${WORK_DIR}/stream-create-response.json" >&2 || true
  fi

  return 1
}

ensure_one_stream() {
  local stream="$1"
  local type="$2"

  if o2_stream_exists "${stream}" "${type}"; then
    log_info "stream OK: ${stream} (${type})"
    return 0
  fi

  local elapsed=0
  local rc

  while (( elapsed <= O2_STREAM_DELETE_TIMEOUT )); do
    if o2_stream_exists "${stream}" "${type}"; then
      log_info "stream OK: ${stream} (${type})"
      return 0
    fi

    set +e
    create_stream_once "${stream}" "${type}"
    rc=$?
    set -e

    if (( rc == 0 )); then
      return 0
    fi

    if (( rc == 2 )); then
      log_warn \
        "stream ${stream} is marked for deletion; waiting ${O2_STREAM_RETRY_INTERVAL}s before retry"

      sleep "${O2_STREAM_RETRY_INTERVAL}"
      elapsed=$((elapsed + O2_STREAM_RETRY_INTERVAL))
      continue
    fi

    return 1
  done

  die "stream ${stream} is still marked 'being deleted' after ${O2_STREAM_DELETE_TIMEOUT}s"
}

ensure_required_streams() {
  log_info "ensuring required OpenObserve streams"

  start_o2_port_forward \
    || die "could not establish OpenObserve port-forward"

  init_o2_api_credentials

  local item
  local stream
  local type

  for item in "${REQUIRED_STREAMS[@]}"; do
    stream="${item%%:*}"
    type="${item##*:}"

    ensure_one_stream "${stream}" "${type}" \
      || die "failed to ensure stream ${stream} (${type})"
  done

  log_info "all required OpenObserve streams are ready"
}

# ------------------------------------------------------------------------------
# Health / configuration verification
# ------------------------------------------------------------------------------

probe_healthz() {
  local local_port="${O2_VERIFY_LOCAL_PORT}"

  curl \
    -sf \
    "http://127.0.0.1:${local_port}/healthz" \
    >/dev/null
}

verify_ssrf_config() {
  local pod

  pod="$(
    kubectl get pods \
      -n "${O2_NAMESPACE}" \
      -l "app.kubernetes.io/instance=${O2_RELEASE}" \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  [[ -n "${pod}" ]] \
    || die "no OpenObserve pod found"

  local skip_ssrf

  skip_ssrf="$(
    kubectl get pod "${pod}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
      | awk -F= '$1=="ZO_SKIP_SSRF_CHECKS" {print $2}'
  )"

  [[ "${skip_ssrf}" == "true" ]] \
    || die "ZO_SKIP_SSRF_CHECKS is '${skip_ssrf}', expected 'true'"

  log_info "SSRF guard disabled OK"
}

verify_required_streams() {
  init_o2_api_credentials

  local item
  local stream
  local type

  for item in "${REQUIRED_STREAMS[@]}"; do
    stream="${item%%:*}"
    type="${item##*:}"

    if o2_stream_exists "${stream}" "${type}"; then
      log_info "stream OK: ${stream} (${type})"
    else
      die "required stream missing: ${stream} (${type})"
    fi
  done
}

# ------------------------------------------------------------------------------
# Diagnostics
# ------------------------------------------------------------------------------

collect_diagnostics() {
  log_error "collecting diagnostics for release ${O2_RELEASE}"

  log_error "--- helm status ---"
  helm status "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>&1 | sed 's/^/  /' || true

  log_error "--- pods ---"
  kubectl -n "${O2_NAMESPACE}" \
    get pods -o wide \
    2>&1 | sed 's/^/  /' || true

  log_error "--- deployment ---"
  kubectl -n "${O2_NAMESPACE}" \
    get deployment "${O2_RELEASE}" -o wide \
    2>&1 | sed 's/^/  /' || true

  log_error "--- pvc ---"
  kubectl -n "${O2_NAMESPACE}" \
    get pvc \
    2>&1 | sed 's/^/  /' || true

  log_error "--- events ---"
  kubectl -n "${O2_NAMESPACE}" \
    get events --sort-by=.lastTimestamp \
    2>&1 | tail -n 30 | sed 's/^/  /' || true
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

  validate_chart "${values}" \
    || die "chart validation failed"

  log_info "applying OpenObserve release"

  if ! run_helm_upgrade "${values}"; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "helm upgrade failed"
  fi

  log_info \
    "waiting for deployment rollout (timeout=${READY_TIMEOUT}s)"

  if ! wait_for_pod; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "deployment did not become ready"
  fi

  log_info "deploy complete"

  # The critical addition:
  # create/adopt streams before Terraform creates alerts.
  ensure_required_streams

  stop_o2_port_forward

  log_info "OpenObserve deployment and stream reconciliation complete"
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
    --values "${values}" \
    >&2
}

cmd_delete() {
  preflight_core

  log_info \
    "removing Helm release ${O2_RELEASE} (PVC retained)"

  helm uninstall "${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    2>/dev/null || true

  log_info \
    "release removed; PVC ${O2_RELEASE}-data retained"
}

cmd_purge() {
  preflight_core

  read -r -p \
    "This deletes the PVC and all OpenObserve data. Type 'yes' to confirm: " \
    ans

  [[ "${ans}" == "yes" ]] \
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
  helm list -n "${O2_NAMESPACE}" 2>/dev/null || true

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
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null \
    || die "deployment not ready"

  log_info "deployment OK"

  local pvc_phase

  pvc_phase="$(
    kubectl get pvc \
      "${O2_RELEASE}-data" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.status.phase}' \
      2>/dev/null || true
  )"

  [[ "${pvc_phase}" == "Bound" ]] \
    || die "PVC phase '${pvc_phase}', expected Bound"

  log_info "PVC OK"

  local image

  image="$(
    kubectl get deployment "${O2_RELEASE}" \
      -n "${O2_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )"

  [[ "${image}" == *"${O2_IMAGE_DIGEST}"* ]] \
    || die "image is not pinned to expected digest: ${image}"

  log_info "image OK"

  verify_ssrf_config

  start_o2_port_forward \
    || die "could not establish OpenObserve port-forward"

  init_o2_api_credentials

  probe_healthz \
    || die "/healthz check failed"

  log_info "health OK"

  verify_required_streams

  stop_o2_port_forward

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
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}"

  kubectl rollout status \
    deployment/"${O2_RELEASE}" \
    -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s"

  log_info "rollout complete"

  # Keep stream existence guaranteed after restart as well.
  init_work_dir
  ensure_required_streams
  stop_o2_port_forward
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
openobserve.sh — OpenObserve lifecycle for AutoSRE

Usage:
  $(basename "$0") <command>

Commands:
  deploy
      Deploy/upgrade OpenObserve and ensure all required streams exist.

  render
      Render Helm values and template output.

  delete
      Remove the Helm release but retain the PVC.

  purge
      Remove the Helm release and PVC.

  status
      Show Helm/deployment/pod/PVC/service state.

  verify
      Verify deployment, image, SSRF configuration, health, and streams.

  logs [args]
      Tail OpenObserve logs.

  rollout
      Restart OpenObserve and re-ensure required streams.

Required streams:
  app_logs        logs
  postgres_logs   logs
  valkey_logs     logs
  app_metrics     metrics

Environment overrides:
  O2_NAMESPACE
      default: openobserve

  O2_RELEASE
      default: openobserve

  O2_ORGANIZATION
      default: default

  O2_AUTH_SECRET
      default: openobserve-auth

  O2_SKIP_SSRF_CHECKS
      default: true

  O2_VERIFY_LOCAL_PORT
      default: 15080

  O2_STREAM_DELETE_TIMEOUT
      default: 180 seconds

  O2_STREAM_RETRY_INTERVAL
      default: 5 seconds

  HELM_TIMEOUT
      default: 120s

  READY_TIMEOUT
      default: 180s
EOF
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] \
    || {
      usage
      exit 2
    }

  local cmd="$1"

  case "${cmd}" in
    deploy)
      cmd_deploy
      ;;

    render)
      cmd_render
      ;;

    delete)
      cmd_delete
      ;;

    purge)
      cmd_purge
      ;;

    status)
      cmd_status
      ;;

    verify)
      cmd_verify
      ;;

    logs)
      shift
      cmd_logs "$@"
      ;;

    rollout)
      cmd_rollout
      ;;

    help|--help|-h)
      usage
      ;;

    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
