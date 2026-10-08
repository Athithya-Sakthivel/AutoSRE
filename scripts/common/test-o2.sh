#!/usr/bin/env bash
# ==============================================================================
# End-to-end smoke test for the OpenObserve + OTel Collector pipeline.
#
# Tests the full observability pipeline under Cilium zero-trust networking:
#   1. Verify all observability pods are Ready.
#   2. Create a temporary CiliumNetworkPolicy for test pods.
#   3. Wait for eBPF policy compilation + Cilium identity assignment.
#   4. Send synthetic traces, metrics, and logs via gRPC on port 4317.
#   5. Confirm the gateway exported them without error.
#   6. Confirm OpenObserve accepted the POST requests.
#   7. Confirm the OpenObserve search API returns the test data.
#
# Usage:
#   bash scripts/common/test-o2.sh [--dry-run] [--keep] [--help]
#
#   --dry-run   Print manifests only; do not deploy.
#   --keep      Do not delete test resources on exit (for debugging).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# --- Configuration -----------------------------------------------------------

NAMESPACE="${NAMESPACE:-openobserve}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-otel-gateway}"
GATEWAY_GRPC_PORT="${GATEWAY_GRPC_PORT:-4317}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-4318}"
OPENOBSERVE_SERVICE="${OPENOBSERVE_SERVICE:-openobserve}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-5080}"
TELEMETRYGEN_IMAGE="${TELEMETRYGEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.157.0}"
TEST_SERVICE_NAME="${TEST_SERVICE_NAME:-smoke-test}"
TEST_TAG="${TEST_TAG:-smoke-$(date -u +%Y%m%d-%H%M%S)}"
O2_LOCAL_PORT="${O2_LOCAL_PORT:-15080}"
TEST_START_TIME=""
TEST_START_US=""
QUERY_RETRY_SECONDS="${QUERY_RETRY_SECONDS:-60}"
QUERY_RETRY_INTERVAL="${QUERY_RETRY_INTERVAL:-3}"

# Critical: Cilium needs time to compile policy into eBPF on each node AND
# assign identities to new pods. Default 15s is safe; reduce only if confident.
POLICY_PROPAGATION_SECONDS="${POLICY_PROPAGATION_SECONDS:-15}"
IDENTITY_WAIT_SECONDS="${IDENTITY_WAIT_SECONDS:-30}"

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

b64_encode() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

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

  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi

  if [[ "${KEEP}" == "true" ]]; then
    warn "Keeping test resources (--keep). Delete manually with:"
    warn "  kubectl delete pod -n ${NAMESPACE} ${TRACES_POD} ${METRICS_POD} ${LOGS_POD} --ignore-not-found"
    warn "  kubectl delete ciliumnetworkpolicy ${SMOKE_POLICY_NAME} -n ${NAMESPACE} --ignore-not-found"
  else
    for pod in "${TRACES_POD}" "${METRICS_POD}" "${LOGS_POD}"; do
      kubectl delete pod -n "${NAMESPACE}" "${pod}" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    done
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

  # Verify the otel-gateway-ingress policy allows smoke-test pods.
  # This is the #1 cause of smoke test failures — without this rule,
  # telemetrygen pods are dropped at the gateway's ingress hook.
  local ingress_yaml
  ingress_yaml="$(kubectl get cnp otel-gateway-ingress -n "${NAMESPACE}" -o yaml 2>/dev/null || true)"
  if [[ -z "${ingress_yaml}" ]]; then
    warn "otel-gateway-ingress CNP not found. Smoke test may fail."
  elif ! grep -q "observability-smoke-test" <<<"${ingress_yaml}"; then
    fail "otel-gateway-ingress CNP is MISSING the smoke-test ingress rule."
    fail "Add this rule to infra/k8s/cilium/templates/10-openobserve-internal.yaml:"
    fail "    - fromEndpoints:"
    fail "        - matchLabels:"
    fail "            app.kubernetes.io/component: observability-smoke-test"
    fail "      toPorts:"
    fail "        - ports:"
    fail "            - port: \"4317\""
    fail "            - port: \"4318\""
    fail "Then run: helm upgrade --install autosre-cilium infra/k8s/cilium/ --namespace kube-system"
    die "Cannot proceed without smoke-test ingress rule"
  fi
  pass "otel-gateway-ingress CNP has smoke-test rule"

  # Clean up stale resources from previous runs
  local stale_policies
  stale_policies="$(kubectl get ciliumnetworkpolicy -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep '^smoke-test-egress-' || true)"

  if [[ -n "${stale_policies}" ]]; then
    warn "Cleaning up stale smoke-test policies:"
    while IFS= read -r policy; do
      [[ -z "${policy}" ]] && continue
      warn "  Deleting: ${policy}"
      kubectl delete ciliumnetworkpolicy "${policy}" \
        -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    done <<<"${stale_policies}"
    sleep 2
  fi

  local stale_pods
  stale_pods="$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/component=observability-smoke-test" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -n "${stale_pods}" ]]; then
    warn "Cleaning up stale smoke-test pods:"
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue
      warn "  Deleting: ${pod}"
      kubectl delete pod "${pod}" -n "${NAMESPACE}" \
        --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    done <<<"${stale_pods}"
    sleep 2
  fi
}

