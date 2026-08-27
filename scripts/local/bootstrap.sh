#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Local Kubernetes bootstrap for kind (AKS-like baseline)
#
# Installs:
#   - kind cluster (Kubernetes 1.36.4, image digest pinned)
#   - Calico v3.32.1 (CNI + NetworkPolicy enforcement)
#   - Metrics Server v0.9.0 (HPA support)
#   - Calico FelixConfiguration patched for Istio Ambient (bpfConnectTimeLoadBalancing=Disabled)
#
# Does NOT install:
#   - ingress-nginx (deprecated / retired)
#   - Argo Rollouts (installed by setup-argo.sh)
#   - Istio / Gateway API (installed by setup-istio.sh)
#
# Design goals:
#   - deterministic, pinned artifacts where practical
#   - no Python dependency
#   - no `kubectl version --client -o jsonpath` (unsupported by some kubectl builds)
#   - never make kind wait for Node Ready when the default CNI is disabled
#   - install Calico before waiting for node readiness
#   - make Calico compatible with Istio Ambient (disable bpfConnectTimeLoadBalancing)
#   - validate the Kubernetes metrics pipeline end-to-end (`kubectl top`)
#   - useful diagnostics on failure
#
# This is for local development/test clusters, not production.
# -----------------------------------------------------------------------------

CLUSTER="${CLUSTER:-kind}"

# Kubernetes version and image
K8S_VERSION="${K8S_VERSION:-1.36.4}"
K8S_IMAGE_DEFAULT="docker.io/kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
K8S_IMAGE="${K8S_IMAGE:-}"

# Networking
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
KIND_WORKERS="${KIND_WORKERS:-0}"

# Calico
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
CALICO_CRD_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v1_crd_projectcalico_org.yaml"
CALICO_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# Metrics Server
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.9.0}"
METRICS_SERVER_MANIFEST_SHA256="${METRICS_SERVER_MANIFEST_SHA256:-1cec29a5267809306a2c6ec74a3e449abbb705b4a8beed0c8a1963910f72c79b}"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
METRICS_SERVER_KUBELET_INSECURE_TLS="${METRICS_SERVER_KUBELET_INSECURE_TLS:-true}"
METRICS_SERVER_PREFERRED_ADDRESS_TYPES="${METRICS_SERVER_PREFERRED_ADDRESS_TYPES:-InternalIP,ExternalIP,Hostname}"
METRICS_SERVER_METRIC_RESOLUTION="${METRICS_SERVER_METRIC_RESOLUTION:-15s}"
METRICS_SERVER_TIMEOUT="${METRICS_SERVER_TIMEOUT:-600}"

# Timeouts and retries
WAIT_API_TIMEOUT="${WAIT_API_TIMEOUT:-180}"
WAIT_CALICO_TIMEOUT="${WAIT_CALICO_TIMEOUT:-900}"
WAIT_WORKLOAD_TIMEOUT="${WAIT_WORKLOAD_TIMEOUT:-600}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-5}"
RETRY_DELAY="${RETRY_DELAY:-3}"

KUBE_CONTEXT="kind-${CLUSTER}"
TMP_DIR="$(mktemp -d)"
KIND_CONFIG="${TMP_DIR}/kind.yaml"
CALICO_CRD_MANIFEST="${TMP_DIR}/calico-crds.yaml"
CALICO_OPERATOR_MANIFEST="${TMP_DIR}/tigera-operator.yaml"
CALICO_RESOURCES_MANIFEST="${TMP_DIR}/calico-custom-resources.yaml"
METRICS_SERVER_MANIFEST="${TMP_DIR}/metrics-server-components.yaml"
KUBECTL_BIN="${KUBECTL_BIN:-$(command -v kubectl 2>/dev/null || true)}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

