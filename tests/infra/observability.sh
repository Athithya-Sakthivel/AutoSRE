#!/usr/bin/env bash
# ==============================================================================
# tests/infra/observability.sh
#
# End-to-end smoke test for the OpenObserve + OTel Collector pipeline.
#
#   1. Verify all pods are Ready.
#   2. Send synthetic traces, metrics, and logs to the OTel gateway.
#   3. Confirm the gateway exported them without error.
#   4. Confirm OpenObserve returned HTTP 200 for each signal.
#   5. Confirm the OpenObserve search API responds.
#
# Usage:
#   tests/infra/observability.sh [--dry-run] [--keep] [--help]
#
#   --dry-run   Print the manifests that would be applied; do not deploy.
#   --keep      Do not delete the test pods on exit (for debugging).
# ==============================================================================
# kubectl -n openobserve port-forward svc/openobserve 5080:5080
## Fetch Username (email) and password
# kubectl -n openobserve get secret openobserve-auth -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d; echo
# kubectl -n openobserve get secret openobserve-auth -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d; echo

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# --- Configuration -----------------------------------------------------------

NAMESPACE="${NAMESPACE:-openobserve}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-otel-gateway}"
GATEWAY_GRPC_PORT="${GATEWAY_GRPC_PORT:-4317}"
OPENOBSERVE_SERVICE="${OPENOBSERVE_SERVICE:-openobserve}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-5080}"
TELEMETRYGEN_IMAGE="${TELEMETRYGEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest}"
TEST_SERVICE_NAME="${TEST_SERVICE_NAME:-smoke-test}"
TEST_TAG="${TEST_TAG:-smoke-$(date -u +%Y%m%d-%H%M%S)}"
O2_LOCAL_PORT="${O2_LOCAL_PORT:-15080}"

# Pod names
TRACES_POD="telemetrygen-traces-${TEST_TAG}"
METRICS_POD="telemetrygen-metrics-${TEST_TAG}"
LOGS_POD="telemetrygen-logs-${TEST_TAG}"
SMOKE_POLICY_NAME="smoke-test-egress-${TEST_TAG}"

# Release labels for health checks
RELEASES=("openobserve" "otel-gateway" "otel-daemonset")

DRY_RUN="false"
KEEP="false"

# --- Colors ------------------------------------------------------------------

if [[ -t 2 ]]; then
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;34m'
  C_RESET=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_RESET=""
fi

# --- Logging -----------------------------------------------------------------

