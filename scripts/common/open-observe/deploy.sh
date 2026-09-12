#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — Deploy single-node OpenObserve via the vendored minimal chart
#
# Chart at O2_CHART_PATH. Produces one Deployment, one Service, one PVC,
# one ServiceAccount, one NetworkPolicy. The chart has no values.yaml.
#
# All values are rendered at runtime into ${TMP_DIR}/values.yaml (mode 0600)
# and deleted on exit. Secrets are referenced by name only:
#   - openobserve-auth    (ZO_ROOT_USER_EMAIL, ZO_ROOT_USER_PASSWORD)
#   - openobserve-storage (account-name, account-key)
#
# Usage: deploy.sh [--dry-run] [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
deploy.sh — Deploy single-node OpenObserve

Usage: $(basename "$0") [options]

Options:
  --dry-run    Validate chart rendering; do not apply
  --help, -h   Show help

Environment (defaults shown):
  O2_NAMESPACE           openobserve
  O2_RELEASE             openobserve
  O2_CHART_PATH          infra/k8s/open-observe-minimal
  O2_AUTH_SECRET         openobserve-auth
  O2_STORAGE_SECRET      openobserve-storage
  O2_IMAGE_REGISTRY      ghcr.io
  O2_IMAGE_REPOSITORY    athithya-sakthivel/openobserve
  O2_IMAGE_TAG           v0.92.2
  O2_IMAGE_DIGEST        sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b
  O2_IMAGE_PULL_SECRET   ghcr-pull-secret
  O2_S3_PROVIDER         azure
  O2_S3_BUCKET           autosre-telemetry
  O2_RETENTION_DAYS      30
  O2_CPU_REQUEST         100m
  O2_MEMORY_REQUEST      256Mi
  O2_CPU_LIMIT           500m
  O2_MEMORY_LIMIT        512Mi
  O2_PVC_SIZE            5Gi
  O2_STORAGE_CLASS       (empty — cluster default)
  O2_LOG_LEVEL           info
EOF
}

# ------------------------------------------------------------------------------
# Render complete values.yaml to ${TMP_DIR}
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  umask 0077

  cat > "${out}" <<EOF
# Rendered by deploy.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# The chart has no values.yaml; this file is the sole source of truth.

replicaCount: 1

image:
  registry: "${O2_IMAGE_REGISTRY:-ghcr.io}"
  repository: "${O2_IMAGE_REPOSITORY:-athithya-sakthivel/openobserve}"
  tag: "${O2_IMAGE_TAG:-v0.92.2}"
  digest: "${O2_IMAGE_DIGEST:-sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b}"
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: ${O2_IMAGE_PULL_SECRET:-ghcr-pull-secret}

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: false

secrets:
  auth: ${O2_AUTH_SECRET:-openobserve-auth}
  storage: ${O2_STORAGE_SECRET:-openobserve-storage}

config:
  ZO_LOCAL_MODE: "true"
  ZO_LOCAL_MODE_STORAGE: "s3"
  ZO_META_STORE: "sqlite"
  ZO_S3_PROVIDER: "${O2_S3_PROVIDER:-azure}"
  ZO_S3_BUCKET_NAME: "${O2_S3_BUCKET:-autosre-telemetry}"
  ZO_COMPACT_DATA_RETENTION_DAYS: "${O2_RETENTION_DAYS:-30}"
  ZO_LOG_LEVEL: "${O2_LOG_LEVEL:-info}"
  ZO_TELEMETRY: "false"

persistence:
  enabled: true
  size: "${O2_PVC_SIZE:-5Gi}"
  accessMode: ReadWriteOnce
  storageClass: "${O2_STORAGE_CLASS:-}"

service:
  type: ClusterIP
  port: 5080

resources:
  requests:
    cpu: "${O2_CPU_REQUEST:-100m}"
    memory: "${O2_MEMORY_REQUEST:-256Mi}"
  limits:
    cpu: "${O2_CPU_LIMIT:-500m}"
    memory: "${O2_MEMORY_LIMIT:-512Mi}"

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
    timeoutSeconds: 3
    failureThreshold: 30
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
    enabled: false

terminationGracePeriodSeconds: 60

priorityClassName: ""

networkPolicy:
  enabled: true
  ingress:
    allowSameNamespace: true
    additionalFrom: []
  egress:
    allowDNS: true
    allowAzureBlob: true
    allowKubeAPI: false
    additionalTo: []

podAnnotations: {}
podLabels: {}
nodeSelector: {}
tolerations: []
affinity: {}
extraEnv: []
extraEnvFrom: []
extraVolumes: []
extraVolumeMounts: []
extraInitContainers: []
extraContainers: []
EOF

  chmod 0600 "${out}"
  log_debug "Rendered values to ${out} (mode 0600)"
}

# ------------------------------------------------------------------------------
# Deploy
# ------------------------------------------------------------------------------

action_deploy() {
  log_info "Deploy (release=${O2_RELEASE}, namespace=${O2_NAMESPACE}, chart=${O2_CHART_PATH})"

  [[ -d "${O2_CHART_PATH}" ]] || die "Chart not found: ${O2_CHART_PATH}"
  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] || die "Invalid chart: missing Chart.yaml in ${O2_CHART_PATH}"

  if ! "${KUBECTL}" get namespace "${O2_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Creating namespace ${O2_NAMESPACE}"
    k create namespace "${O2_NAMESPACE}"
  fi

  require_secrets

  local values_file="${TMP_DIR}/values.yaml"
  render_values "${values_file}"

  local helm_args=(
    upgrade --install "${O2_RELEASE}" "${O2_CHART_PATH}"
    --namespace "${O2_NAMESPACE}"
    --create-namespace
    --values "${values_file}"
    --wait
    --timeout "${O2_HELM_TIMEOUT}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Would deploy release ${O2_RELEASE} to namespace ${O2_NAMESPACE}"
    local template_args=(
      template "${O2_RELEASE}" "${O2_CHART_PATH}"
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

  discover_deployment
  "${KUBECTL}" rollout status deployment/"${DEPLOYMENT_NAME}" \
    -n "${O2_NAMESPACE}" --timeout="${O2_POD_READY_TIMEOUT}s"

  local pod running_image sa
  pod="$("${KUBECTL}" get pods -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}')"
  running_image="$("${KUBECTL}" get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].image}')"
  sa="$("${KUBECTL}" get deployment "${DEPLOYMENT_NAME}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}')"

  log_info "Running image: ${running_image}"
  log_info "ServiceAccount: ${sa}"
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
  log_info "deploy.sh v${O2_VERSION} — run_id=${O2_RUN_ID}"

  preflight
  validate_config
  action_deploy

  log_info "Done"
}

main "$@"
