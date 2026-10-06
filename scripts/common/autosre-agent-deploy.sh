#!/usr/bin/env bash
# ==============================================================================
# autosre-agent-deploy.sh — AutoSRE Agent lifecycle manager
#
# Renders and applies the AutoSRE agent stack:
#   1. ServiceAccount + RBAC — least-privilege permissions (no secrets access)
#   2. Deployment            — Python FastAPI agent, distroless
#   3. Service               — ClusterIP :8000 (HTTP API + webhooks)
#
# Image tag policy:
#   Default "latest" — matches build_all_images.sh convention.
#   Use --resolve-sha to lock to the local image's sha256.
#     latest        -> imagePullPolicy: Always
#     anything else -> imagePullPolicy: IfNotPresent
#
# Secrets contract (all created by eso_local.sh):
#   autosre-agent-secrets   AUTOSRE_* (86 keys including Valkey)
#   postgres-agent          POSTGRES_HOST/PORT/DB/USER/PASSWORD/URI
#   openobserve-reader      email/password/url
#   otel-exporter-headers   otel-exporter-headers (optional)
#
# Cilium contract (see infra/k8s/cilium/templates/):
#   * sre-agent-egress     — egress to kube-apiserver, postgres, valkey, openobserve, otel-gw, world
#   * sre-agent-ingress    — ingress :8000 (openobserve webhooks, eval, host)
#   * allow-dns-egress     — DNS resolution
#   * default-deny         — Cilium endpoint isolation
#
# Dependencies (must be deployed before this script):
#   1. scripts/staging/eso_local.sh          — ESO + all secrets
#   2. infra/k8s/cilium/templates/           — Cilium network policies
#   3. scripts/staging/postgres.sh           — Postgres in rivulet namespace
#   4. scripts/staging/valkey-deploy.sh      — Valkey in rivulet namespace
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-sre}"
APP_NAME="${APP_NAME:-autosre-agent}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/athithya-sakthivel/autosre-agent}"
IMAGE_TAG="${IMAGE_TAG:-4fe4ee8}"

DEPLOYMENT_ENVIRONMENT="${DEPLOYMENT_ENVIRONMENT:-staging}"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-autosre-agent}"

# Service DNS — cross-namespace references (rivulet namespace)
PG_HOST="${PG_HOST:-postgres.rivulet.svc.cluster.local}"
PG_PORT="${PG_PORT:-5432}"
VALKEY_HOST="${VALKEY_HOST:-valkey.rivulet.svc.cluster.local}"
VALKEY_PORT="${VALKEY_PORT:-6379}"
OBSERVE_URL="${OBSERVE_URL:-http://openobserve.openobserve.svc.cluster.local:5080}"
OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://otel-gateway.openobserve.svc.cluster.local:4318}"

# Secret names (all in sre namespace, created by eso_local.sh)
AGENT_SECRETS="${AGENT_SECRETS:-autosre-agent-secrets}"
PG_SECRET="${PG_SECRET:-postgres-agent}"
OBSERVE_SECRET="${OBSERVE_SECRET:-openobserve-reader}"
OTEL_HEADERS_SECRET="${OTEL_HEADERS_SECRET:-otel-exporter-headers}"

# Cilium sanity check
REQUIRED_CNPS=(
  default-deny
  allow-dns-egress
  sre-agent-egress
  sre-agent-ingress
)

REPLICAS="${REPLICAS:-1}"
HTTP_PORT="${HTTP_PORT:-8000}"
INIT_IMAGE="${INIT_IMAGE:-docker.io/library/busybox:1.37-musl}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GEN_DIR="${GEN_DIR:-${REPO_ROOT}/infra/k8s/generated/autosre-agent}"

