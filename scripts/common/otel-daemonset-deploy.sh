#!/usr/bin/env bash
# ==============================================================================
# otel-daemonset-deploy.sh — Deploy the OTel Collector DaemonSet (self-contained)
#
# Chart at infra/k8s/otel-daemonset. Produces one DaemonSet, one ConfigMap,
# one ServiceAccount, one ClusterRole, one ClusterRoleBinding.
# No Service (DaemonSet pods push to OpenObserve; they are not load-balanced).
#
# Usage: otel-daemonset-deploy.sh [--dry-run] [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------

O2_VERSION="1.0.0"
O2_DAEMONSET_CHART_PATH="${O2_DAEMONSET_CHART_PATH:-infra/k8s/otel-daemonset}"
O2_DAEMONSET_RELEASE="${O2_DAEMONSET_RELEASE:-otel-daemonset}"
O2_NAMESPACE="${O2_NAMESPACE:-openobserve}"
O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"
O2_HELM_TIMEOUT="${O2_HELM_TIMEOUT:-600s}"
O2_POD_READY_TIMEOUT="${O2_POD_READY_TIMEOUT:-300s}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"

DRY_RUN=false
O2_RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
TMP_DIR=""

# ------------------------------------------------------------------------------
# Logging + runtime helpers (previously from _lib.sh)
# ------------------------------------------------------------------------------

log_info()  { printf '%s [INFO]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_debug() { [[ "${O2_DEBUG:-false}" == "true" ]] && \
              printf '%s [DEBUG] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2 || true; }
die()       { log_error "$*"; exit 1; }

cleanup_tmpdir() {
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf -- "${TMP_DIR}" || true
}
trap cleanup_tmpdir EXIT
trap 'exit 130' INT TERM

init_runtime() {
  TMP_DIR="$(mktemp -d -t otel-daemonset.XXXXXX)"
  chmod 0700 "${TMP_DIR}"
}

preflight() {
  command -v "${KUBECTL}" >/dev/null 2>&1 || die "kubectl not found"
  command -v "${HELM}"    >/dev/null 2>&1 || die "helm not found"
  "${KUBECTL}" cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
  [[ -d "${O2_DAEMONSET_CHART_PATH}" ]] || die "Chart not found: ${O2_DAEMONSET_CHART_PATH}"
  [[ -f "${O2_DAEMONSET_CHART_PATH}/Chart.yaml" ]] || die "Invalid chart: missing Chart.yaml"
}

o2_parse_common_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run)  DRY_RUN=true ;;
      "")         ;;
      *)          die "Unknown argument: ${arg}" ;;
    esac
  done
}

_o2_check_secret() {
  local secret="$1" key="$2"
  "${KUBECTL}" get secret "${secret}" -n "${O2_NAMESPACE}" >/dev/null 2>&1 || return 1
  local v
  v="$("${KUBECTL}" get secret "${secret}" -n "${O2_NAMESPACE}" \
        -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
  [[ -n "${v}" ]]
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
otel-daemonset-deploy.sh — Deploy the OTel Collector DaemonSet

Usage: $(basename "$0") [options]

Options:
  --dry-run    Validate chart rendering; do not apply
  --help, -h   Show help

Environment (defaults shown):
  O2_DAEMONSET_RELEASE        otel-daemonset
  O2_DAEMONSET_CHART_PATH     infra/k8s/otel-daemonset
  O2_OTEL_TAG                 0.160.0
  O2_OTEL_DIGEST              sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6
  O2_OTEL_COLLECTION_INTERVAL 60s
  O2_DAEMONSET_CPU_REQUEST    50m
  O2_DAEMONSET_MEMORY_REQUEST 128Mi
  O2_DAEMONSET_CPU_LIMIT      300m
  O2_DAEMONSET_MEMORY_LIMIT   256Mi
  O2_OPENOBSERVE_ENDPOINT     http://openobserve.openobserve.svc.cluster.local:5080/api/default
  O2_AUTH_SECRET              openobserve-auth  (key OPENOBSERVE_AUTH)
  O2_CLUSTER_NAME             autosre
  O2_NAMESPACE                openobserve
EOF
}

# ------------------------------------------------------------------------------
# Values rendering
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  umask 0077

  cat > "${out}" <<EOF
# Rendered by otel-daemonset-deploy.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# The chart has no values.yaml; this file is the sole source of truth.

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "${O2_OTEL_TAG:-0.160.0}"
  digest: "${O2_OTEL_DIGEST:-sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6}"
  pullPolicy: IfNotPresent

imagePullSecrets: []

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: true

rbac:
  create: true

openobserve:
  endpoint: "${O2_OPENOBSERVE_ENDPOINT:-http://openobserve.openobserve.svc.cluster.local:5080/api/default}"
  tokenSecret:
    name: ${O2_AUTH_SECRET}
    key: OPENOBSERVE_AUTH