dump_debug() {
  {
    printf '\n================ DEBUG ================\n'

    printf '\n--- executable versions ---\n'
    command -v docker >/dev/null 2>&1 && \
      docker version --format 'docker client={{.Client.Version}} server={{.Server.Version}}' 2>&1 || true
    command -v kind >/dev/null 2>&1 && kind version 2>&1 || true
    [[ -n "${KUBECTL_BIN}" ]] && "${KUBECTL_BIN}" version --output=yaml 2>&1 || true

    printf '\n--- kubectl context ---\n'
    "${KUBECTL_BIN:-kubectl}" config current-context 2>&1 || true

    printf '\n--- nodes ---\n'
    "${KUBECTL_BIN:-kubectl}" get nodes -o wide 2>&1 || true

    printf '\n--- node conditions ---\n'
    "${KUBECTL_BIN:-kubectl}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.conditions[*]}  {.type}={.status}{"\n"}{end}{end}' 2>&1 || true

    printf '\n--- namespaces ---\n'
    "${KUBECTL_BIN:-kubectl}" get namespaces 2>&1 || true

    printf '\n--- kube-system ---\n'
    "${KUBECTL_BIN:-kubectl}" get pods -n kube-system -o wide 2>&1 || true

    printf '\n--- tigera-operator ---\n'
    "${KUBECTL_BIN:-kubectl}" get pods -n tigera-operator -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get deployment -n tigera-operator -o wide 2>&1 || true

    printf '\n--- calico-system ---\n'
    "${KUBECTL_BIN:-kubectl}" get all -n calico-system -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get tigerastatus -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get installation.operator.tigera.io default -o yaml 2>&1 || true

    printf '\n--- metrics-server ---\n'
    "${KUBECTL_BIN:-kubectl}" get deployment metrics-server -n kube-system -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get pods -n kube-system -l k8s-app=metrics-server -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get apiservice v1beta1.metrics.k8s.io -o wide 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" describe apiservice v1beta1.metrics.k8s.io 2>&1 || true
    "${KUBECTL_BIN:-kubectl}" get --raw='/apis/metrics.k8s.io/v1beta1' 2>&1 || true

    printf '\n--- recent events ---\n'
    "${KUBECTL_BIN:-kubectl}" get events -A --sort-by=.lastTimestamp 2>&1 | tail -n 160 || true

    printf '\n=======================================\n'
  } >&2
}

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-unknown}"
  local command="${BASH_COMMAND:-unknown}"
  printf '\nERROR: bootstrap failed\n' >&2
  printf '  exit code : %s\n' "${exit_code}" >&2
  printf '  line      : %s\n' "${line_no}" >&2
  printf '  command   : %s\n' "${command}" >&2
  dump_debug
  exit "${exit_code}"
}

cleanup() { rm -rf "${TMP_DIR}"; }

trap on_error ERR
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2

  local attempt=1
  while (( attempt <= attempts )); do
    if "$@"; then
      return 0
    fi

    if (( attempt == attempts )); then
      return 1
    fi

    sleep "${delay}"
    attempt=$((attempt + 1))
  done
}

wait_until() {
  local description="$1"
  local timeout="$2"
  shift 2

  local start elapsed
  start="$(date +%s)"

  while true; do
    if "$@"; then
      return 0
    fi

    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= timeout )); then
      die "Timed out waiting for ${description}"
    fi

    sleep 2
  done
}

kubectl_cmd() {
  [[ -n "${KUBECTL_BIN}" ]] || die "kubectl binary is not initialized"
  "${KUBECTL_BIN}" "$@"
}

validate_uint() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer, got: ${value}"
}

validate_ipv4_cidr() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
    die "${name} must be an IPv4 CIDR, got: ${value}"

  local ip="${value%/*}"
  local octet
  IFS=. read -r -a octets <<< "${ip}"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || die "${name} contains invalid IPv4 octet: ${value}"
  done
}

