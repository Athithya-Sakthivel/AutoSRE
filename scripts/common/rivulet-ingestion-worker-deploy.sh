#!/usr/bin/env bash
# ==============================================================================
# rivulet-ingestion-worker-deploy.sh — Rivulet Ingestion Worker lifecycle manager
#
# Renders and applies the ingestion-worker stack:
#   1. Deployment — Go worker, distroless static, readOnlyRootFilesystem
#   2. Service    — ClusterIP :8080 (health); chaos :8081 never exposed
#   3. HorizontalPodAutoscaler
#
# No migration phase. Schema is owned by rivulet-api-gateway via Flyway.
#
# Image tag policy:
#   Default "latest" — matches build_rivulet_images.sh convention.
#   Use --resolve-sha to lock to the local image's sha256.
#     latest        -> imagePullPolicy: Always
#     anything else -> imagePullPolicy: IfNotPresent
#
# Secrets contract (same as api-gateway):
#   postgres-rivulet-env    PGDATABASE, PGUSER, PGPASSWORD
#   valkey-auth             VALKEY_PASSWORD
#   otel-exporter-headers   otel-exporter-headers
#
# Cilium contract (see infra/k8s/cilium/templates/):
#   * clients-to-datastores-egress — egress to postgres/valkey
#   * postgres-ingress             — allows ingestion-worker :5432
#   * valkey-ingress               — allows ingestion-worker :6379
#   * ingestion-worker-ingress     — ingress :8080 (kubelet), :8081 (eval)
#   * rivulet-to-otel              — egress to otel-gateway :4318
#   * allow-dns-egress             — DNS resolution
#   * default-deny                 — Cilium endpoint isolation
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-rivulet}"
APP_NAME="${APP_NAME:-ingestion-worker}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/athithya-sakthivel/rivulet-ingestion-worker}"
IMAGE_TAG="${IMAGE_TAG:-latest}" # SUT rarely changes

DEPLOYMENT_ENVIRONMENT="${DEPLOYMENT_ENVIRONMENT:-evaluation}"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-ingestion-worker}"

# Service DNS — same names as api-gateway
PGHOST="${PGHOST:-postgres.${NAMESPACE}.svc.cluster.local}"
PGPORT="${PGPORT:-5432}"
PGSSLMODE="${PGSSLMODE:-disable}"
VALKEY_HOST="${VALKEY_HOST:-valkey.${NAMESPACE}.svc.cluster.local}"
VALKEY_PORT="${VALKEY_PORT:-6379}"
VALKEY_TLS_ENABLED="${VALKEY_TLS_ENABLED:-false}"
OTEL_ENDPOINT="${OTEL_ENDPOINT:-http://otel-gateway.openobserve.svc.cluster.local:4318}"
STREAM_NAME="${STREAM_NAME:-rivulet.orders.in}"
CONSUMER_GROUP="${CONSUMER_GROUP:-ingestion-workers}"

# Secret names — identical contract to api-gateway
PG_ENV_SECRET="${PG_ENV_SECRET:-postgres-rivulet-env}"
VALKEY_SECRET="${VALKEY_SECRET:-valkey-auth}"
VALKEY_SECRET_KEY="${VALKEY_SECRET_KEY:-VALKEY_PASSWORD}"
OTEL_HEADERS_SECRET="${OTEL_HEADERS_SECRET:-otel-exporter-headers}"

# Cilium sanity check
REQUIRED_CNPS=(
  default-deny
  allow-dns-egress
  clients-to-datastores-egress
  postgres-ingress
  valkey-ingress
  ingestion-worker-ingress
  rivulet-to-otel
)

REPLICAS="${REPLICAS:-2}"
HTTP_PORT="${HTTP_PORT:-8080}"
CHAOS_PORT="${CHAOS_PORT:-8081}"
INIT_IMAGE="${INIT_IMAGE:-docker.io/library/busybox:1.37-musl}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GEN_DIR="${GEN_DIR:-${REPO_ROOT}/infra/k8s/generated/ingestion-worker}"

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
  WORK_DIR="$(mktemp -d -t rivulet-ingestion-worker.XXXXXX)"
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
  for s in "${PG_ENV_SECRET}" "${VALKEY_SECRET}" "${OTEL_HEADERS_SECRET}"; do
    if kubectl -n "${NAMESPACE}" get secret "${s}" >/dev/null 2>&1; then
      printf '  %s: present\n' "${s}" >&2
    else
      printf '  %s: MISSING\n' "${s}" >&2
    fi
  done
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

preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

  [[ -n "${IMAGE_TAG}" ]] || die "IMAGE_TAG is empty."
  [[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "IMAGE_TAG '${IMAGE_TAG}' is not a valid Docker tag."

  log_info "Target namespace: ${NAMESPACE}"
  log_info "Target image:     ${IMAGE_REPO}:${IMAGE_TAG}"
  log_info "Pull policy:      ${PULL_POLICY}"
  log_info "Postgres:         ${PGHOST}:${PGPORT} (sslmode=${PGSSLMODE})  secret=${PG_ENV_SECRET}"
  log_info "Valkey:           ${VALKEY_HOST}:${VALKEY_PORT} (tls=${VALKEY_TLS_ENABLED})  secret=${VALKEY_SECRET}"
  log_info "Stream:           ${STREAM_NAME}  group=${CONSUMER_GROUP}"
  log_info "OTel:             ${OTEL_ENDPOINT}"
  log_info "HTTP port:        ${HTTP_PORT}  (chaos on ${CHAOS_PORT}, not exposed)"

  if ! kubectl -n "${NAMESPACE}" get svc postgres >/dev/null 2>&1; then
    log_warn "Service 'postgres' not found in namespace '${NAMESPACE}'."
    log_warn "Init container will block until it appears."
  fi
  if ! kubectl -n "${NAMESPACE}" get svc valkey >/dev/null 2>&1; then
    log_warn "Service 'valkey' not found in namespace '${NAMESPACE}'."
    log_warn "Init container will block until it appears."
  fi

  local s
  for s in "${PG_ENV_SECRET}" "${VALKEY_SECRET}" "${OTEL_HEADERS_SECRET}"; do
    if ! kubectl -n "${NAMESPACE}" get secret "${s}" >/dev/null 2>&1; then
      log_warn "Secret '${s}' not found in namespace '${NAMESPACE}'."
      log_warn "Pods will fail to start until it exists."
    fi
  done

  preflight_cilium
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
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: backend
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
        app.kubernetes.io/part-of: rivulet
        app.kubernetes.io/component: backend
    spec:
      # Prevents kubelet's legacy Docker-link env injection (SVCNAME_PORT=tcp://...).
      # VALKEY_PORT=tcp://10.x.x.x:6379 would be read by config.Load and fail
      # to parse as int — worker exits 1 at startup.
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
              wait_tcp "${PGHOST}" "${PGPORT}" "postgres"
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
            # Service identity for telemetry
            - name: OTEL_SERVICE_NAME
              value: "${OTEL_SERVICE_NAME}"
            - name: DEPLOYMENT_ENVIRONMENT
              value: "${DEPLOYMENT_ENVIRONMENT}"
            - name: GIT_VERSION
              value: "${IMAGE_TAG}"

            # HTTP + Chaos ports (config.Load reads these)
            - name: HTTP_PORT
              value: "${HTTP_PORT}"
            - name: CHAOS_PORT
              value: "${CHAOS_PORT}"

            # Postgres — host/port/sslmode via env, credentials via secret
            - name: PGHOST
              value: "${PGHOST}"
            - name: PGPORT
              value: "${PGPORT}"
            - name: PGSSLMODE
              value: "${PGSSLMODE}"
            - name: PGDATABASE
              valueFrom: { secretKeyRef: { name: ${PG_ENV_SECRET}, key: PGDATABASE } }
            - name: PGUSER
              valueFrom: { secretKeyRef: { name: ${PG_ENV_SECRET}, key: PGUSER } }
            - name: PGPASSWORD
              valueFrom: { secretKeyRef: { name: ${PG_ENV_SECRET}, key: PGPASSWORD } }

            # Valkey — explicit to override any SVCNAME_PORT injection
            - name: VALKEY_HOST
              value: "${VALKEY_HOST}"
            - name: VALKEY_PORT
              value: "${VALKEY_PORT}"
            - name: VALKEY_TLS_ENABLED
              value: "${VALKEY_TLS_ENABLED}"
            - name: VALKEY_PASSWORD
              valueFrom: { secretKeyRef: { name: ${VALKEY_SECRET}, key: ${VALKEY_SECRET_KEY} } }

            # Stream / consumer group identity
            - name: STREAM_NAME
              value: "${STREAM_NAME}"
            - name: CONSUMER_GROUP
              value: "${CONSUMER_GROUP}"

            # OTel — endpoint via env, exporter headers optional
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "${OTEL_ENDPOINT}"
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
            - name: chaos
              containerPort: ${CHAOS_PORT}
              protocol: TCP
            # NOTE: chaos is not referenced by the Service — see service.yaml
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
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
            failureThreshold: 20    # 60s budget for initial ping + pool init
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
  # Service — only :8080 is exposed. Chaos :8081 is intentionally invisible.
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: backend
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

  # ---------------------------------------------------------------------------
  # HPA — stabilization prevents runaway scale during transient outages
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/hpa.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}-hpa
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/part-of: rivulet
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_NAME}
  minReplicas: ${REPLICAS}
  maxReplicas: 8
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
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

  log_info "Applying Service and HPA..."
  kubectl apply -f "${GEN_DIR}/service.yaml" --server-side --force-conflicts
  kubectl apply -f "${GEN_DIR}/hpa.yaml"     --server-side --force-conflicts

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

  log_success "Ingestion Worker deployed successfully"
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
  echo "=== HPA ==="
  kubectl get hpa "${APP_NAME}-hpa" -n "${NAMESPACE}" 2>/dev/null || true
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