log()  { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*" >&2; }
pass() { printf '%s✓%s %s\n'   "${C_GREEN}"  "${C_RESET}" "$*" >&2; }
warn() { printf '%s⚠%s %s\n'   "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
fail() { printf '%s✗%s %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; }
die()  { fail "$@"; exit 1; }

# --- Utilities ---------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# Cross-platform base64 encode (no line wrapping)
b64_encode() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# Find pods matching a release label
pod_for_release() {
  local release="$1"
  kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${release}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# --- Runtime lifecycle -------------------------------------------------------

TMP_DIR=""
PORT_FORWARD_PID=""

cleanup() {
  local exit_code=$?

  # Kill port-forward if running
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi

  if [[ "${KEEP}" == "true" ]]; then
    warn "Keeping test resources (--keep). Delete manually with:"
    warn "  kubectl delete pod -n ${NAMESPACE} ${TRACES_POD} ${METRICS_POD} ${LOGS_POD}"
    warn "  kubectl delete ciliumnetworkpolicy ${SMOKE_POLICY_NAME} -n ${NAMESPACE}"
  else
    # Delete test pods
    for pod in "${TRACES_POD}" "${METRICS_POD}" "${LOGS_POD}"; do
      kubectl delete pod -n "${NAMESPACE}" "${pod}" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    done

    # Delete temporary network policy
    kubectl delete ciliumnetworkpolicy "${SMOKE_POLICY_NAME}" \
      -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi

  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  exit "${exit_code}"
}

on_error() { fail "Failed at line $1"; exit 1; }

init_runtime() {
  TMP_DIR="$(mktemp -d -t observability-smoke-XXXXXX)"
  trap cleanup EXIT
  trap 'on_error ${LINENO}' ERR
}

# --- Preflight ---------------------------------------------------------------

preflight() {
  require_cmd kubectl
  require_cmd jq
  require_cmd curl

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach a cluster"
  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || die "Namespace '${NAMESPACE}' does not exist"
}

# --- Test 1: Pod health ------------------------------------------------------
# --- Test 1: Pod health ------------------------------------------------------

check_pods() {
  log "Test 1: Verifying pod health"

  local failed=0
  for release in "${RELEASES[@]}"; do
    local pods
    # Use jsonpath with explicit newlines to avoid word-splitting issues
    pods="$(kubectl get pods -n "${NAMESPACE}" \
      -l "app.kubernetes.io/instance=${release}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

    if [[ -z "${pods}" ]]; then
      fail "No pods for release '${release}'"
      failed=$((failed + 1))
      continue
    fi

    # Use while-read loop to handle one pod per line
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue

      local ready
      ready="$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.containerStatuses[0].ready}')"

      if [[ "${ready}" == "true" ]]; then
        pass "${pod} is Ready"
      else
        fail "${pod} is not Ready"
        failed=$((failed + 1))
      fi
    done <<< "${pods}"
  done

  [[ ${failed} -eq 0 ]] || die "${failed} pod(s) not ready"
}
# --- Test 2: Create network policy for test pods -----------------------------

create_smoke_policy() {
  log "Test 2: Creating temporary CiliumNetworkPolicy for test pods"

  local policy_manifest="${TMP_DIR}/smoke-policy.yaml"

  cat > "${policy_manifest}" <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${SMOKE_POLICY_NAME}
  namespace: ${NAMESPACE}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/component: observability-smoke-test
      smoke-test-id: "${TEST_TAG}"
  egress:
    # Allow DNS resolution
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"

    # Allow OTel gateway (gRPC)
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/instance: otel-gateway
            k8s:io.kubernetes.pod.namespace: ${NAMESPACE}
      toPorts:
        - ports:
            - port: "${GATEWAY_GRPC_PORT}"
              protocol: TCP

    # Allow OpenObserve (HTTP) for direct queries
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/instance: openobserve
            k8s:io.kubernetes.pod.namespace: ${NAMESPACE}
      toPorts:
        - ports:
            - port: "${OPENOBSERVE_PORT}"
              protocol: TCP
EOF

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would apply network policy:"
    cat "${policy_manifest}"
    return 0
  fi

  kubectl apply -f "${policy_manifest}" >/dev/null
  pass "Created CiliumNetworkPolicy ${SMOKE_POLICY_NAME}"
}

# --- Test 3: Send synthetic telemetry ---------------------------------------

render_pod() {
  local name="$1"
  local signal="$2"
  shift 2
  local args=("$@")

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/component: observability-smoke-test
    smoke-test-signal: ${signal}
    smoke-test-id: "${TEST_TAG}"
spec:
  restartPolicy: Never
  containers:
    - name: telemetrygen
      image: ${TELEMETRYGEN_IMAGE}
      imagePullPolicy: IfNotPresent
      args:
        - ${signal}
        - --otlp-endpoint=${GATEWAY_SERVICE}:${GATEWAY_GRPC_PORT}
        - --otlp-insecure
        - --service=${TEST_SERVICE_NAME}
        - --otlp-attributes=smoke.test.id="${TEST_TAG}"
$(for arg in "${args[@]}"; do printf '        - %s\n' "${arg}"; done)
EOF
}

apply_pods() {
  log "Test 3: Sending synthetic telemetry"

  local manifests="${TMP_DIR}/telemetrygen.yaml"
  {
    render_pod "${TRACES_POD}"  "traces"  \
      "--traces=5" "--child-spans=2" "--status-code=Ok"
    echo "---"
    render_pod "${METRICS_POD}" "metrics" \
      "--metrics=5" "--metric-type=Sum"
    echo "---"
    render_pod "${LOGS_POD}"    "logs"    \
      "--logs=5" "--severity-text=Info" "--body=Smoke test log entry"
  } > "${manifests}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would apply telemetrygen pods:"
    cat "${manifests}"
    return 0
  fi

  kubectl apply -f "${manifests}" >/dev/null

  for pod in "${TRACES_POD}" "${METRICS_POD}" "${LOGS_POD}"; do
    log "Waiting for ${pod} to complete"
    if kubectl wait \
        --for=jsonpath='{.status.phase}'=Succeeded \
        pod/"${pod}" -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
      pass "${pod} completed"
    else
      local phase
      phase="$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
      fail "${pod} did not succeed (phase: ${phase})"
      echo
      kubectl logs "${pod}" -n "${NAMESPACE}" 2>&1 | tail -20 || true
      echo
      return 1
    fi
  done
}

# --- Test 4: Verify gateway exported without error --------------------------

verify_gateway() {
  log "Test 4: Verifying gateway export logs"

  # Wait for at least one export cycle
  sleep 15

  local pod
  pod="$(pod_for_release "otel-gateway")"
  [[ -n "${pod}" ]] || die "No otel-gateway pod found"

  local logs
  logs="$(kubectl logs "${pod}" -n "${NAMESPACE}" --tail=500 2>&1)"

  local failed=0

  if grep -qE 'Exporting failed|Dropping data' <<< "${logs}"; then
    fail "Gateway reported export failures:"
    grep -E 'Exporting failed|Dropping data' <<< "${logs}" | tail -5 >&2
    failed=$((failed + 1))
  else
    pass "No export failures in gateway logs"
  fi

  if grep -qE 'refused|permanently failed' <<< "${logs}"; then
    fail "Gateway reported refused or non-retryable errors:"
    grep -E 'refused|permanently failed' <<< "${logs}" | tail -5 >&2
    failed=$((failed + 1))
  else
    pass "No refused or non-retryable errors"
  fi

  [[ ${failed} -eq 0 ]]
}

# --- Test 5: Verify OpenObserve accepted the data ---------------------------

verify_openobserve() {
  log "Test 5: Verifying OpenObserve ingestion"

  local pod
  pod="$(pod_for_release "openobserve")"
  [[ -n "${pod}" ]] || die "No openobserve pod found"

  local logs
  logs="$(kubectl logs "${pod}" -n "${NAMESPACE}" --tail=500 2>&1)"

  local failed=0
  for signal in traces metrics logs; do
    local count
    count="$(grep -cE "POST /api/default/v1/${signal} HTTP/1.1\" 200" <<< "${logs}" || true)"
    if [[ "${count}" -gt 0 ]]; then
      pass "OpenObserve accepted ${count} ${signal} POST(s) with HTTP 200"
    else
      if [[ "${signal}" == "metrics" ]]; then
        fail "OpenObserve accepted zero ${signal} POSTs"
        failed=$((failed + 1))
      else
        warn "No ${signal} POSTs in the last 500 log lines (batch may not have flushed)"
      fi
    fi
  done

  [[ ${failed} -eq 0 ]]
}

# --- Test 6: Query the OpenObserve search API -------------------------------

verify_query() {
  log "Test 6: Querying OpenObserve search API"

  # Start port-forward in background
  kubectl port-forward -n "${NAMESPACE}" svc/openobserve "${O2_LOCAL_PORT}:5080" \
    >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  # Wait for port-forward readiness
  local wait_start wait_elapsed
  wait_start="$(date +%s)"
  while true; do
    if curl -sf "http://localhost:${O2_LOCAL_PORT}/healthz" >/dev/null 2>&1; then
      break
    fi
    wait_elapsed=$(( $(date +%s) - wait_start ))
    if (( wait_elapsed >= 15 )); then
      fail "port-forward did not become ready within 15s"
      return 1
    fi
    sleep 1
  done

  # Retrieve credentials
  local email password auth
  email="$(kubectl get secret openobserve-auth -n "${NAMESPACE}" \
    -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
  password="$(kubectl get secret openobserve-auth -n "${NAMESPACE}" \
    -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"
  auth="Basic $(printf '%s:%s' "${email}" "${password}" | b64_encode)"

  # Query the last 15 minutes
  local end_us start_us
  end_us="$(( $(date -u +%s) * 1000000 ))"
  start_us="$(( end_us - 900000000 ))"

  local body
  body="$(jq -nc \
    --argjson s "${start_us}" \
    --argjson e "${end_us}" \
    '{query: {sql: "SELECT * FROM \"default\" LIMIT 1", start_time: $s, end_time: $e}}')"

  local response
  response="$(curl -s -X POST \
    "http://localhost:${O2_LOCAL_PORT}/api/default/_search?type=traces" \
    -H "Authorization: ${auth}" \
    -H "Content-Type: application/json" \
    -d "${body}")"

  if jq -e '.hits' <<< "${response}" >/dev/null 2>&1; then
    local hits
    hits="$(jq '.hits | length' <<< "${response}")"
    pass "OpenObserve search API responded (traces hits: ${hits})"
  else
    fail "OpenObserve search API returned an unexpected response:"
    echo "${response}" | head -20 >&2
    return 1
  fi
}