WORK_DIR=""
PRESERVE_WORK_DIR=false

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'
log_info()   { printf "${C_CYAN}[%s]${C_RESET} [INFO]  %s\n"  "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_warn()   { printf "${C_YELLOW}[%s]${C_RESET} [WARN]  %s\n" "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_error()  { printf "${C_RED}[%s]${C_RESET} [ERROR] %s\n"   "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_success(){ printf "${C_GREEN}[%s]${C_RESET} [OK]    %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }
die()        { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Image helpers
# ------------------------------------------------------------------------------
resolve_image_sha() {
  local ref="$1"
  local full_id
  full_id="$(docker inspect --format='{{.Id}}' "${ref}" 2>/dev/null || true)"
  [[ -n "${full_id}" ]] || die "docker has no image '${ref}'. Build it first."
  local short
  short="${full_id#sha256:}"
  short="${short:0:12}"
  printf 'sha-%s' "${short}"
}

pull_policy_for() {
  case "$1" in
    latest|"" ) printf 'Always' ;;
    *        ) printf 'IfNotPresent' ;;
  esac
}

# ------------------------------------------------------------------------------
# Cleanup & Diagnostics
# ------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  set +e
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    if [[ "${PRESERVE_WORK_DIR}" == "true" || "${rc}" -ne 0 ]]; then
      log_info "Work directory preserved for inspection: ${WORK_DIR}"
    else
      rm -rf -- "${WORK_DIR}"
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

init_work_dir() {
  WORK_DIR="$(mktemp -d -t autosre-agent.XXXXXX)"
  chmod 0700 "${WORK_DIR}"
}

collect_diagnostics() {
  log_error "--- Pods ---"
  kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${APP_NAME}" -o wide 2>&1 | sed 's/^/  /' || true
  log_error "--- Deployment Events (last 20) ---"
  kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp \
    --field-selector "involvedObject.name=${APP_NAME}" 2>&1 | tail -n 20 | sed 's/^/  /' || true
  log_error "--- Secrets (existence) ---"
  local s
  for s in "${AGENT_SECRETS}" "${PG_SECRET}" "${OBSERVE_SECRET}" "${OTEL_HEADERS_SECRET}"; do
    if kubectl -n "${NAMESPACE}" get secret "${s}" >/dev/null 2>&1; then
      printf '  %s: present\n' "${s}" >&2
    else
      printf '  %s: MISSING\n' "${s}" >&2
    fi
  done
  log_error "--- Agent secret key count ---"
  local key_count
  key_count="$(kubectl -n "${NAMESPACE}" get secret "${AGENT_SECRETS}" -o jsonpath='{.data}' 2>/dev/null | jq 'keys | length' 2>/dev/null || echo "?")"
  printf '  %s: %s keys\n' "${AGENT_SECRETS}" "${key_count}" >&2
  log_error "--- Valkey keys in agent secret ---"
  kubectl -n "${NAMESPACE}" get secret "${AGENT_SECRETS}" -o json 2>/dev/null | \
    jq -r '.data | keys[] | select(startswith("AUTOSRE_VALKEY"))' 2>/dev/null | sed 's/^/  /' >&2 || true
  log_error "--- CiliumNetworkPolicies ---"
  kubectl -n "${NAMESPACE}" get cnp -o wide 2>&1 | sed 's/^/  /' || true

  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    log_error "--- Pod Describe (tail 40) ---"
    kubectl -n "${NAMESPACE}" describe pod "${pod}" 2>&1 | tail -n 40 | sed 's/^/  /' || true
    log_error "--- Init container logs ---"
    kubectl -n "${NAMESPACE}" logs "${pod}" -c wait-for-datastores --tail=40 2>&1 | sed 's/^/  /' || true
    log_error "--- App logs (tail 80) ---"
    kubectl -n "${NAMESPACE}" logs "${pod}" -c "${APP_NAME}" --tail=80 2>&1 | sed 's/^/  /' || true
  fi
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight_cilium() {
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq not installed — skipping Cilium policy sanity check."
    return 0
  fi

  local missing=()
  local cnp
  for cnp in "${REQUIRED_CNPS[@]}"; do
    if ! kubectl -n "${NAMESPACE}" get cnp "${cnp}" >/dev/null 2>&1; then
      missing+=("${cnp}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_warn "Missing required CiliumNetworkPolicies: ${missing[*]}"
    log_warn "Apply infra/k8s/cilium/templates/ before deploying."
    log_warn "Under Cilium default-deny, a missing INGRESS rule on the"
    log_warn "destination pod causes a silent SYN drop — init container hangs."
  fi

  local invalid
  invalid="$(kubectl -n "${NAMESPACE}" get cnp \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Valid")].status}{"\n"}{end}' \
    2>/dev/null | awk '$2 != "True" {print $1}' || true)"
  if [[ -n "${invalid}" ]]; then
    log_warn "CiliumNetworkPolicies with VALID != True:"
    printf '  %s\n' ${invalid} >&2
    log_warn "Run: kubectl -n ${NAMESPACE} describe cnp <name>"
  fi
}

