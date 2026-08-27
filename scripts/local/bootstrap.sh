#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Local Kubernetes bootstrap for kind.
# Recreates the named cluster on every run by design.
# Baseline: kind + Kubernetes 1.36.1 + Gateway API v1.6.1 + Cilium 1.20.1 + Metrics Server v0.9.0

CLUSTER="${CLUSTER:-kind}"
K8S_VERSION="${K8S_VERSION:-1.36.1}"
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
KIND_WORKERS="${KIND_WORKERS:-0}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

CILIUM_VERSION="${CILIUM_VERSION:-1.20.1}"
CILIUM_CHART="oci://quay.io/cilium/charts/cilium"

METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.9.0}"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

TMP_DIR="$(mktemp -d)"
KIND_CONFIG="${TMP_DIR}/kind.yaml"
KUBECTL_BIN="${KUBECTL_BIN:-$(command -v kubectl 2>/dev/null || true)}"

log() { printf '==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_until() {
  local description="$1" timeout="$2" start elapsed
  shift 2
  start="$(date +%s)"
  while true; do
    "$@" >/dev/null 2>&1 && return 0
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= timeout )) && die "Timed out waiting for ${description}"
    sleep 2
  done
}

kubectl_cmd() {
  [[ -n "${KUBECTL_BIN}" ]] || die "kubectl binary is not initialized"
  "${KUBECTL_BIN}" "$@"
}

preflight() {
  require_command docker
  require_command kind
  require_command kubectl
  require_command helm
  require_command curl
  docker info >/dev/null 2>&1 || die "Docker daemon not running"
}

create_kind_config() {
  cat >"${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
nodes:
  - role: control-plane
EOF
  local i
  for (( i=0; i<KIND_WORKERS; i++ )); do
    echo "  - role: worker" >> "${KIND_CONFIG}"
  done
}

create_cluster() {
  log "Recreating kind cluster ${CLUSTER}"
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  kind create cluster --name "${CLUSTER}" --image "${K8S_IMAGE}" --config "${KIND_CONFIG}"
  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl_cmd config use-context "kind-${CLUSTER}" >/dev/null
  wait_until "Kubernetes API" 180 kubectl_cmd get --raw='/readyz?verbose'
}

install_gateway_api() {
  log "Installing Gateway API ${GATEWAY_API_VERSION}"
  kubectl_cmd apply --server-side -f "${GATEWAY_API_URL}"
  for crd in gatewayclasses gateways httproutes referencegrants backendtlspolicies; do
    kubectl_cmd wait --for=condition=Established "crd/${crd}.gateway.networking.k8s.io" --timeout=120s
  done
}

install_cilium() {
  log "Installing Cilium ${CILIUM_VERSION}"
  helm upgrade --install cilium "${CILIUM_CHART}" \
    --namespace kube-system \
    --version "${CILIUM_VERSION}" \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set gatewayAPI.enabled=true \
    --set operator.replicas=1 \
    --wait --timeout "${WAIT_TIMEOUT}s"

  kubectl_cmd rollout status daemonset/cilium -n kube-system --timeout="${WAIT_TIMEOUT}s"
  kubectl_cmd rollout status deployment/cilium-operator -n kube-system --timeout="${WAIT_TIMEOUT}s"
  wait_until "Cilium GatewayClass" 60 kubectl_cmd get gatewayclass cilium
}

remove_taint() {
  (( KIND_WORKERS == 0 )) || return 0
  log "Removing control-plane taint"
  kubectl_cmd taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
}

install_metrics_server() {
  log "Installing Metrics Server ${METRICS_SERVER_VERSION}"
  kubectl_cmd apply -f "${METRICS_SERVER_URL}"
  kubectl_cmd patch deployment metrics-server -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  kubectl_cmd rollout status deployment/metrics-server -n kube-system --timeout="${WAIT_TIMEOUT}s"
  kubectl_cmd wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
  wait_until "kubectl top nodes" 60 kubectl_cmd top nodes
}

final_validate() {
  log "Final validation"
  kubectl_cmd wait --for=condition=Ready nodes --all --timeout=120s
  echo
  kubectl_cmd get nodes -o wide
  echo
  kubectl_cmd get pods -n kube-system
  echo
  kubectl_cmd get gatewayclass cilium -o wide
  echo
  kubectl_cmd top nodes
  echo
  log "READY: kind=${CLUSTER} k8s=${K8S_VERSION} cilium=${CILIUM_VERSION} gatewayapi=${GATEWAY_API_VERSION}"
}

main() {
  preflight
  create_kind_config
  create_cluster
  install_gateway_api
  install_cilium
  remove_taint
  install_metrics_server
  final_validate
}

main "$@"