# --- Test 1: Pod health ------------------------------------------------------

check_pods() {
  log "Test 1: Verifying pod health"

  local failed=0
  for release in "${RELEASES[@]}"; do
    local pods
    pods="$(kubectl get pods -n "${NAMESPACE}" \
      -l "app.kubernetes.io/instance=${release}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

    if [[ -z "${pods}" ]]; then
      fail "No pods for release '${release}'"
      failed=$((failed + 1))
      continue
    fi

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
    done <<<"${pods}"
  done

  [[ ${failed} -eq 0 ]] || die "${failed} pod(s) not ready"
}

# --- Test 2: Create network policy for test pods -----------------------------

create_smoke_policy() {
  log "Test 2: Creating temporary CiliumNetworkPolicy for test pods"

  local policy_manifest="${TMP_DIR}/smoke-policy.yaml"

  cat >"${policy_manifest}" <<EOF
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

    # Allow OTel gateway (gRPC + HTTP) — same namespace
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: otel-gateway
            k8s:io.kubernetes.pod.namespace: ${NAMESPACE}
      toPorts:
        - ports:
            - port: "${GATEWAY_GRPC_PORT}"
              protocol: TCP
            - port: "${GATEWAY_HTTP_PORT}"
              protocol: TCP

    # Allow OpenObserve (HTTP) for direct queries — same namespace
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: open-observe-minimal
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

  log "Waiting for CiliumNetworkPolicy to be validated..."
  if ! kubectl wait --for=condition=Valid \
    ciliumnetworkpolicy/"${SMOKE_POLICY_NAME}" \
    -n "${NAMESPACE}" --timeout=30s 2>/dev/null; then
    fail "CiliumNetworkPolicy did not become Valid within 30s"
    kubectl describe ciliumnetworkpolicy "${SMOKE_POLICY_NAME}" -n "${NAMESPACE}" >&2 || true
    return 1
  fi
  pass "CiliumNetworkPolicy ${SMOKE_POLICY_NAME} is Valid"

  log "Waiting ${POLICY_PROPAGATION_SECONDS}s for eBPF policy compilation..."
  sleep "${POLICY_PROPAGATION_SECONDS}"
  pass "Policy propagation wait complete"
}

# --- Test 3: Send synthetic telemetry ----------------------------------------

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