preflight_secrets() {
  # Verify autosre-agent-secrets has Valkey keys
  if kubectl -n "${NAMESPACE}" get secret "${AGENT_SECRETS}" >/dev/null 2>&1; then
    local valkey_count
    valkey_count="$(kubectl -n "${NAMESPACE}" get secret "${AGENT_SECRETS}" -o json 2>/dev/null | \
      jq '[.data | keys[] | select(startswith("AUTOSRE_VALKEY"))] | length' 2>/dev/null || echo "0")"
    if [[ "${valkey_count}" -lt 4 ]]; then
      log_warn "autosre-agent-secrets has only ${valkey_count}/4 Valkey keys."
      log_warn "Re-run scripts/staging/eso_local.sh with the updated script."
    else
      log_info "autosre-agent-secrets has all 4 Valkey keys"
    fi
  fi
}

preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

  [[ -n "${IMAGE_TAG}" ]] || die "IMAGE_TAG is empty."
  [[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "IMAGE_TAG '${IMAGE_TAG}' is not a valid Docker tag."

  log_info "Target namespace: ${NAMESPACE}"
  log_info "Target image:     ${IMAGE_REPO}:${IMAGE_TAG}"
  log_info "Pull policy:      ${PULL_POLICY}"
  log_info "Postgres:         ${PG_HOST}:${PG_PORT}  secret=${PG_SECRET}"
  log_info "Valkey:           ${VALKEY_HOST}:${VALKEY_PORT}"
  log_info "OpenObserve:      ${OBSERVE_URL}  secret=${OBSERVE_SECRET}"
  log_info "OTel:             ${OTEL_ENDPOINT}"
  log_info "HTTP port:        ${HTTP_PORT}"

  if ! kubectl -n rivulet get svc postgres >/dev/null 2>&1; then
    log_warn "Service 'postgres' not found in namespace 'rivulet'."
    log_warn "Init container will block until it appears."
  fi
  if ! kubectl -n rivulet get svc valkey >/dev/null 2>&1; then
    log_warn "Service 'valkey' not found in namespace 'rivulet'."
    log_warn "Init container will block until it appears."
  fi

  local s
  for s in "${AGENT_SECRETS}" "${PG_SECRET}" "${OBSERVE_SECRET}"; do
    if ! kubectl -n "${NAMESPACE}" get secret "${s}" >/dev/null 2>&1; then
      log_warn "Secret '${s}' not found in namespace '${NAMESPACE}'."
      log_warn "Run scripts/staging/eso_local.sh first."
    fi
  done

  preflight_cilium
  preflight_secrets
}

# ------------------------------------------------------------------------------
# Manifest Generation
# ------------------------------------------------------------------------------
render_manifests() {
  mkdir -p "${GEN_DIR}"
  log_info "Rendering manifests to ${GEN_DIR}"

  local pull_policy="${PULL_POLICY}"
  local image_ref="${IMAGE_REPO}:${IMAGE_TAG}"

  # ---------------------------------------------------------------------------
  # ServiceAccount + RBAC (least-privilege, no secrets access)
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/rbac.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: autosre
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${APP_NAME}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: autosre
rules:
  # Pod operations (list, logs, delete for remediation tools)
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]

  # Deployment operations (scale, restart, patch for remediation tools)
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets"]
    verbs: ["get", "list", "watch", "patch", "update"]

  # Event inspection (for get_pod_events tool)
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]

  # Service discovery (for tool target resolution)
  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["get", "list", "watch"]

  # Node metrics (for get_pod_metrics tool via metrics.k8s.io)
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods"]
    verbs: ["get", "list"]

  # NOTE: NO secrets or configmaps access.
  # Agent receives all credentials via environment variables injected by ESO.
  # Cluster-wide secrets access is a CRITICAL security finding (KSV-0041).
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${APP_NAME}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: autosre
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${APP_NAME}
subjects:
  - kind: ServiceAccount
    name: ${APP_NAME}
    namespace: ${NAMESPACE}