validate_inputs() {
  [[ "${CLUSTER}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] ||
    die "CLUSTER contains unsupported characters: ${CLUSTER}"

  [[ "${K8S_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "K8S_VERSION must be x.y.z, got: ${K8S_VERSION}"

  validate_ipv4_cidr "POD_CIDR" "${POD_CIDR}"
  validate_ipv4_cidr "SERVICE_CIDR" "${SERVICE_CIDR}"
  validate_uint "KIND_WORKERS" "${KIND_WORKERS}"
  validate_uint "RETRY_ATTEMPTS" "${RETRY_ATTEMPTS}"
  validate_uint "RETRY_DELAY" "${RETRY_DELAY}"
  validate_uint "WAIT_API_TIMEOUT" "${WAIT_API_TIMEOUT}"
  validate_uint "WAIT_CALICO_TIMEOUT" "${WAIT_CALICO_TIMEOUT}"
  validate_uint "WAIT_WORKLOAD_TIMEOUT" "${WAIT_WORKLOAD_TIMEOUT}"
  validate_uint "METRICS_SERVER_TIMEOUT" "${METRICS_SERVER_TIMEOUT}"

  [[ "${METRICS_SERVER_METRIC_RESOLUTION}" =~ ^[0-9]+s$ ]] ||
    die "METRICS_SERVER_METRIC_RESOLUTION must be a seconds duration such as 15s"

  [[ "${METRICS_SERVER_KUBELET_INSECURE_TLS}" == "true" ||
     "${METRICS_SERVER_KUBELET_INSECURE_TLS}" == "false" ]] ||
    die "METRICS_SERVER_KUBELET_INSECURE_TLS must be true or false"

  if [[ -z "${K8S_IMAGE}" ]]; then
    if [[ "${K8S_VERSION}" == "1.36.4" ]]; then
      K8S_IMAGE="${K8S_IMAGE_DEFAULT}"
    else
      K8S_IMAGE="docker.io/kindest/node:v${K8S_VERSION}"
      warn "No built-in digest is recorded for Kubernetes ${K8S_VERSION}; set K8S_IMAGE to an explicit digest for reproducibility."
    fi
  fi
}

preflight() {
  require_command docker
  require_command kind
  require_command curl
  require_command sha256sum
  require_command awk
  require_command cut
  require_command grep
  require_command sed
  require_command tail
  require_command head
  require_command date
  require_command mktemp

  [[ -n "${KUBECTL_BIN}" ]] ||
    die "Required command not found: kubectl"

  docker info >/dev/null 2>&1 ||
    die "Docker daemon is not available"

  "${KUBECTL_BIN}" version --client=true --output=yaml >/dev/null 2>&1 ||
    die "kubectl is installed but not executable"
}

fetch_manifest() {
  local url="$1"
  local destination="$2"

  retry "${RETRY_ATTEMPTS}" "${RETRY_DELAY}" \
    curl -fsSL --retry 3 --retry-all-errors \
      --connect-timeout 10 --max-time 120 \
      -o "${destination}" "${url}"

  [[ -s "${destination}" ]] ||
    die "Downloaded manifest is empty: ${url}"
}

extract_client_version() {
  kubectl_cmd version --client=true --output=yaml 2>/dev/null |
    awk '/^[[:space:]]*gitVersion:/ { gsub(/"/, "", $2); print $2; exit }'
}

extract_server_version() {
  kubectl_cmd version --output=yaml 2>/dev/null |
    awk '/^[[:space:]]*gitVersion:/ { gsub(/"/, "", $2); print $2 }' |
    tail -n 1
}

minor_version() {
  local version="$1"
  local without_v="${version#v}"
  printf '%s\n' "${without_v#*.}" | cut -d. -f1
}

ensure_kubectl_compatible() {
  local current_version=""
  local bundled="${TMP_DIR}/kubectl"
  local expected_version="v${K8S_VERSION}"
  local host_arch arch download_url checksum_url expected_sha actual_sha
  local client_minor server_minor minor_skew

  current_version="$(extract_client_version || true)"
  server_minor="$(printf '%s\n' "${expected_version#v}" | cut -d. -f2)"

  if [[ -n "${current_version}" ]]; then
    client_minor="$(minor_version "${current_version}")"

    if [[ "${client_minor}" =~ ^[0-9]+$ && "${server_minor}" =~ ^[0-9]+$ ]]; then
      minor_skew=$(( client_minor - server_minor ))
      (( minor_skew < 0 )) && minor_skew=$(( -minor_skew ))

      if (( minor_skew <= 1 )); then
        log "Using compatible kubectl ${current_version}"
        return 0
      fi
    fi
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv6l) arch="arm" ;;
    ppc64le) arch="ppc64le" ;;
    s390x) arch="s390x" ;;
    *) die "Unsupported host architecture for kubectl bootstrap: $(uname -m)" ;;
  esac

  download_url="https://dl.k8s.io/release/${expected_version}/bin/linux/${arch}/kubectl"
  checksum_url="${download_url}.sha256"

  log "Downloading kubectl ${expected_version} for ${arch}"
  retry "${RETRY_ATTEMPTS}" "${RETRY_DELAY}" \
    curl -fsSL --retry 3 --retry-all-errors \
      --connect-timeout 10 --max-time 120 \
      -o "${bundled}" "${download_url}"
  retry "${RETRY_ATTEMPTS}" "${RETRY_DELAY}" \
    curl -fsSL --retry 3 --retry-all-errors \
      --connect-timeout 10 --max-time 120 \
      -o "${bundled}.sha256" "${checksum_url}"

  expected_sha="$(awk '{print $1}' "${bundled}.sha256")"
  actual_sha="$(sha256sum "${bundled}" | awk '{print $1}')"

  [[ -n "${expected_sha}" ]] ||
    die "Downloaded kubectl checksum is empty"

  [[ "${expected_sha}" == "${actual_sha}" ]] ||
    die "kubectl checksum verification failed"

  chmod +x "${bundled}"
  "${bundled}" version --client=true --output=yaml >/dev/null
  KUBECTL_BIN="${bundled}"
}

wait_for_namespace() {
  local namespace="$1"
  local timeout="$2"
  wait_until "namespace/${namespace}" "${timeout}" \
    kubectl_cmd get namespace "${namespace}" >/dev/null 2>&1
}

wait_for_crd() {
  local crd="$1"
  local timeout="$2"
  wait_until "CRD ${crd}" "${timeout}" \
    kubectl_cmd wait --for=condition=Established "crd/${crd}" --timeout=10s >/dev/null 2>&1
}

wait_for_deployment_ready() {
  local namespace="$1"
  local deployment="$2"
  local timeout="$3"

  wait_until "deployment/${deployment} in namespace ${namespace}" "${timeout}" \
    kubectl_cmd rollout status "deployment/${deployment}" \
      -n "${namespace}" --timeout=15s >/dev/null 2>&1
}

wait_for_daemonset_ready() {
  local namespace="$1"
  local daemonset="$2"
  local timeout="$3"

  wait_until "daemonset/${daemonset} in namespace ${namespace}" "${timeout}" \
    kubectl_cmd rollout status "daemonset/${daemonset}" \
      -n "${namespace}" --timeout=15s >/dev/null 2>&1
}

wait_for_tigerastatus() {
  local timeout="$1"
  local start elapsed
  start="$(date +%s)"

  while true; do
    if kubectl_cmd get tigerastatus \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\t"}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' \
      2>/dev/null |
      awk '
        BEGIN { seen=0; bad=0 }
        NF {
          seen=1
          if ($2 != "True" || $3 == "True") bad=1
        }
        END {
          exit (!seen || bad)
        }
      '; then
      return 0
    fi

    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= timeout )); then
      printf '\nTimed out waiting for all required TigeraStatus resources to become healthy.\n' >&2
      kubectl_cmd get tigerastatus -o wide >&2 || true
      printf '\n--- Calico operator logs ---\n' >&2
      kubectl_cmd logs -n tigera-operator deployment/tigera-operator --tail=240 >&2 || true
      printf '\n--- Calico events ---\n' >&2
      kubectl_cmd get events -n calico-system --sort-by=.lastTimestamp >&2 || true
      return 1
    fi

    sleep 5
  done
}

