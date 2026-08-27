#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Istio Ambient setup for a kind cluster that already has:
#   - Calico with bpfConnectTimeLoadBalancing=Disabled (done in bootstrap.sh)
#   - Metrics Server (optional, not required)
#
# This script:
#   - Cleans up any existing Istio installation
#   - Verifies Calico CTLB is Disabled
#   - Installs Gateway API Standard CRDs (v1.5.1)
#   - Installs Istio 1.30.3 Ambient (istiod, istio-cni, ztunnel)
#   - Creates the application namespace with ambient mode enabled
#
# Run after bootstrap.sh and before setup-argo.sh.

ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
NAMESPACE="${NAMESPACE:-task-api}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-10m}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ISTIO_ROOT="${REPO_ROOT}/.istio"
ISTIO_DIR="${ISTIO_ROOT}/istio-${ISTIO_VERSION}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_istio() {
  log "Cleaning up existing Istio installation (if any)"
  if [[ -x "${ISTIO_DIR}/bin/istioctl" ]]; then
    "${ISTIO_DIR}/bin/istioctl" uninstall --purge -y || true
  elif command -v istioctl >/dev/null 2>&1; then
    istioctl uninstall --purge -y || true
  fi
  kubectl delete namespace "${ISTIO_NAMESPACE}" --ignore-not-found=true
}

verify_calico_istio_compat() {
  log "Verifying Calico bpfConnectTimeLoadBalancing is Disabled"
  local ctlb
  ctlb="$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfConnectTimeLoadBalancing}')"
  [[ "${ctlb}" == "Disabled" ]] || {
    die "Calico bpfConnectTimeLoadBalancing is '${ctlb}', expected 'Disabled'. Run bootstrap.sh first."
  }
  log "Calico is Istio Ambient compatible"
}

install_gateway_api() {
  log "Installing Gateway API ${GATEWAY_API_VERSION} Standard channel"
  kubectl apply --server-side \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

  for crd in \
    gatewayclasses.gateway.networking.k8s.io \
    gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io \
    grpcroutes.gateway.networking.k8s.io \
    referencegrants.gateway.networking.k8s.io
  do
    kubectl get crd "${crd}" >/dev/null 2>&1 || die "Required Gateway API CRD missing: ${crd}"
  done
  log "Gateway API CRDs verified"
}

download_istio() {
  mkdir -p "${ISTIO_ROOT}"
  if [[ -x "${ISTIO_DIR}/bin/istioctl" ]]; then
    log "Using existing Istio ${ISTIO_VERSION}"
    return 0
  fi

  log "Downloading Istio ${ISTIO_VERSION}"
  (
    cd "${ISTIO_ROOT}"
    curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
  )
  [[ -x "${ISTIO_DIR}/bin/istioctl" ]] || die "istioctl not found after download"
}

install_istio() {
  download_istio
  export PATH="${ISTIO_DIR}/bin:${PATH}"

  log "Istio client version:"
  istioctl version --remote=false

  log "Running Istio precheck"
  istioctl x precheck

  log "Installing Istio ${ISTIO_VERSION} ambient profile"
  istioctl install --set profile=ambient --skip-confirmation

  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status daemonset/istio-cni-node -n "${ISTIO_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
}

enroll_namespace() {
  log "Creating namespace ${NAMESPACE}"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  log "Enabling Istio ambient mode for namespace ${NAMESPACE}"
  kubectl label namespace "${NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite
  kubectl label namespace "${NAMESPACE}" istio-injection- --overwrite >/dev/null 2>&1 || true

  kubectl get namespace "${NAMESPACE}" --show-labels
}

verify_installation() {
  log "Final verification"

  printf '\nIstio pods:\n'
  kubectl get pods -n "${ISTIO_NAMESPACE}" -o wide

  printf '\nCalico CTLB: '
  kubectl get felixconfiguration default -o jsonpath='{.spec.bpfConnectTimeLoadBalancing}'
  printf '\n'

  printf '\nGateway API CRDs:\n'
  kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io

  printf '\nAmbient namespace:\n'
  kubectl get namespace "${NAMESPACE}" --show-labels
}

main() {
  require_cmd kubectl
  require_cmd curl

  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot connect to the cluster"

  cleanup_istio
  verify_calico_istio_compat
  install_gateway_api
  install_istio
  enroll_namespace
  verify_installation

  printf '\n============================================================\n'
  printf ' Istio Ambient setup complete\n'
  printf '============================================================\n'
  printf ' Istio:             %s\n' "${ISTIO_VERSION}"
  printf ' Gateway API:       %s Standard\n' "${GATEWAY_API_VERSION}"
  printf ' Ambient namespace: %s\n' "${NAMESPACE}"
  printf '============================================================\n'
}

main "$@"