EOF

  # ---------------------------------------------------------------------------
  # Deployment
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: autosre
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
        app.kubernetes.io/part-of: autosre
    spec:
      serviceAccountName: ${APP_NAME}
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: wait-for-datastores
          image: ${INIT_IMAGE}
          command:
            - sh
            - -c
            - |
              set -eu
              wait_tcp() {
                host="\$1"; port="\$2"; label="\$3"; i=0
                echo "waiting for \${label} \${host}:\${port} ..."
                until timeout -k 2 3 nc -z -w 2 "\${host}" "\${port}" 2>/dev/null; do
                  i=\$((i + 1))
                  echo "  [\${label}] attempt \${i} failed, retrying in 2s..."
                  sleep 2
                done
                echo "\${label} reachable"
              }
              wait_tcp "${PG_HOST}" "${PG_PORT}" "postgres"
              wait_tcp "${VALKEY_HOST}" "${VALKEY_PORT}" "valkey"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 100m, memory: 32Mi }
      containers:
        - name: ${APP_NAME}
          image: ${image_ref}
          imagePullPolicy: ${pull_policy}
          env:
            # ================================================================
            # Service identity
            # ================================================================
            - name: OTEL_SERVICE_NAME
              value: "${OTEL_SERVICE_NAME}"
            - name: DEPLOYMENT_ENVIRONMENT
              value: "${DEPLOYMENT_ENVIRONMENT}"
            - name: HTTP_PORT
              value: "${HTTP_PORT}"

            # ================================================================
            # Postgres — from postgres-agent secret (legacy keys)
            # ================================================================
            - name: POSTGRES_HOST
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: POSTGRES_HOST } }
            - name: POSTGRES_PORT
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: POSTGRES_PORT } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: POSTGRES_DB } }
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: POSTGRES_USER } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: POSTGRES_PASSWORD } }

            # ================================================================
            # AUTOSRE_LLM__* (16 keys)
            # ================================================================
            - name: AUTOSRE_LLM__API_KEY
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__API_KEY } }
            - name: AUTOSRE_LLM__MODEL_COORDINATOR
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__MODEL_COORDINATOR } }
            - name: AUTOSRE_LLM__MODEL_WORKER
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__MODEL_WORKER } }
            - name: AUTOSRE_LLM__FALLBACK_MODELS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__FALLBACK_MODELS } }
            - name: AUTOSRE_LLM__BASE_URL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__BASE_URL } }
            - name: AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR } }
            - name: AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR } }
            - name: AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER } }
            - name: AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER } }
            - name: AUTOSRE_LLM__MAX_RETRIES
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__MAX_RETRIES } }
            - name: AUTOSRE_LLM__INITIAL_BACKOFF_SECONDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__INITIAL_BACKOFF_SECONDS } }
            - name: AUTOSRE_LLM__MAX_BACKOFF_SECONDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__MAX_BACKOFF_SECONDS } }
            - name: AUTOSRE_LLM__ABSOLUTE_BACKOFF_CAP_SECONDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__ABSOLUTE_BACKOFF_CAP_SECONDS } }
            - name: AUTOSRE_LLM__CIRCUIT_BREAKER_ENABLED
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__CIRCUIT_BREAKER_ENABLED } }
            - name: AUTOSRE_LLM__CIRCUIT_BREAKER_THRESHOLD
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__CIRCUIT_BREAKER_THRESHOLD } }
            - name: AUTOSRE_LLM__CIRCUIT_BREAKER_TIMEOUT_SECONDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_LLM__CIRCUIT_BREAKER_TIMEOUT_SECONDS } }

            # ================================================================
            # AUTOSRE_POSTGRES__* (5 keys)
            # ================================================================
            - name: AUTOSRE_POSTGRES__HOST
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_POSTGRES__HOST } }
            - name: AUTOSRE_POSTGRES__PORT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_POSTGRES__PORT } }
            - name: AUTOSRE_POSTGRES__DB
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_POSTGRES__DB } }
            - name: AUTOSRE_POSTGRES__USER
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_POSTGRES__USER } }
            - name: AUTOSRE_POSTGRES__PASSWORD
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_POSTGRES__PASSWORD } }

            # ================================================================
            # AUTOSRE_VALKEY__* (4 keys) — cross-namespace to rivulet
            # ================================================================
            - name: AUTOSRE_VALKEY__HOST
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_VALKEY__HOST } }
            - name: AUTOSRE_VALKEY__PORT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_VALKEY__PORT } }
            - name: AUTOSRE_VALKEY__PASSWORD
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_VALKEY__PASSWORD } }
            - name: AUTOSRE_VALKEY__TLS_ENABLED
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_VALKEY__TLS_ENABLED } }

            # ================================================================
            # AUTOSRE_OPENOBSERVE__* (3 keys)
            # ================================================================
            - name: AUTOSRE_OPENOBSERVE__EMAIL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OPENOBSERVE__EMAIL } }
            - name: AUTOSRE_OPENOBSERVE__PASSWORD
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OPENOBSERVE__PASSWORD } }
            - name: AUTOSRE_OPENOBSERVE__URL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OPENOBSERVE__URL } }

            # ================================================================
            # AUTOSRE_ALERT__* (1 key)
            # ================================================================
            - name: AUTOSRE_ALERT__WEBHOOK_SECRET
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_ALERT__WEBHOOK_SECRET } }

            # ================================================================
            # AUTOSRE_ADMIN__* (1 key, optional)
            # ================================================================
            - name: AUTOSRE_ADMIN__SECRET
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_ADMIN__SECRET, optional: true } }

            # ================================================================
            # AUTOSRE_SAFETY__* (11 keys)
            # ================================================================
            - name: AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS } }
            - name: AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT } }
            - name: AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS } }
            - name: AUTOSRE_SAFETY__INITIAL_ITERATION_BUDGET
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__INITIAL_ITERATION_BUDGET } }
            - name: AUTOSRE_SAFETY__STAGNATION_LIMIT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__STAGNATION_LIMIT } }
            - name: AUTOSRE_SAFETY__MAX_ACTION_ATTEMPTS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MAX_ACTION_ATTEMPTS } }
            - name: AUTOSRE_SAFETY__CONFIDENCE_PROPOSE
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__CONFIDENCE_PROPOSE } }
            - name: AUTOSRE_SAFETY__CONFIDENCE_FAST_PATH
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__CONFIDENCE_FAST_PATH } }
            - name: AUTOSRE_SAFETY__CONFIDENCE_GIVE_UP
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__CONFIDENCE_GIVE_UP } }
            - name: AUTOSRE_SAFETY__MIN_CONFIDENCE_IMPROVEMENT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MIN_CONFIDENCE_IMPROVEMENT } }
            - name: AUTOSRE_SAFETY__MAX_LLM_CALLS_PER_INCIDENT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SAFETY__MAX_LLM_CALLS_PER_INCIDENT } }

            # ================================================================
            # AUTOSRE_OTEL__* (4 keys)
            # ================================================================
            - name: AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT } }
            - name: AUTOSRE_OTEL__SERVICE_NAME
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OTEL__SERVICE_NAME } }
            - name: AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT } }
            - name: AUTOSRE_OTEL__EXPORTER_HEADERS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_OTEL__EXPORTER_HEADERS } }

            # ================================================================
            # AUTOSRE_DEPLOYMENT_ENVIRONMENT (1 key)
            # ================================================================
            - name: AUTOSRE_DEPLOYMENT_ENVIRONMENT
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_DEPLOYMENT_ENVIRONMENT } }

            # ================================================================
            # AUTOSRE_EVAL__* (3 keys, optional — only used by eval harness)
            # ================================================================
            - name: AUTOSRE_EVAL__JUDGE_API_KEY
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_EVAL__JUDGE_API_KEY, optional: true } }
            - name: AUTOSRE_EVAL__JUDGE_MODEL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_EVAL__JUDGE_MODEL, optional: true } }
            - name: AUTOSRE_EVAL__JUDGE_BASE_URL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_EVAL__JUDGE_BASE_URL, optional: true } }

            # ================================================================
            # AUTOSRE_SLACK__* (6 keys, optional)
            # ================================================================
            - name: AUTOSRE_SLACK__BOT_TOKEN
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__BOT_TOKEN, optional: true } }
            - name: AUTOSRE_SLACK__APP_TOKEN
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__APP_TOKEN, optional: true } }
            - name: AUTOSRE_SLACK__SIGNING_SECRET
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__SIGNING_SECRET, optional: true } }
            - name: AUTOSRE_SLACK__MODE
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__MODE, optional: true } }
            - name: AUTOSRE_SLACK__APPROVAL_CHANNEL
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__APPROVAL_CHANNEL, optional: true } }
            - name: AUTOSRE_SLACK__APPROVER_USER_IDS
              valueFrom: { secretKeyRef: { name: ${AGENT_SECRETS}, key: AUTOSRE_SLACK__APPROVER_USER_IDS, optional: true } }

            # ================================================================
            # OTel exporter headers (optional, from separate secret)
            # ================================================================
            - name: OTEL_EXPORTER_OTLP_HEADERS
              valueFrom:
                secretKeyRef:
                  name: ${OTEL_HEADERS_SECRET}
                  key: otel-exporter-headers
                  optional: true
          ports:
            - name: http
              containerPort: ${HTTP_PORT}
              protocol: TCP
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 3
            timeoutSeconds: 2
            failureThreshold: 20
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
            successThreshold: 1
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
            successThreshold: 1
      volumes:
        - name: tmp
          emptyDir: {}