create_calico_resources_manifest() {
  cat >"${CALICO_RESOURCES_MANIFEST}" <<EOF_MANIFEST
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  cni:
    type: Calico
  calicoNetwork:
    bgp: Disabled
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
    ipPools:
      - cidr: ${POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
---
apiVersion: operator.tigera.io/v1
kind: Goldmane
metadata:
  name: default
---
apiVersion: operator.tigera.io/v1
kind: Whisker
metadata:
  name: default
EOF_MANIFEST
}

configure_calico_for_istio() {
  log "Configuring Calico for Istio Ambient compatibility"

  # The FelixConfiguration object is created by the operator, wait for it.
  wait_until "default FelixConfiguration" "${WAIT_CALICO_TIMEOUT}" \
    kubectl_cmd get felixconfiguration default >/dev/null 2>&1

  # Always set bpfConnectTimeLoadBalancing to Disabled, regardless of bpfEnabled.
  kubectl_cmd patch felixconfiguration default \
    --type='merge' \
    -p '{"spec":{"bpfConnectTimeLoadBalancing":"Disabled"}}'

  # Restart calico-node to apply the change.
  if kubectl_cmd get daemonset calico-node -n calico-system >/dev/null 2>&1; then
    kubectl_cmd rollout restart daemonset/calico-node -n calico-system
    kubectl_cmd rollout status daemonset/calico-node -n calico-system --timeout="${WAIT_CALICO_TIMEOUT}"
  fi

  # Verify.
  local ctlb
  ctlb="$(kubectl_cmd get felixconfiguration default -o jsonpath='{.spec.bpfConnectTimeLoadBalancing}')"
  [[ "${ctlb}" == "Disabled" ]] || die "Calico bpfConnectTimeLoadBalancing is ${ctlb}, expected Disabled"
  log "Calico bpfConnectTimeLoadBalancing confirmed as Disabled"
}

install_calico() {
  local crd

  log "Fetching Calico ${CALICO_VERSION} manifests"
  fetch_manifest "${CALICO_CRD_URL}" "${CALICO_CRD_MANIFEST}"
  fetch_manifest "${CALICO_OPERATOR_URL}" "${CALICO_OPERATOR_MANIFEST}"
  create_calico_resources_manifest

  log "Installing Calico CRDs"
  kubectl_cmd create -f "${CALICO_CRD_MANIFEST}"

  log "Installing Tigera Operator"
  kubectl_cmd create -f "${CALICO_OPERATOR_MANIFEST}"

  log "Waiting for Tigera Operator"
  wait_for_deployment_ready tigera-operator tigera-operator 300

  log "Waiting for Calico operator CRDs"
  for crd in \
    installations.operator.tigera.io \
    apiservers.operator.tigera.io \
    goldmanes.operator.tigera.io \
    whiskers.operator.tigera.io
  do
    wait_for_crd "${crd}" 300
  done

  log "Installing Calico custom resources with pod CIDR ${POD_CIDR}"
  kubectl_cmd create -f "${CALICO_RESOURCES_MANIFEST}"

  log "Waiting for Calico"
  wait_for_namespace calico-system "${WAIT_CALICO_TIMEOUT}"

  wait_until "calico-node DaemonSet to exist" "${WAIT_CALICO_TIMEOUT}" \
    kubectl_cmd get daemonset calico-node -n calico-system >/dev/null 2>&1
  wait_for_daemonset_ready calico-system calico-node "${WAIT_CALICO_TIMEOUT}"

  wait_until "calico-kube-controllers Deployment to exist" "${WAIT_CALICO_TIMEOUT}" \
    kubectl_cmd get deployment calico-kube-controllers -n calico-system >/dev/null 2>&1
  wait_for_deployment_ready calico-system calico-kube-controllers "${WAIT_CALICO_TIMEOUT}"

  wait_for_tigerastatus "${WAIT_CALICO_TIMEOUT}"
}

patch_metrics_server_arg() {
  local arg="$1"

  if kubectl_cmd get deployment metrics-server -n kube-system \
      -o jsonpath='{.spec.template.spec.containers[0].args[*]}' 2>/dev/null |
      grep -F -- "${arg}" >/dev/null; then
    return 0
  fi

  kubectl_cmd patch deployment metrics-server -n kube-system \
    --type=json \
    -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${arg}\"}]"
}

install_metrics_server() {
  local checksum

  log "Installing Metrics Server ${METRICS_SERVER_VERSION}"
  fetch_manifest "${METRICS_SERVER_URL}" "${METRICS_SERVER_MANIFEST}"

  checksum="$(sha256sum "${METRICS_SERVER_MANIFEST}" | awk '{print $1}')"
  [[ "${checksum}" == "${METRICS_SERVER_MANIFEST_SHA256}" ]] ||
    die "Metrics Server manifest checksum mismatch: expected ${METRICS_SERVER_MANIFEST_SHA256}, got ${checksum}"

  kubectl_cmd apply -f "${METRICS_SERVER_MANIFEST}"

  # kind's kubelet serving certificates are not guaranteed to validate against
  # the node IP. Metrics Server documents --kubelet-insecure-tls as testing-only.
  # This is deliberately enabled only for this local cluster bootstrap.
  if [[ "${METRICS_SERVER_KUBELET_INSECURE_TLS}" == "true" ]]; then
    patch_metrics_server_arg "--kubelet-insecure-tls"
  fi

  patch_metrics_server_arg "--kubelet-preferred-address-types=${METRICS_SERVER_PREFERRED_ADDRESS_TYPES}"
  patch_metrics_server_arg "--metric-resolution=${METRICS_SERVER_METRIC_RESOLUTION}"

  log "Waiting for Metrics Server Deployment"
  wait_for_deployment_ready kube-system metrics-server "${METRICS_SERVER_TIMEOUT}"

  log "Waiting for metrics.k8s.io APIService"
  kubectl_cmd wait --for=condition=Available \
    apiservice/v1beta1.metrics.k8s.io --timeout=5m

  # APIService availability can be observed before useful metrics are available.
  wait_until "Metrics API endpoint" "${METRICS_SERVER_TIMEOUT}" \
    kubectl_cmd get --raw='/apis/metrics.k8s.io/v1beta1' >/dev/null 2>&1

  log "Waiting for kubectl top nodes"
  wait_until "kubectl top nodes" "${METRICS_SERVER_TIMEOUT}" \
    kubectl_cmd top nodes >/dev/null 2>&1
}

create_kind_config() {
  {
    printf 'kind: Cluster\n'
    printf 'apiVersion: kind.x-k8s.io/v1alpha4\n'
    printf 'networking:\n'
    printf '  disableDefaultCNI: true\n'
    printf '  podSubnet: "%s"\n' "${POD_CIDR}"
    printf '  serviceSubnet: "%s"\n' "${SERVICE_CIDR}"
    printf 'nodes:\n'
    printf '  - role: control-plane\n'

    local i
    for (( i=0; i<KIND_WORKERS; i++ )); do
      printf '  - role: worker\n'
    done
  } >"${KIND_CONFIG}"
}

create_cluster() {
  log "Deleting existing kind cluster ${CLUSTER}"
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true

  log "Creating kind cluster ${CLUSTER} with Kubernetes ${K8S_VERSION}"
  # Do NOT use `kind create cluster --wait` here. With disableDefaultCNI=true,
  # Node Ready is intentionally impossible until Calico is installed.
  kind create cluster \
    --name "${CLUSTER}" \
    --image "${K8S_IMAGE}" \
    --config "${KIND_CONFIG}"

  log "Exporting kubeconfig"
  kind export kubeconfig --name "${CLUSTER}" >/dev/null
  kubectl_cmd config use-context "${KUBE_CONTEXT}" >/dev/null

  log "Waiting for Kubernetes API"
  wait_until "Kubernetes API readiness" "${WAIT_API_TIMEOUT}" \
    kubectl_cmd get --raw='/readyz?verbose' >/dev/null 2>&1
}

remove_single_node_control_plane_taint() {
  (( KIND_WORKERS == 0 )) || return 0

  log "Removing control-plane taint for single-node local development"
  kubectl_cmd taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl_cmd taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
}

validate_cluster_versions() {
  local client_version server_version
  local client_minor server_minor minor_skew

  client_version="$(extract_client_version)"
  server_version="$(extract_server_version)"

  [[ -n "${client_version}" && -n "${server_version}" ]] ||
    die "Could not determine kubectl client/apiserver versions"

  log "kubectl=${client_version}, apiserver=${server_version}"

  client_minor="$(minor_version "${client_version}")"
  server_minor="$(minor_version "${server_version}")"

  if [[ "${client_minor}" =~ ^[0-9]+$ && "${server_minor}" =~ ^[0-9]+$ ]]; then
    minor_skew=$(( client_minor - server_minor ))
    (( minor_skew < 0 )) && minor_skew=$(( -minor_skew ))

    (( minor_skew <= 1 )) ||
      die "kubectl ${client_version} is outside supported +/-1 minor skew from apiserver ${server_version}"
  fi
}

final_validate() {
  local server_version
  server_version="$(extract_server_version)"

  log "Waiting for all Kubernetes nodes"
  kubectl_cmd wait --for=condition=Ready nodes --all --timeout=10m

  printf '\n========================================\n'
  printf ' Cluster\n'
  printf '========================================\n'
  kubectl_cmd get nodes -o wide

  printf '\n========================================\n'
  printf ' Calico %s\n' "${CALICO_VERSION}"
  printf '========================================\n'
  kubectl_cmd get tigerastatus -o wide
  kubectl_cmd get daemonset calico-node -n calico-system -o wide
  kubectl_cmd get deployment calico-kube-controllers -n calico-system -o wide
  kubectl_cmd get pods -n calico-system -o wide

  printf '\n========================================\n'
  printf ' Metrics Server %s\n' "${METRICS_SERVER_VERSION}"
  printf '========================================\n'
  kubectl_cmd get deployment metrics-server -n kube-system -o wide
  kubectl_cmd get pods -n kube-system -l k8s-app=metrics-server -o wide
  kubectl_cmd get apiservice v1beta1.metrics.k8s.io -o wide
  kubectl_cmd top nodes

  printf '\n========================================\n'
  printf ' Final state\n'
  printf '========================================\n'
  kubectl_cmd get nodes
  kubectl_cmd get pods -A

  printf '\nREADY: kind cluster=%s Kubernetes=%s Calico=%s MetricsServer=%s\n' \
    "${CLUSTER}" "${server_version#v}" "${CALICO_VERSION}" "${METRICS_SERVER_VERSION}"
}

main() {
  validate_inputs
  preflight
  create_kind_config

  # Choose a kubectl that is within the supported +/-1 minor skew BEFORE
  # talking to the newly-created apiserver. No JSON parsing is required.
  ensure_kubectl_compatible

  create_cluster
  validate_cluster_versions
  remove_single_node_control_plane_taint

  install_calico
  configure_calico_for_istio

  # CoreDNS/local-path cannot become Ready until a working CNI exists.
  log "Waiting for all Kubernetes nodes after CNI installation"
  kubectl_cmd wait --for=condition=Ready nodes --all --timeout=10m

  install_metrics_server

  final_validate
}

main "$@"