cmd_chaos() {
  # Convenience: exec into a running pod and hit the chaos plane on loopback.
  # Usage: ./script chaos <pod-name> <endpoint>
  local pod="${1:-}"; local endpoint="${2:-}"
  [[ -n "${pod}" && -n "${endpoint}" ]] \
    || die "usage: $(basename "$0") chaos <pod-name> <endpoint e.g. reset>"
  kubectl -n "${NAMESPACE}" exec "${pod}" -c "${APP_NAME}" -- \
    wget -qO- --post-data='' "http://127.0.0.1:${CHAOS_PORT}/__chaos/${endpoint}"
}

cmd_delete() {
  preflight
  log_warn "Deleting Ingestion Worker resources..."
  kubectl -n "${NAMESPACE}" delete deployment "${APP_NAME}"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete svc        "${APP_NAME}"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete hpa        "${APP_NAME}-hpa" --ignore-not-found >/dev/null 2>&1 || true
  log_success "Ingestion Worker resources removed (stream state untouched)"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--resolve-sha] <command> [args]

Commands:
  deploy        Apply Deployment + Service + HPA
  render        Render manifests to disk only (no cluster mutation)
  status        Show Deployment, Pods, Service, and HPA state
  logs          Tail ingestion-worker container logs
  init-logs     Tail the wait-for-datastores init container logs
  chaos         Forward a chaos endpoint on a running pod:
                  $(basename "$0") chaos <pod> <endpoint>
  delete        Remove all ingestion-worker resources
  help          Show this help

Flags:
  --resolve-sha   Read IMAGE_REPO:IMAGE_TAG from local docker and re-tag as
                  sha-<12-char-sha> for an immutable deploy.

Environment Overrides:
  NAMESPACE              (default: rivulet)
  IMAGE_REPO             (default: ghcr.io/athithya-sakthivel/rivulet-ingestion-worker)
  IMAGE_TAG              (default: latest)
  REPLICAS               (default: 2)
  HTTP_PORT              (default: 8080)
  CHAOS_PORT             (default: 8081)
  DEPLOYMENT_ENVIRONMENT (default: evaluation)
  OTEL_SERVICE_NAME      (default: ingestion-worker)
  PGHOST / PGPORT / PGSSLMODE
  VALKEY_HOST / VALKEY_PORT / VALKEY_TLS_ENABLED
  OTEL_ENDPOINT          (default: http://otel-gateway.openobserve.svc.cluster.local:4318)
  STREAM_NAME            (default: rivulet.orders.in)
  CONSUMER_GROUP         (default: ingestion-workers)
  PG_ENV_SECRET          (default: postgres-rivulet-env)
  VALKEY_SECRET          (default: valkey-auth)
  VALKEY_SECRET_KEY      (default: VALKEY_PASSWORD)
  OTEL_HEADERS_SECRET    (default: otel-exporter-headers)
  INIT_IMAGE             (default: docker.io/library/busybox:1.37-musl)
  GEN_DIR                (default: <repo>/infra/k8s/generated/ingestion-worker)

Examples:
  # Deploy latest (imagePullPolicy: Always)
  ./scripts/common/rivulet-ingestion-worker-deploy.sh deploy

  # Deploy with an immutable image-sha tag
  ./scripts/common/rivulet-ingestion-worker-deploy.sh --resolve-sha deploy

  # Tail logs
  ./scripts/common/rivulet-ingestion-worker-deploy.sh logs

  # Trigger a chaos fault on a specific pod
  ./scripts/common/rivulet-ingestion-worker-deploy.sh chaos ingestion-worker-xxxxx reset
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
    chaos)           cmd_chaos "${passthrough[@]}" ;;
    delete)          cmd_delete ;;
    help|--help|-h)  usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