EOF

  # ---------------------------------------------------------------------------
  # Service
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: autosre
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: ${APP_NAME}
  ports:
    - name: http
      port: ${HTTP_PORT}
      targetPort: http
      protocol: TCP
EOF
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------
cmd_render() {
  preflight
  render_manifests
  log_success "Manifests rendered to ${GEN_DIR}"
}

cmd_deploy() {
  init_work_dir
  preflight
  render_manifests

  log_info "Applying RBAC..."
  kubectl apply -f "${GEN_DIR}/rbac.yaml" --server-side --force-conflicts

  log_info "Applying Service..."
  kubectl apply -f "${GEN_DIR}/service.yaml" --server-side --force-conflicts

  log_info "Applying Deployment..."
  if ! kubectl apply -f "${GEN_DIR}/deployment.yaml" --server-side --force-conflicts; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "kubectl apply failed"
  fi

  log_info "Pruning stale ${APP_NAME} ReplicaSets..."
  local stale_rs
  stale_rs="$(kubectl -n "${NAMESPACE}" get rs -l "app.kubernetes.io/name=${APP_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
    | awk '$2 == 0 {print $1}' || true)"
  if [[ -n "${stale_rs}" ]]; then
    # shellcheck disable=SC2086
    kubectl -n "${NAMESPACE}" delete rs ${stale_rs} --ignore-not-found >/dev/null 2>&1 || true
  fi

  log_info "Pruning pods stuck in Init:* or Pending..."
  local stuck
  stuck="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
    --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "${stuck}" ]]; then
    # shellcheck disable=SC2086
    kubectl -n "${NAMESPACE}" delete pod ${stuck} --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  log_info "Waiting for Deployment rollout (timeout=300s)..."
  if ! kubectl rollout status "deployment/${APP_NAME}" -n "${NAMESPACE}" --timeout=300s; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "Deployment did not become ready"
  fi

  log_success "AutoSRE Agent deployed successfully"
}

