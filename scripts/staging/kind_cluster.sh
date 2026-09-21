#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# kind_cluster.sh
#
# Create or reuse a local kind cluster with:
#   - Kubernetes (configurable version)
#   - Cilium as the CNI (data plane, kube-proxy replacement)
#   - Kubernetes Metrics Server (with --kubelet-insecure-tls for kind)
#
# Safety guarantees
# -----------------
#   - Idempotent: reruns are no-ops for unchanged inputs.
#   - Non-destructive by default: an existing cluster is never deleted unless
#     the caller opts in via FORCE_RECREATE=true.
#   - CNI-aware: if the existing cluster was created with the default kindnet
#     CNI, installing Cilium on top of it is unsafe and the script refuses.
#     The user is told exactly how to proceed.
#
# Overrides
# ---------
#   CLUSTER                  default: kind
#   K8S_VERSION              default: 1.36.1
#   K8S_IMAGE                default: kindest/node v1.36.1 (pinned by digest)
#   KIND_WORKERS             default: 1
#   POD_CIDR                 default: 10.244.0.0/16
#   SERVICE_CIDR             default: 10.96.0.0/12
#   CILIUM_VERSION           default: 1.19.6
#   METRICS_SERVER_VERSION   default: v0.9.0
#   WAIT_TIMEOUT             default: 300
# ==============================================================================

CLUSTER="${CLUSTER:-kind}"
K8S_VERSION="${K8S_VERSION:-1.36.1}"
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
KIND_WORKERS="${KIND_WORKERS:-1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

CILIUM_VERSION="${CILIUM_VERSION:-1.19.6}"
CILIUM_CHART="${CILIUM_CHART:-oci://quay.io/cilium/charts/cilium}"

METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.9.0}"
METRICS_SERVER_URL="${METRICS_SERVER_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
FORCE_RECREATE="${FORCE_RECREATE:-false}"

TMP_DIR=""
cleanup() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true; }
trap cleanup EXIT INT TERM

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  require_cmd helm
  require_cmd grep
  docker info >/dev/null 2>&1 || die "Docker daemon not running"
  TMP_DIR="$(mktemp -d)"
}

# ------------------------------------------------------------------------------
# Cluster state detection
# ------------------------------------------------------------------------------
cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"
}

ctx() { printf 'kind-%s' "${CLUSTER}"; }

cluster_has_cilium() {
  kubectl --context "$(ctx)" get daemonset cilium -n kube-system >/dev/null 2>&1
}