cluster:
  name: "${O2_CLUSTER_NAME:-autosre}"

# 60s halves the TLS handshake frequency versus 30s.
# Issue #45725: kubelet_stats does not reuse connections between scrapes.
collectionInterval: "${O2_OTEL_COLLECTION_INTERVAL:-60s}"

resources:
  requests:
    cpu: "${O2_DAEMONSET_CPU_REQUEST:-50m}"
    memory: "${O2_DAEMONSET_MEMORY_REQUEST:-128Mi}"
  limits:
    cpu: "${O2_DAEMONSET_CPU_LIMIT:-300m}"
    memory: "${O2_DAEMONSET_MEMORY_LIMIT:-256Mi}"

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65534
  capabilities:
    drop: ["ALL"]

probes:
  readiness:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
  liveness:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 30

terminationGracePeriodSeconds: 30

tolerations:
  - operator: Exists
    effect: NoSchedule

nodeSelector: {}

podAnnotations: {}
podLabels: {}
extraEnv: []
extraVolumes: []
extraVolumeMounts: []
EOF

  chmod 0600 "${out}"
  log_debug "Rendered values to ${out} (mode 0600)"
}

# ------------------------------------------------------------------------------
# Deploy
# ------------------------------------------------------------------------------

action_deploy() {
  log_info "Deploy (release=${O2_DAEMONSET_RELEASE}, namespace=${O2_NAMESPACE}, chart=${O2_DAEMONSET_CHART_PATH})"

  if ! "${KUBECTL}" get namespace "${O2_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating namespace ${O2_NAMESPACE}"
    "${KUBECTL}" create namespace "${O2_NAMESPACE}" >/dev/null
  fi

  _o2_check_secret "${O2_AUTH_SECRET}" "OPENOBSERVE_AUTH" \
    || die "Secret '${O2_AUTH_SECRET}' missing key 'OPENOBSERVE_AUTH'. \
Run scripts/common/openobserve.sh deploy first, or re-run ESO sync."

  local values_file="${TMP_DIR}/values.yaml"
  render_values "${values_file}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Would deploy release ${O2_DAEMONSET_RELEASE} to namespace ${O2_NAMESPACE}"
    local template_args=(
      template "${O2_DAEMONSET_RELEASE}" "${O2_DAEMONSET_CHART_PATH}"
      --namespace "${O2_NAMESPACE}"
      --values "${values_file}"
    )
    if "${HELM}" "${template_args[@]}" >/dev/null 2>&1; then
      local resource_count
      resource_count="$("${HELM}" "${template_args[@]}" 2>/dev/null | grep -c '^kind:' || true)"
      log_info "Chart renders successfully (${resource_count} resources; nothing applied)"
    else
      log_error "Chart failed to render. Re-running with stderr visible:"
      "${HELM}" "${template_args[@]}" >/dev/null
      die "Render failed"
    fi
    return 0
  fi

  log_info "Running helm upgrade --install"
  "${HELM}" upgrade --install "${O2_DAEMONSET_RELEASE}" "${O2_DAEMONSET_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --create-namespace \
    --values "${values_file}" \
    --wait \
    --timeout "${O2_HELM_TIMEOUT}"

  log_info "Waiting for DaemonSet rollout"
  "${KUBECTL}" rollout status daemonset/"${O2_DAEMONSET_RELEASE}-daemonset" \
    -n "${O2_NAMESPACE}" --timeout="${O2_POD_READY_TIMEOUT}" 2>/dev/null \
    || "${KUBECTL}" rollout status daemonset/"${O2_DAEMONSET_RELEASE}" \
      -n "${O2_NAMESPACE}" --timeout="${O2_POD_READY_TIMEOUT}"

  local ds_name node_count ready_count running_image
  ds_name="$("${KUBECTL}" get daemonset -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_DAEMONSET_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}')"

  node_count="$("${KUBECTL}" get daemonset "${ds_name}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.desiredNumberScheduled}')"
  ready_count="$("${KUBECTL}" get daemonset "${ds_name}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.numberReady}')"
  running_image="$("${KUBECTL}" get daemonset "${ds_name}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"

  log_info "DaemonSet: ${ds_name}"
  log_info "Coverage: ${ready_count}/${node_count} nodes ready"
  log_info "Running image: ${running_image}"
  log_info "Deploy complete"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
  local filtered=()
  for arg in "$@"; do
    case "${arg}" in
      --help|-h) usage; exit 0 ;;
      *)         filtered+=("${arg}") ;;
    esac
  done

  o2_parse_common_flags "${filtered[@]}"

  init_runtime
  log_info "otel-daemonset-deploy.sh v${O2_VERSION} — run_id=${O2_RUN_ID}"

  preflight
  action_deploy

  log_info "Done"
}

main "$@"
