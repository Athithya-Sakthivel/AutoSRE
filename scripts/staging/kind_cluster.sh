#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# kind_cluster.sh — Bulletproof Kind + Cilium Cluster Bootstrap
#
# Creates a local Kind cluster with Cilium as the CNI (kube-proxy replacement),
# Metrics Server, and CoreDNS upstream fix for WSL2/Devcontainer.
#
# Critical fixes applied automatically:
#   1. kubeProxyMode: "none" — prevents kube-proxy/Cilium dual-mode conflict
#   2. k8sServiceHost — patched into ConfigMap (Helm --set is unreliable)
#   3. CoreDNS upstream — patched to 8.8.8.8/1.1.1.1 (WSL2 fix)
#   4. socketLB.enabled — enables BPF socket-level load balancing
#
# Safety guarantees:
#   - Idempotent: reruns are no-ops for unchanged inputs
#   - Non-destructive by default: existing cluster is never deleted unless
#     FORCE_RECREATE=true is set
#   - CNI-aware: refuses to install Cilium over kindnet
#
# Overrides:
#   CLUSTER                  default: kind
#   K8S_IMAGE                default: kindest/node:v1.36.1 (pinned by digest)
#   KIND_WORKERS             default: 1
#   POD_CIDR                 default: 10.244.0.0/16
#   SERVICE_CIDR             default: 10.96.0.0/12
#   CILIUM_VERSION           default: 1.19.6
#   METRICS_SERVER_VERSION   default: v0.9.0
#   WAIT_TIMEOUT             default: 300
#   FORCE_RECREATE           default: false
# ==============================================================================

CLUSTER="${CLUSTER:-kind}"
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

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
pass() { printf '✓ %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  require_cmd helm
  require_cmd grep

  docker info >/dev/null 2>&1 || die "Docker daemon not running"
  TMP_DIR="$(mktemp -d)"
}

# -----------------------------------------------------------------------------
# Cluster state detection
# -----------------------------------------------------------------------------
cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER}"
}

ctx() {
  printf 'kind-%s' "${CLUSTER}"
}

cluster_has_cilium() {
  kubectl --context "$(ctx)" get daemonset cilium -n kube-system >/dev/null 2>&1
}

cluster_has_kindnet() {
  kubectl --context "$(ctx)" get daemonset kindnet -n kube-system >/dev/null 2>&1
}

cluster_has_kube_proxy() {
  kubectl --context "$(ctx)" get daemonset kube-proxy -n kube-system >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Detect control-plane IP
# -----------------------------------------------------------------------------
detect_control_plane_ip() {
  local ip=""

  # Try Kubernetes node object first
  ip="$(kubectl --context "$(ctx)" get nodes \
    -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || true)"

  # Fall back to Docker inspect
  if [[ -z "${ip}" ]]; then
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "${CLUSTER}-control-plane" 2>/dev/null || true)"
  fi

  [[ -n "${ip}" ]] || die "Could not detect control-plane IP"
  printf '%s' "${ip}"
}

# -----------------------------------------------------------------------------
# Kind config
# -----------------------------------------------------------------------------
write_kind_config() {
  local cfg="$1"

  cat >"${cfg}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            service-cluster-ip-range: "${SERVICE_CIDR}"
EOF

  local i
  for ((i = 0; i < KIND_WORKERS; i++)); do
    printf '  - role: worker\n' >>"${cfg}"
  done
}

# -----------------------------------------------------------------------------
# Cluster lifecycle
# -----------------------------------------------------------------------------
wait_for_api() {
  local start
  start="$(date +%s)"

  while ! kubectl --context "$(ctx)" get --raw='/readyz' >/dev/null 2>&1; do
    if (( $(date +%s) - start > 120 )); then
      die "Kubernetes API did not become ready within 120s"
    fi
    sleep 2
  done
}