cmd_status() {
  preflight
  echo "=== Deployment ==="
  kubectl get deployment "${APP_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Pods ==="
  kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${APP_NAME}" -o wide 2>/dev/null || true
  echo
  echo "=== Service ==="
  kubectl get svc "${APP_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== ServiceAccount ==="
  kubectl get sa "${APP_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== ClusterRole ==="
  kubectl get clusterrole "${APP_NAME}" 2>/dev/null || true
}

cmd_logs() {
  preflight
  kubectl logs -n "${NAMESPACE}" -l "app.kubernetes.io/name=${APP_NAME}" \
    -c "${APP_NAME}" --tail=200 -f "$@"
}

cmd_init_logs() {
  preflight
  kubectl logs -n "${NAMESPACE}" -l "app.kubernetes.io/name=${APP_NAME}" \
    -c wait-for-datastores --tail=200 -f "$@"
}

cmd_delete() {
  preflight
  log_warn "Deleting AutoSRE Agent resources..."
  kubectl -n "${NAMESPACE}" delete deployment "${APP_NAME}"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete svc        "${APP_NAME}"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete sa         "${APP_NAME}"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole "${APP_NAME}"                      --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding "${APP_NAME}"               --ignore-not-found >/dev/null 2>&1 || true
  log_success "AutoSRE Agent resources removed"
}