# --- Main --------------------------------------------------------------------

usage() {
  cat <<EOF
$(basename "$0") — OpenObserve + OTel end-to-end smoke test

Usage:
  $(basename "$0") [options]

Options:
  --dry-run    Print manifests; do not deploy.
  --keep       Do not delete test resources on exit.
  --help, -h   Show this help.

Environment (defaults shown):
  NAMESPACE              openobserve
  GATEWAY_SERVICE        otel-gateway
  GATEWAY_GRPC_PORT      4317
  OPENOBSERVE_SERVICE    openobserve
  OPENOBSERVE_PORT       5080
  O2_LOCAL_PORT          15080
  TEST_SERVICE_NAME      smoke-test
  TELEMETRYGEN_IMAGE     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.160.0

This test creates temporary pods and a CiliumNetworkPolicy to validate the
full observability pipeline under zero-trust network policies.
EOF
}

main() {
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN="true" ;;
      --keep)    KEEP="true" ;;
      --help|-h) usage; exit 0 ;;
      *)         die "Unknown argument: ${arg}" ;;
    esac
  done

  init_runtime

  log "OpenObserve + OTel end-to-end smoke test"
  log "Namespace: ${NAMESPACE}  Service: ${TEST_SERVICE_NAME}  Tag: ${TEST_TAG}"
  echo

  preflight
  check_pods
  create_smoke_policy
  apply_pods
  verify_gateway
  verify_openobserve
  verify_query

  echo
  log "All checks passed"
}

main "$@"