create_cluster() {
  local cfg="${TMP_DIR}/kind-config.yaml"

  log "Creating kind cluster '${CLUSTER}'"
  write_kind_config "${cfg}"

  kind create cluster \
    --name "${CLUSTER}" \
    --image "${K8S_IMAGE}" \
    --config "${cfg}"

  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl config use-context "$(ctx)" >/dev/null
  wait_for_api

  cluster_has_kube_proxy && die "kube-proxy was installed despite kubeProxyMode: 'none'"
  pass "Cluster created. kube-proxy is NOT installed (Cilium will replace it)."
}

reuse_cluster() {
  log "Reusing existing kind cluster '${CLUSTER}'"

  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl config use-context "$(ctx)" >/dev/null
  wait_for_api

  if cluster_has_kube_proxy; then
    warn "Cluster has kube-proxy installed. This will conflict with Cilium."
    warn "Recreate with FORCE_RECREATE=true to fix this."
  fi
}

recreate_cluster() {
  log "Deleting existing kind cluster '${CLUSTER}'"
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  create_cluster
}

# -----------------------------------------------------------------------------
# Cilium CNI
# -----------------------------------------------------------------------------
install_cilium() {
  log "Installing/upgrading Cilium ${CILIUM_VERSION} (CNI + kube-proxy replacement)"

  local control_plane_ip
  control_plane_ip="$(detect_control_plane_ip)"
  log "Detected control-plane IP: ${control_plane_ip}"

  # Install Cilium WITHOUT --wait (we'll wait manually after patching ConfigMap)
  helm upgrade --install cilium "${CILIUM_CHART}" \
    --namespace kube-system \
    --version "${CILIUM_VERSION}" \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${control_plane_ip}" \
    --set k8sServicePort=6443 \
    --set socketLB.enabled=true \
    --set socketLB.hostNamespaceOnly=true \
    --set bpf.masquerade=true \
    --set ipv4NativeRoutingCIDR="${POD_CIDR}" \
    --set operator.replicas=1 \
    --timeout "${WAIT_TIMEOUT}s"

  # Patch ConfigMap immediately (Helm --set for k8sServiceHost is unreliable)
  patch_cilium_config "${control_plane_ip}"

  # Now wait for Cilium to be ready
  log "Waiting for Cilium DaemonSet to be ready..."
  kubectl rollout status daemonset/cilium -n kube-system --timeout="${WAIT_TIMEOUT}s"

  log "Waiting for Cilium operator to be ready..."
  kubectl rollout status deployment/cilium-operator -n kube-system --timeout="${WAIT_TIMEOUT}s"

  pass "Cilium installed and ready"
}

patch_cilium_config() {
  local expected_ip="$1"

  log "Patching cilium-config ConfigMap..."

  local actual_ip
  actual_ip="$(kubectl get configmap cilium-config -n kube-system \
    -o jsonpath='{.data.k8s-service-host}' 2>/dev/null || echo "")"

  if [[ "${actual_ip}" == "${expected_ip}" ]]; then
    pass "Cilium ConfigMap already correct (k8s-service-host=${expected_ip})"
    return 0
  fi

  log "Patching k8s-service-host: '${actual_ip:-<empty>}' → '${expected_ip}'"

  kubectl patch configmap cilium-config -n kube-system --type merge -p "{
    \"data\": {
      \"k8s-service-host\": \"${expected_ip}\",
      \"k8s-service-port\": \"6443\"
    }
  }"

  # Restart Cilium to pick up the new config
  kubectl rollout restart daemonset/cilium -n kube-system
  pass "Cilium ConfigMap patched"
}

wait_for_nodes_ready() {
  log "Waiting for all nodes to be Ready"
  kubectl wait --for=condition=Ready nodes --all --timeout="${WAIT_TIMEOUT}s"
}