wait_for_pod_identity() {
  # Wait for Cilium to assign an identity to each smoke pod. Without an
  # identity, the pod's egress traffic is dropped by default-deny even if
  # an egress policy exists.
  log "Waiting up to ${IDENTITY_WAIT_SECONDS}s for Cilium identities on smoke pods..."

  local all_have_identity=true
  for pod in "${TRACES_POD}" "${METRICS_POD}" "${LOGS_POD}"; do
    local start
    start="$(date +%s)"
    local has_identity=false

    while (( $(date +%s) - start < IDENTITY_WAIT_SECONDS )); do
      # Check if pod exists and has a CiliumEndpoint with an identity
      if kubectl get cep "${pod}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.identity.id}' 2>/dev/null | grep -qE '^[0-9]+$'; then
        has_identity=true
        break
      fi
      sleep 1
    done

    if [[ "${has_identity}" == "true" ]]; then
      pass "Pod ${pod} has Cilium identity"
    else
      fail "Pod ${pod} did not get a Cilium identity within ${IDENTITY_WAIT_SECONDS}s"
      all_have_identity=false
    fi
  done

  if [[ "${all_have_identity}" != "true" ]]; then
    warn "Some pods lack Cilium identities. Traffic may be dropped by default-deny."
    warn "This usually means Cilium agents are slow to process new pods."
    warn "Waiting an additional 10s to give Cilium more time..."
    sleep 10
  fi

  # Extra settle time after identity assignment
  sleep 3
}

apply_pods() {
  log "Test 3: Sending synthetic telemetry"

  local manifests="${TMP_DIR}/telemetrygen.yaml"
  {
    render_pod "${TRACES_POD}" "traces" \
      "--traces=5" "--child-spans=2" "--status-code=Ok"
    echo "---"
    render_pod "${METRICS_POD}" "metrics" \
      "--metrics=5" "--metric-type=Sum"
    echo "---"
    render_pod "${LOGS_POD}" "logs" \
      "--logs=5" "--severity-text=Info" "--body=Smoke test log entry"
  } >"${manifests}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Would apply telemetrygen pods:"
    cat "${manifests}"
    return 0
  fi

  kubectl apply -f "${manifests}" >/dev/null

  # Wait for Cilium identities BEFORE waiting for completion
  wait_for_pod_identity

  local failed=0
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
      kubectl logs "${pod}" -n "${NAMESPACE}" 2>&1 | tail -30 || true
      echo
      diagnose_drop "${pod}"
      failed=$((failed + 1))
    fi
  done

  [[ ${failed} -eq 0 ]] || die "${failed} telemetrygen pod(s) failed"
}

# --- Diagnostics -------------------------------------------------------------

diagnose_drop() {
  # Capture Cilium drop events during a failing pod's lifetime
  local pod="$1"
  warn "Running Cilium drop diagnostics for ${pod}..."

  local pod_ip
  pod_ip="$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

  if [[ -z "${pod_ip}" ]]; then
    warn "  Could not get pod IP for ${pod}"
    return 0
  fi

  local node
  node="$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"

  if [[ -z "${node}" ]]; then
    warn "  Could not get node for ${pod}"
    return 0
  fi

  local cilium_pod
  cilium_pod="$(kubectl get pods -n kube-system -l k8s-app=cilium \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "${cilium_pod}" ]]; then
    warn "  Could not find Cilium agent on node ${node}"
    return 0
  fi

  warn "  Capturing drops involving ${pod_ip} from ${cilium_pod}..."
  kubectl exec -n kube-system "${cilium_pod}" -c cilium-agent -- \
    cilium-dbg monitor --last 1000 --type drop 2>/dev/null \
    | grep "${pod_ip}" \
    | head -20 \
    | sed 's/^/    /' >&2 || true
}

# --- Test 4: Verify gateway exported this test without error ----------------

verify_gateway() {
  log "Test 4: Verifying gateway export logs for this test run"

  sleep 15

  local pod
  pod="$(pod_for_release "otel-gateway")"
  [[ -n "${pod}" ]] || die "No otel-gateway pod found"

  local logs
  logs="$(kubectl logs "${pod}" -n "${NAMESPACE}" \
    --since-time="${TEST_START_TIME}" 2>&1)"

  local export_failures nonretryable
  export_failures="$(grep -E 'Exporting failed|Dropping data' <<<"${logs}" \
    | grep 'otlp_http/openobserve' || true)"
  nonretryable="$(grep -Ei 'refused|permanently failed' <<<"${logs}" \
    | grep 'otlp_http/openobserve' || true)"

  if [[ -n "${export_failures}" ]]; then
    fail "Gateway reported OpenObserve export failures during this test run:"
    tail -10 <<<"${export_failures}" >&2
    return 1
  fi
  pass "No OpenObserve export failures during this test run"

  if [[ -n "${nonretryable}" ]]; then
    fail "Gateway reported non-retryable OpenObserve export errors during this test run:"
    tail -10 <<<"${nonretryable}" >&2
    return 1
  fi
  pass "No non-retryable OpenObserve export errors during this test run"
}

