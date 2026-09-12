#!/usr/bin/env bash
# ==============================================================================
# otel-gateway-deploy.sh — Deploy the OTel Collector
#
# Chart at infra/k8s/otel-gateway. Produces one Deployment, one Service,
# one ConfigMap, one ServiceAccount, one ClusterRole, one ClusterRoleBinding.
#
# Authentication to OpenObserve uses the OPENOBSERVE_AUTH key in the
# openobserve-auth secret. This key contains base64(email:password)
#
# Usage: otel-gateway-deploy.sh [--dry-run] [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=open-observe/_lib.sh
source "${SCRIPT_DIR}/open-observe/_lib.sh"

O2_OTEL_CHART_PATH="${O2_OTEL_CHART_PATH:-infra/k8s/otel-gateway}"
O2_OTEL_RELEASE="${O2_OTEL_RELEASE:-otel-gateway}"

usage() {
  cat <<EOF
otel-gateway-deploy.sh — Deploy the OTel gateway

Usage: $(basename "$0") [options]

Options:
  --dry-run    Validate chart rendering; do not apply
  --help, -h   Show help

Environment (defaults shown):
  O2_OTEL_REPLICAS            1
  O2_OTEL_RELEASE             otel-gateway
  O2_OTEL_CHART_PATH          infra/k8s/otel-gateway
  O2_OTEL_TAG                 0.160.0
  O2_OTEL_DIGEST              sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6
  O2_OTEL_CPU_REQUEST         200m
  O2_OTEL_MEMORY_REQUEST      384Mi
  O2_OTEL_CPU_LIMIT           1500m
  O2_OTEL_MEMORY_LIMIT        1Gi
  O2_OPENOBSERVE_ENDPOINT     http://openobserve.openobserve.svc.cluster.local:5080/api/default
  O2_AUTH_SECRET              openobserve-auth  (key OPENOBSERVE_AUTH)
  O2_CLUSTER_NAME             autosre
  O2_NAMESPACE                openobserve

Production example:
  O2_OTEL_REPLICAS=2 bash scripts/common/otel-gateway-deploy.sh
EOF
}

render_values() {
  local out="$1"
  umask 0077

  cat > "${out}" <<EOF
# Rendered by otel-gateway-deploy.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# The chart has no values.yaml; this file is the sole source of truth.

replicaCount: ${O2_OTEL_REPLICAS:-1}

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

service:
  type: ClusterIP
  grpcPort: 4317
  httpPort: 4318

openobserve:
  endpoint: "${O2_OPENOBSERVE_ENDPOINT:-http://openobserve.openobserve.svc.cluster.local:5080/api/default}"
  tokenSecret:
    name: ${O2_AUTH_SECRET:-openobserve-auth}
    key: OPENOBSERVE_AUTH

cluster:
  name: "${O2_CLUSTER_NAME:-autosre}"

healthCheckEndpoints:
  - "/healthz"
  - "/readyz"
  - "/livez"
  - "/health"
  - "/ready"

resources:
  requests:
    cpu: "${O2_OTEL_CPU_REQUEST:-200m}"
    memory: "${O2_OTEL_MEMORY_REQUEST:-384Mi}"
  limits:
    cpu: "${O2_OTEL_CPU_LIMIT:-1500m}"
    memory: "${O2_OTEL_MEMORY_LIMIT:-1Gi}"

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
  startup:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 12
  readiness:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
  liveness:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 30

lifecycle:
  preStop:
    enabled: false

terminationGracePeriodSeconds: 30

priorityClassName:

podAnnotations:
  prometheus.io/scrape: "false"

podLabels: {}
nodeSelector: {}
tolerations: []

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otel-gateway
          topologyKey: kubernetes.io/hostname

extraEnv: []
extraEnvFrom: []
extraVolumes: []
extraVolumeMounts: []
EOF

  chmod 0600 "${out}"
  log_debug "Rendered values to ${out} (mode 0600)"
}

action_deploy() {
  log_info "Deploy (release=${O2_OTEL_RELEASE}, namespace=${O2_NAMESPACE}, chart=${O2_OTEL_CHART_PATH})"

  [[ -d "${O2_OTEL_CHART_PATH}" ]] || die "Chart not found: ${O2_OTEL_CHART_PATH}"
  [[ -f "${O2_OTEL_CHART_PATH}/Chart.yaml" ]] || die "Invalid chart: missing Chart.yaml in ${O2_OTEL_CHART_PATH}"

  if ! "${KUBECTL}" get namespace "${O2_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating namespace ${O2_NAMESPACE}"
    k create namespace "${O2_NAMESPACE}"
  fi

  _o2_check_secret "${O2_AUTH_SECRET:-openobserve-auth}" "OPENOBSERVE_AUTH" \
    || die "Secret '${O2_AUTH_SECRET:-openobserve-auth}' missing key 'OPENOBSERVE_AUTH'. \
Re-run scripts/local/local_secrets.sh to regenerate it."

  local values_file="${TMP_DIR}/values.yaml"
  render_values "${values_file}"

  local helm_args=(
    upgrade --install "${O2_OTEL_RELEASE}" "${O2_OTEL_CHART_PATH}"
    --namespace "${O2_NAMESPACE}"
    --create-namespace
    --values "${values_file}"
    --wait
    --timeout "${O2_HELM_TIMEOUT}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Would deploy release ${O2_OTEL_RELEASE} with replicas=${O2_OTEL_REPLICAS:-1}"
    local template_args=(
      template "${O2_OTEL_RELEASE}" "${O2_OTEL_CHART_PATH}"
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
  "${HELM}" "${helm_args[@]}"

  log_info "Waiting for rollout"
  "${KUBECTL}" rollout status deployment/"${O2_OTEL_RELEASE}" \
    -n "${O2_NAMESPACE}" --timeout="${O2_POD_READY_TIMEOUT}s"

  local pod running_image
  pod="$("${KUBECTL}" get pods -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_OTEL_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}')"
  running_image="$("${KUBECTL}" get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].image}')"

  log_info "Running image: ${running_image}"
  log_info "Deploy complete"
}

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
  log_info "otel-gateway-deploy.sh v${O2_VERSION} — run_id=${O2_RUN_ID}"

  preflight
  action_deploy

  log_info "Done"
}

main "$@"