# -----------------------------------------------------------------------------
# Metrics Server
# -----------------------------------------------------------------------------
install_metrics_server() {
  log "Installing/upgrading Metrics Server ${METRICS_SERVER_VERSION}"

  kubectl apply -f "${METRICS_SERVER_URL}"

  local current_args
  current_args="$(kubectl get deployment metrics-server -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].args[*]}' 2>/dev/null || true)"

  if [[ "${current_args}" != *"--kubelet-insecure-tls"* ]]; then
    log "Adding --kubelet-insecure-tls to metrics-server"
    kubectl patch deployment metrics-server -n kube-system --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi

  kubectl rollout status deployment/metrics-server -n kube-system --timeout="${WAIT_TIMEOUT}s"

  log "Waiting for metrics.k8s.io API to become Available"
  local start
  start="$(date +%s)"
  while ! kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=10s >/dev/null 2>&1; do
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

  pass "Metrics Server ready"
}

# -----------------------------------------------------------------------------
# CoreDNS upstream fix for WSL2 / Docker Desktop
# -----------------------------------------------------------------------------
fix_coredns_upstream() {
  log "Fixing CoreDNS upstream DNS for WSL2/Docker Desktop..."

  local current_corefile
  current_corefile="$(kubectl get configmap coredns -n kube-system \
    -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")"

  if [[ "${current_corefile}" == *"8.8.8.8"* ]]; then
    pass "CoreDNS already configured with public DNS upstream"
    return 0
  fi

  kubectl patch configmap coredns -n kube-system --type merge -p '{
    "data": {
      "Corefile": ".:53 {\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    forward . 8.8.8.8 1.1.1.1\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"
    }
  }'

  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s

  # Verify DNS resolution
  local verify_result
  verify_result="$(kubectl run dns-verify --rm -i --restart=Never \
    --image=busybox:1.37-musl -n kube-system --timeout=30s -- \
    sh -c 'nslookup google.com 2>&1' 2>&1 || echo "DNS_VERIFY_FAILED")"

  if [[ "${verify_result}" == *"Address"* ]]; then
    pass "CoreDNS upstream DNS working"
  else
    warn "CoreDNS upstream DNS verification did not return expected output"
  fi
}

# -----------------------------------------------------------------------------
# Final validation
# -----------------------------------------------------------------------------
final_validate() {
  log "Final validation"

  echo
  kubectl get nodes -o wide
  echo
  kubectl get pods -n kube-system
  echo
  kubectl top nodes

  log "Testing pod-to-service connectivity..."

  local test_result
  test_result="$(kubectl run connectivity-test \
    --rm -i --restart=Never \
    --image=busybox:1.37-musl \
    -n default --timeout=30s -- \
    sh -c 'nc -zv -w 5 kubernetes.default.svc.cluster.local 443 2>&1' \
    2>&1 || echo "CONNECTIVITY_TEST_FAILED")"

  if [[ "${test_result}" == *"open"* ]] || [[ "${test_result}" == *"succeeded"* ]]; then
    pass "Pod-to-service connectivity working"
  else
    warn "Pod-to-service connectivity test failed"
  fi

  echo
  log "READY: kind=${CLUSTER} cilium=${CILIUM_VERSION}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  preflight

  if cluster_exists; then
    if cluster_has_cilium; then
      reuse_cluster
    elif cluster_has_kindnet; then
      if [[ "${FORCE_RECREATE}" == "true" ]]; then
        warn "Cluster uses kindnet; FORCE_RECREATE=true, recreating with Cilium"
        recreate_cluster
      else
        die "Cluster '${CLUSTER}' uses kindnet CNI.
Re-run with FORCE_RECREATE=true to delete and recreate with Cilium."
      fi
    else
      if [[ "${FORCE_RECREATE}" == "true" ]]; then
        warn "Cluster has no recognisable CNI; FORCE_RECREATE=true, recreating"
        recreate_cluster
      else
        die "Cluster '${CLUSTER}' CNI could not be identified.
Re-run with FORCE_RECREATE=true to delete and recreate with Cilium."
      fi
    fi
  else
    create_cluster
  fi

  install_cilium
  wait_for_nodes_ready
  install_metrics_server
  fix_coredns_upstream
  final_validate
}

main "$@"