cmd_verify() {
  preflight
  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || die "No running agent pod found"

  log_info "Verifying Postgres connectivity..."
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${APP_NAME}" -- python -c "
import os, asyncio
from psycopg_pool import AsyncConnectionPool
async def test():
    dsn = f\"postgresql://{os.environ['AUTOSRE_POSTGRES__USER']}:{os.environ['AUTOSRE_POSTGRES__PASSWORD']}@{os.environ['AUTOSRE_POSTGRES__HOST']}:{os.environ['AUTOSRE_POSTGRES__PORT']}/{os.environ['AUTOSRE_POSTGRES__DB']}\"
    pool = AsyncConnectionPool(dsn, open=False, min_size=1, max_size=2)
    await pool.open()
    async with pool.connection() as conn:
        async with conn.cursor() as cur:
            await cur.execute('SELECT 1')
            print(f'Postgres OK: {await cur.fetchone()}')
    await pool.close()
asyncio.run(test())
"

  log_info "Verifying Valkey connectivity..."
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${APP_NAME}" -- python -c "
import os, asyncio
from redis.asyncio import Redis
async def test():
    r = Redis(
        host=os.environ['AUTOSRE_VALKEY__HOST'],
        port=int(os.environ['AUTOSRE_VALKEY__PORT']),
        password=os.environ.get('AUTOSRE_VALKEY__PASSWORD') or None,
        ssl=os.environ.get('AUTOSRE_VALKEY__TLS_ENABLED', 'false').lower() == 'true',
        socket_connect_timeout=5.0,
        decode_responses=True,
    )
    result = await r.ping()
    print(f'Valkey OK: PING={result}')
    await r.aclose()
asyncio.run(test())
"

  log_info "Verifying health endpoint..."
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${APP_NAME}" -- \
    python -c "
import urllib.request
resp = urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=5)
print(f'Health: {resp.status} {resp.read().decode().strip()}')
"

  log_info "Verifying readyz endpoint..."
  kubectl exec -n "${NAMESPACE}" "${pod}" -c "${APP_NAME}" -- \
    python -c "
import urllib.request
resp = urllib.request.urlopen('http://127.0.0.1:8000/readyz', timeout=5)
print(f'Ready: {resp.status} {resp.read().decode().strip()}')
"

  log_success "All connectivity checks passed"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--resolve-sha] <command> [args]

