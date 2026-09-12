#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# kind_cluster.sh — Create or reuse a local kind cluster.
#
# Uses kind's default CNI. No Cilium, no Envoy Gateway, no Metrics Server.
#
# Idempotent: if the cluster already exists, it is reused.
# ==============================================================================

CLUSTER="${CLUSTER:-kind}"
K8S_VERSION="${K8S_VERSION:-1.36.1}"
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

log() { printf '==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

preflight() {
  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  docker info >/dev/null 2>&1 || die "Docker daemon not running"
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    log "kind cluster '${CLUSTER}' already exists; reusing"
  else
    log "Creating kind cluster '${CLUSTER}' with Kubernetes ${K8S_VERSION}"
    kind create cluster \
      --name "${CLUSTER}" \
      --image "${K8S_IMAGE}" \
      --wait "${WAIT_TIMEOUT}s"
  fi

  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl config use-context "kind-${CLUSTER}" >/dev/null
  kubectl wait --for=condition=Ready nodes --all --timeout=120s

  log "Cluster ready"
  kubectl get nodes -o wide
}

main() {
  preflight
  create_cluster
}

main "$@"