cluster_has_kindnet() {
  kubectl --context "$(ctx)" get daemonset kindnet -n kube-system >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# kind config (CNI-disabled so Cilium can take over)
# ------------------------------------------------------------------------------
write_kind_config() {
  local cfg="$1"
  cat >"${cfg}" <<EOF
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
    printf '  - role: worker\n' >>"${cfg}"
  done
}

# ------------------------------------------------------------------------------
# Cluster lifecycle
# ------------------------------------------------------------------------------
wait_for_api() {
  local start
  start="$(date +%s)"
  while ! kubectl get --raw='/readyz' >/dev/null 2>&1; do
    if (( $(date +%s) - start > 120 )); then
      die "Kubernetes API did not become ready within 120s"
    fi
    sleep 2
  done
}

create_cluster() {
  local cfg="${TMP_DIR}/kind.yaml"
  write_kind_config "${cfg}"

  log "Creating kind cluster '${CLUSTER}' with Kubernetes ${K8S_VERSION}"
  # NOTE: we deliberately do not pass --wait; with disableDefaultCNI the nodes
  # will not become Ready until Cilium is installed. We wait on the API server
  # manually instead.
  kind create cluster \
    --name "${CLUSTER}" \
    --image "${K8S_IMAGE}" \
    --config "${cfg}"

  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl config use-context "$(ctx)" >/dev/null
  wait_for_api
  log "Kubernetes API is up (nodes become Ready once Cilium is installed)"
}

reuse_cluster() {
  log "Reusing existing kind cluster '${CLUSTER}'"
  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl config use-context "$(ctx)" >/dev/null
  wait_for_api
}

recreate_cluster() {
  log "Deleting existing kind cluster '${CLUSTER}'"
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  create_cluster
}

# ------------------------------------------------------------------------------
# Cilium CNI
# ------------------------------------------------------------------------------
install_cilium() {
  log "Installing/upgrading Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"
  helm upgrade --install cilium "${CILIUM_CHART}" \
    --namespace kube-system \
    --version "${CILIUM_VERSION}" \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set operator.replicas=1 \
    --wait --timeout "${WAIT_TIMEOUT}s"

  kubectl rollout status daemonset/cilium -n kube-system --timeout="${WAIT_TIMEOUT}s"
  kubectl rollout status deployment/cilium-operator -n kube-system --timeout="${WAIT_TIMEOUT}s"
}

wait_for_nodes_ready() {
  log "Waiting for all nodes to be Ready"
  kubectl wait --for=condition=Ready nodes --all --timeout="${WAIT_TIMEOUT}s"
}

# ------------------------------------------------------------------------------
# Metrics Server (kind needs --kubelet-insecure-tls)
# ------------------------------------------------------------------------------
install_metrics_server() {
  log "Installing/upgrading Metrics Server ${METRICS_SERVER_VERSION}"
  kubectl apply -f "${METRICS_SERVER_URL}"

  # Idempotently ensure the --kubelet-insecure-tls flag is present.
  local current_args
  current_args="$(kubectl get deployment metrics-server -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)"

  if ! grep -q -- '--kubelet-insecure-tls' <<<"${current_args}"; then
    log "Adding --kubelet-insecure-tls to metrics-server"
    kubectl patch deployment metrics-server -n kube-system --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi

  kubectl rollout status deployment/metrics-server -n kube-system --timeout="${WAIT_TIMEOUT}s"

  log "Waiting for metrics.k8s.io API to become Available"
  local start
  start="$(date +%s)"
  while ! kubectl wait \
      --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
      --timeout=10s >/dev/null 2>&1; do
    if (( $(date +%s) - start > 120 )); then
      die "metrics.k8s.io API did not become Available within 120s"
    fi
    sleep 2
  done

  log "Waiting for 'kubectl top nodes' to succeed"
  start="$(date +%s)"
  while ! kubectl top nodes >/dev/null 2>&1; do
    if (( $(date +%s) - start > 60 )); then
      die "'kubectl top nodes' did not succeed within 60s"
    fi
    sleep 2
  done
}

# ------------------------------------------------------------------------------
# Final validation
# ------------------------------------------------------------------------------
final_validate() {
  log "Final validation"
  echo
  kubectl get nodes -o wide
  echo
  kubectl get pods -n kube-system
  echo
  kubectl top nodes
  echo
  log "READY: kind=${CLUSTER} k8s=${K8S_VERSION} cilium=${CILIUM_VERSION} metrics-server=${METRICS_SERVER_VERSION}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  preflight

  if cluster_exists; then
    if cluster_has_cilium; then
      # Safe path: reuse the cluster, helm upgrade handles version bumps.
      reuse_cluster
    elif cluster_has_kindnet; then
      if [[ "${FORCE_RECREATE}" == "true" ]]; then
        warn "Cluster '${CLUSTER}' uses kindnet; FORCE_RECREATE=true so it will be recreated with Cilium"
        recreate_cluster
      else
        die "Cluster '${CLUSTER}' already exists and uses the default kindnet CNI.
      Installing Cilium over kindnet is not supported.
      Re-run with FORCE_RECREATE=true to delete and recreate it with Cilium."
      fi
    else
      if [[ "${FORCE_RECREATE}" == "true" ]]; then
        warn "Cluster '${CLUSTER}' has no recognisable CNI; FORCE_RECREATE=true so it will be recreated"
        recreate_cluster
      else
        die "Cluster '${CLUSTER}' exists but its CNI could not be identified.
      Re-run with FORCE_RECREATE=true to delete and recreate it with Cilium."
      fi
    fi
  else
    create_cluster
  fi

  install_cilium
  wait_for_nodes_ready
  install_metrics_server
  final_validate
}

main "$@"