# --- Test 5: Verify OpenObserve accepted this test run ---------------------

verify_openobserve() {
  log "Test 5: Verifying OpenObserve accepted telemetry from this test run"

  local pod
  pod="$(pod_for_release "openobserve")"
  [[ -n "${pod}" ]] || die "No openobserve pod found"

  local logs
  logs="$(kubectl logs "${pod}" -n "${NAMESPACE}" \
    --since-time="${TEST_START_TIME}" 2>&1)"

  local failed=0
  for signal in traces metrics logs; do
    local count
    count="$(grep -cE "POST /api/default/v1/${signal} HTTP/1.1\" 200" <<<"${logs}" || true)"
    if [[ "${count}" -gt 0 ]]; then
      pass "OpenObserve accepted ${count} ${signal} POST(s) with HTTP 200 during this test run"
    else
      fail "OpenObserve accepted zero ${signal} POSTs during this test run"
      failed=$((failed + 1))
    fi
  done

  [[ ${failed} -eq 0 ]]
}

# --- SQL helpers -------------------------------------------------------------

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_identifier_escape() {
  printf '%s' "$1" | sed 's/"/""/g'
}

discover_smoke_targets() {
  local signal="$1"
  local streams_json="$2"

  jq -r '
    .list[]?
    | .name as $stream
    | ([.schema[]?.name | select(test("(^|_)smoke_test_id$"; "i"))] | .[]) as $field
    | [$stream, $field]
    | @tsv
  ' <<<"${streams_json}"
}

search_smoke_target() {
  local signal="$1"
  local stream="$2"
  local field="$3"
  local sql_tag="$4"
  local start_us="$5"
  local end_us="$6"

  local stream_sql field_sql sql body response
  stream_sql="$(sql_identifier_escape "${stream}")"
  field_sql="$(sql_identifier_escape "${field}")"

  sql="SELECT * FROM \"${stream_sql}\" WHERE \"${field_sql}\" = '${sql_tag}' ORDER BY _timestamp DESC LIMIT 1"

  body="$(jq -nc \
    --arg sql "${sql}" \
    --arg start_us "${start_us}" \
    --arg end_us "${end_us}" \
    '{query:{sql:$sql,start_time:($start_us|tonumber),end_time:($end_us|tonumber),from:0,size:1},search_type:"ui",timeout:30}')"

  response="$(curl -sS \
    -X POST "http://localhost:${O2_LOCAL_PORT}/api/default/_search?type=${signal}" \
    -H "Authorization: ${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${body}")"

  if jq -e '.hits? and (.hits | length > 0)' <<<"${response}" >/dev/null 2>&1; then
    printf '%s\n' "${response}"
    return 0
  fi

  return 1
}

# --- Test 6: Query the OpenObserve search API -------------------------------