Commands:
  deploy        Apply RBAC + Deployment + Service
  render        Render manifests to disk only (no cluster mutation)
  status        Show Deployment, Pods, Service, and ServiceAccount state
  logs          Tail agent container logs
  init-logs     Tail the wait-for-datastores init container logs
  verify        Test Postgres, Valkey, and health endpoint connectivity
  delete        Remove all agent resources (RBAC, Deployment, Service)
  help          Show this help

Flags:
  --resolve-sha   Read IMAGE_REPO:IMAGE_TAG from local docker and re-tag as
                  sha-<12-char-sha> for an immutable deploy.

Prerequisites (must be deployed before this script):
  1. scripts/staging/eso_local.sh          — ESO + all secrets
  2. infra/k8s/cilium/templates/           — Cilium network policies
  3. scripts/staging/postgres.sh           — Postgres in rivulet namespace
  4. scripts/staging/valkey-deploy.sh      — Valkey in rivulet namespace

Environment Overrides:
  NAMESPACE              (default: sre)
  IMAGE_REPO             (default: ghcr.io/athithya-sakthivel/autosre-agent)
  IMAGE_TAG              (default: latest)
  REPLICAS               (default: 1)
  HTTP_PORT              (default: 8000)
  DEPLOYMENT_ENVIRONMENT (default: staging)
  OTEL_SERVICE_NAME      (default: autosre-agent)
  PG_HOST / PG_PORT
  VALKEY_HOST / VALKEY_PORT
  OBSERVE_URL            (default: http://openobserve.openobserve.svc.cluster.local:5080)
  OTEL_ENDPOINT          (default: http://otel-gateway.openobserve.svc.cluster.local:4318)
  AGENT_SECRETS          (default: autosre-agent-secrets)
  PG_SECRET              (default: postgres-agent)
  OBSERVE_SECRET         (default: openobserve-reader)
  OTEL_HEADERS_SECRET    (default: otel-exporter-headers)
  INIT_IMAGE             (default: docker.io/library/busybox:1.37-musl)
  GEN_DIR                (default: <repo>/infra/k8s/generated/autosre-agent)

Examples:
  # Deploy latest (imagePullPolicy: Always)
  ./scripts/common/autosre-agent-deploy.sh deploy

  # Deploy with an immutable image-sha tag
  ./scripts/common/autosre-agent-deploy.sh --resolve-sha deploy

  # Verify all connections after deploy
  ./scripts/common/autosre-agent-deploy.sh verify

  # Tail logs
  ./scripts/common/autosre-agent-deploy.sh logs

  # Delete all agent resources
  ./scripts/common/autosre-agent-deploy.sh delete
EOF
}

main() {
  local resolve_sha=false
  local args=()
  local a
  for a in "$@"; do
    case "${a}" in
      --resolve-sha) resolve_sha=true ;;
      *) args+=("${a}") ;;
    esac
  done

  if (( ${#args[@]} == 0 )); then
    usage; exit 2
  fi

  local cmd="${args[0]}"; shift 1 || true
  local passthrough=("$@")

  if [[ "${resolve_sha}" == "true" ]]; then
    local local_ref="${IMAGE_REPO}:${IMAGE_TAG}"
    IMAGE_TAG="$(resolve_image_sha "${local_ref}")"
    log_info "Resolved ${local_ref} → ${IMAGE_TAG}"
  fi

  PULL_POLICY="$(pull_policy_for "${IMAGE_TAG}")"
  export PULL_POLICY

  case "${cmd}" in
    deploy)          cmd_deploy ;;
    render)          cmd_render ;;
    status)          cmd_status ;;
    logs)            cmd_logs "${passthrough[@]}" ;;
    init-logs)       cmd_init_logs "${passthrough[@]}" ;;
    verify)          cmd_verify ;;
    delete)          cmd_delete ;;
    help|--help|-h)  usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