verify_query() {
  log "Test 6: Verifying test-specific data through the OpenObserve search API"

  kubectl port-forward -n "${NAMESPACE}" svc/openobserve "${O2_LOCAL_PORT}:5080" \
    >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  local wait_start wait_elapsed
  wait_start="$(date +%s)"
  while true; do
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      fail "port-forward exited before becoming ready"
      return 1
    fi
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

  local email password
  email="$(kubectl get secret openobserve-auth -n "${NAMESPACE}" \
    -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
  password="$(kubectl get secret openobserve-auth -n "${NAMESPACE}" \
    -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)"
  AUTH_HEADER="Basic $(printf '%s:%s' "${email}" "${password}" | b64_encode)"

  local sql_tag
  sql_tag="$(sql_escape "${TEST_TAG}")"

  local query_start_us
  query_start_us=$(( TEST_START_US - 30000000 ))
  (( query_start_us < 0 )) && query_start_us=0

  local signal streams_json targets target_stream target_field
  local deadline end_us response found target_count
  for signal in traces metrics logs; do
    found=0
    response=""
    targets=""
    deadline=$(( $(date +%s) + QUERY_RETRY_SECONDS ))

    while (( $(date +%s) < deadline )); do
      if streams_json="$(curl -fsS \
        -u "${email}:${password}" \
        "http://localhost:${O2_LOCAL_PORT}/api/default/streams?type=${signal}&fetchSchema=true" 2>/dev/null)"; then
        targets="$(discover_smoke_targets "${signal}" "${streams_json}" || true)"
      else
        targets=""
      fi

      target_count=0
      [[ -n "${targets}" ]] && target_count="$(wc -l <<<"${targets}")"

      if (( target_count > 0 )); then
        end_us=$(( $(date -u +%s) * 1000000 + 60000000 ))

        while IFS=$'\t' read -r target_stream target_field; do
          [[ -z "${target_stream}" || -z "${target_field}" ]] && continue

          if response="$(search_smoke_target \
            "${signal}" \
            "${target_stream}" \
            "${target_field}" \
            "${sql_tag}" \
            "${query_start_us}" \
            "${end_us}")"; then
            local hits
            hits="$(jq '.hits | length' <<<"${response}")"
            pass "OpenObserve search found ${hits} ${signal} record(s) for ${TEST_TAG} in ${target_stream} using ${target_field}"
            found=1
            break
          fi
        done <<<"${targets}"
      fi

      (( found == 1 )) && break
      sleep "${QUERY_RETRY_INTERVAL}"
    done

    if (( found == 0 )); then
      fail "OpenObserve search found no ${signal} records for ${TEST_TAG} after ${QUERY_RETRY_SECONDS}s"
      if [[ -n "${targets}" ]]; then
        fail "Discovered ${signal} target(s):"
        while IFS=$'\t' read -r target_stream target_field; do
          [[ -n "${target_stream}" ]] && printf '  stream=%s field=%s\n' "${target_stream}" "${target_field}" >&2
        done <<<"${targets}"
      else
        fail "No ${signal} stream currently exposes a smoke_test_id field"
      fi
      return 1
    fi
  done
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
  NAMESPACE                    openobserve
  GATEWAY_SERVICE              otel-gateway
  GATEWAY_GRPC_PORT            4317
  GATEWAY_HTTP_PORT            4318
  OPENOBSERVICE_SERVICE        openobserve
  OPENOBSERVE_PORT             5080
  O2_LOCAL_PORT                15080
  TEST_SERVICE_NAME            smoke-test
  TELEMETRYGEN_IMAGE           ghcr.io/.../telemetrygen:v0.157.0
  QUERY_RETRY_SECONDS          60
  QUERY_RETRY_INTERVAL         3
  POLICY_PROPAGATION_SECONDS   15
  IDENTITY_WAIT_SECONDS        30

Prerequisite: The otel-gateway-ingress CiliumNetworkPolicy must include a
fromEndpoints rule matching app.kubernetes.io/component: observability-smoke-test.
EOF
}

main() {
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN="true" ;;
      --keep) KEEP="true" ;;
      --help | -h) usage; exit 0 ;;
      *) die "Unknown argument: ${arg}" ;;
    esac
  done

  init_runtime

  log "OpenObserve + OTel end-to-end smoke test"
  log "Namespace: ${NAMESPACE}  Service: ${TEST_SERVICE_NAME}  Tag: ${TEST_TAG}"
  echo

  preflight
  check_pods
  create_smoke_policy

  TEST_START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TEST_START_US="$(( $(date -u +%s) * 1000000 ))"
  log "Test run start: ${TEST_START_TIME}"

  apply_pods

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run complete"
    exit 0
  fi

  verify_gateway
  verify_openobserve
  verify_query

  echo
  log "All checks passed"
}

main "$@"
