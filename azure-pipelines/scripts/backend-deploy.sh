#!/usr/bin/env bash
# ==============================================================================
# backend-deploy.sh – Backend lifecycle manager (stable and canary)
#
# Manages the backend Rollout with Argo Rollouts canary strategy.
# Supports stable deploys (setWeight:100) and canary deploys with automatic
# validation (k6) and rollback on failure.
#
# Works on any Kubernetes cluster with Argo Rollouts, Gateway API, and a
# `backend-config` ConfigMap containing environment overrides.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN_DIR="$SCRIPT_DIR/../infra/k8s/generated/backend"

# --- Defaults (override via flags or environment) ---------------------------
NAMESPACE="${NAMESPACE:-task-api}"
REPLICAS="${REPLICAS:-2}"
PORT="${PORT:-8080}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/athithya-sakthivel/task-api-backend}"
STABLE_TAG="${STABLE_TAG:-v1}"
CANARY_TAG="${CANARY_TAG:-v2}"
K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/../tests/k6/backend-load.ts}"
K6_BIN="${K6_BIN:-k6}"

QPS="${QPS:-50}"
P95_THRESHOLD="${P95_THRESHOLD:-200}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-0.01}"
DURATION="${DURATION:-2m}"
GRACEFUL_STOP="${GRACEFUL_STOP:-10s}"
PREALLOCATED_VUS="${PREALLOCATED_VUS:-25}"
OBSERVATION_DURATION="${OBSERVATION_DURATION:-2m}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"    # seconds
LOCAL_PORT="${LOCAL_PORT:-18080}"

MODE="stable"
IMAGE=""
SKIP_K6=false
SKIP_PROMOTE=false

ROLLOUT_NAME="backend"
STABLE_SERVICE="backend-stable"
CANARY_SERVICE="backend-canary"
CONTAINER="backend"
CANARY_SERVICE_PORT=""
PREVIOUS_IMAGE=""
ROLL_OUT_UPDATED=false
ROLLING_BACK=false
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

# --- Logging ----------------------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'
log()    { printf "${C_CYAN}[%s]${C_RESET} %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }
warn()   { printf "${C_YELLOW}[%s] WARN:${C_RESET} %s\n" "$(date -u +%H:%M:%SZ)" "$*" >&2; }
fail()   { printf "${C_RED}[%s] ERROR:${C_RESET} %s\n" "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }
success(){ printf "${C_GREEN}[%s] SUCCESS:${C_RESET} %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }

usage() { cat <<USAGE
Usage:
  $0 --stable --stable-tag v1
  $0 --canary --image <image> [options]

Options:
  --namespace <ns>                  Kubernetes namespace (default: $NAMESPACE)
  --replicas <n>                    Number of replicas (default: $REPLICAS)
  --port <port>                     Container and Service port (default: $PORT)
  --image-repo <repo>               Image repository (default: $IMAGE_REPO)
  --stable-tag <tag>                Stable image tag (default: $STABLE_TAG)
  --canary-tag <tag>                Canary image tag (default: $CANARY_TAG)
  --k6-script <path>                k6 script path (default: $K6_SCRIPT)
  --qps <n>                         Target QPS (default: $QPS)
  --p95-threshold <ms>              P95 latency threshold (default: $P95_THRESHOLD)
  --error-threshold <rate>          Error rate threshold (default: $ERROR_THRESHOLD)
  --duration <dur>                  Load test duration (default: $DURATION)
  --observation-duration <dur>      Observation period at 10% (default: $OBSERVATION_DURATION)
  --local-port <port>               Local port for port-forward (default: $LOCAL_PORT)
  --skip-k6                         Skip k6 validation
  --skip-promote                    Do not promote after successful validation
  --help                            Show this help
USAGE
exit 2; }

# --- Trap for rollback on unexpected failure ---------------------------------
on_exit() {
  local rc=$?
  stop_port_forward
  if [[ "$rc" -ne 0 && "$ROLL_OUT_UPDATED" == true && "$ROLLING_BACK" == false ]]; then
    ROLLING_BACK=true
    log "Orchestration failed (exit=$rc). Rolling back..."
    rollback "$rc"
  fi
}
trap on_exit EXIT

stop_port_forward() {
  [[ -n "${PORT_FORWARD_PID:-}" ]] && kill "$PORT_FORWARD_PID" 2>/dev/null || true
  [[ -n "${PORT_FORWARD_LOG:-}" && -f "$PORT_FORWARD_LOG" ]] && rm -f "$PORT_FORWARD_LOG"
  PORT_FORWARD_PID=""; PORT_FORWARD_LOG=""
}

# --- Helper functions --------------------------------------------------------
rollout_json() { kubectl get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o json 2>/dev/null; }

detect_strategy() {
  local kind
  kind="$(jq -r 'if .spec.strategy.canary != null then "canary" else "unknown" end' <<<"$(rollout_json)")"
  [[ "$kind" == "canary" ]] || fail "Rollout '$ROLLOUT_NAME' does not use canary strategy"
}

validate_rollout_healthy() {
  local phase
  phase="$(jq -r '.status.phase // "Unknown"' <<<"$(rollout_json)")"
  [[ "$phase" == "Healthy" ]] || fail "Rollout must be Healthy before canary; current phase: $phase. Use --stable first."
}

resolve_canary_port() {
  CANARY_SERVICE_PORT="$(kubectl get svc "$CANARY_SERVICE" -n "$NAMESPACE" -o json | jq -r '.spec.ports[0].port')"
  [[ "$CANARY_SERVICE_PORT" =~ ^[0-9]+$ ]] || fail "Invalid canary service port"
}

wait_for_canary_pause() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  log "Waiting for CanaryPauseStep..."
  while (( SECONDS < deadline )); do
    local data phase reason idx step_pause
    data="$(rollout_json)" || fail "Rollout disappeared"
    phase="$(jq -r '.status.phase // "Unknown"' <<<"$data")"
    [[ "$phase" == "Degraded" || "$phase" == "Error" ]] && fail "Rollout entered terminal phase: $phase"
    reason="$(jq -r '(.status.pauseConditions // []) | map(select(.reason == "CanaryPauseStep")) | if length > 0 then .[0].reason else "" end' <<<"$data")"
    if [[ "$reason" == "CanaryPauseStep" ]]; then
      idx="$(jq -r '.status.currentStepIndex // -1' <<<"$data")"
      step_pause="$(jq -r --argjson idx "$idx" '.spec.strategy.canary.steps[$idx].pause // null' <<<"$data")"
      [[ "$step_pause" != "null" ]] && { log "Pause confirmed at step $idx"; return 0; }
    fi
    sleep 2
  done
  fail "Timed out waiting for CanaryPauseStep"
}

promote_once() { kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE"; }
wait_for_healthy() { kubectl argo rollouts status "$ROLLOUT_NAME" -n "$NAMESPACE" --timeout "${WAIT_TIMEOUT}s"; }
promote_to_full() { kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE" --full; }

rollback() {
  local rc=${1:-1}
  set +e
  stop_port_forward
  kubectl argo rollouts abort "$ROLLOUT_NAME" -n "$NAMESPACE" 2>/dev/null || true
  if [[ -n "$PREVIOUS_IMAGE" && -n "$CONTAINER" ]]; then
    kubectl argo rollouts set image "$ROLLOUT_NAME" "$CONTAINER=$PREVIOUS_IMAGE" -n "$NAMESPACE"
    promote_to_full
    kubectl argo rollouts status "$ROLLOUT_NAME" -n "$NAMESPACE" --timeout "${WAIT_TIMEOUT}s" 2>/dev/null || true
  fi
  set -e
  log "Rollback completed. Original failure exit code: $rc"
  exit "$rc"
}

# --- Resource rendering ------------------------------------------------------
mkdir -p "$GEN_DIR"

write_and_apply() {
  local filename="$1"
  cat > "$GEN_DIR/$filename"
  kubectl apply -f "$GEN_DIR/$filename"
}

ensure_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

ensure_configmap() {
  write_and_apply "configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-config
  namespace: $NAMESPACE
data:
  OTEL_SERVICE_NAME: "task-api-backend"
  SERVER_PORT: "$PORT"
  APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE: "100"
  OTEL_RESOURCE_ATTRIBUTES: ""
EOF
}

ensure_services() {
  write_and_apply "services.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $STABLE_SERVICE
  namespace: $NAMESPACE
spec:
  selector:
    app: backend
  ports:
    - port: $PORT
      targetPort: $PORT
---
apiVersion: v1
kind: Service
metadata:
  name: $CANARY_SERVICE
  namespace: $NAMESPACE
spec:
  selector:
    app: backend
  ports:
    - port: $PORT
      targetPort: $PORT
EOF
}

ensure_httproute() {
  if ! kubectl get httproute backend-route -n "$NAMESPACE" >/dev/null 2>&1; then
    write_and_apply "httproute.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-route
  namespace: $NAMESPACE
spec:
  parentRefs:
    - name: gateway
      namespace: gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: $STABLE_SERVICE
          port: $PORT
          weight: 100
        - name: $CANARY_SERVICE
          port: $PORT
          weight: 0
EOF
  fi
}

ensure_rollout() {
  # Create if missing; do not wait here.
  if ! kubectl get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    write_and_apply "rollout.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: $ROLLOUT_NAME
  namespace: $NAMESPACE
spec:
  replicas: $REPLICAS
  revisionHistoryLimit: 3
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app: backend
  strategy:
    canary:
      canaryService: $CANARY_SERVICE
      stableService: $STABLE_SERVICE
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: backend-route
            namespace: $NAMESPACE
      steps:
        - setWeight: 100
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: $CONTAINER
          image: $IMAGE_REPO:$STABLE_TAG
          ports:
            - containerPort: $PORT
          envFrom:
            - configMapRef:
                name: backend-config
            - secretRef:
                name: backend-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: $PORT
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health
              port: $PORT
            initialDelaySeconds: 30
            periodSeconds: 15
          startupProbe:
            httpGet:
              path: /actuator/health
              port: $PORT
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 30
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
EOF
  fi
}

patch_steps() {
  kubectl patch rollout "$ROLLOUT_NAME" -n "$NAMESPACE" \
    --type merge -p "{\"spec\":{\"strategy\":{\"canary\":{\"steps\":$1}}}}"
}

patch_replicas() {
  kubectl patch rollout "$ROLLOUT_NAME" -n "$NAMESPACE" \
    --type merge -p "{\"spec\":{\"replicas\":$REPLICAS}}"
}

set_image() { kubectl argo rollouts set image "$ROLLOUT_NAME" "$CONTAINER=$1" -n "$NAMESPACE"; }

# --- Validation --------------------------------------------------------------
run_k6() {
  [[ "$SKIP_K6" == false ]] || return 0
  log "Running k6 load test (QPS=$QPS, duration=$DURATION)..."
  set +e
  timeout 10m "$K6_BIN" run --quiet \
    --env "BASE_URL=http://127.0.0.1:${LOCAL_PORT}" \
    --env "QPS=$QPS" --env "P95_THRESHOLD=$P95_THRESHOLD" \
    --env "ERROR_RATE_THRESHOLD=$ERROR_THRESHOLD" \
    --env "PREALLOCATED_VUS=$PREALLOCATED_VUS" \
    --env "DURATION=$DURATION" --env "GRACEFUL_STOP=$GRACEFUL_STOP" \
    "$K6_SCRIPT"
  local rc=$?; set -e
  [[ $rc -eq 0 ]] && success "k6 passed" || fail "k6 failed (exit=$rc)"
}

start_port_forward() {
  local port=$LOCAL_PORT attempt=0
  while (( attempt < 10 )); do
    PORT_FORWARD_LOG="$(mktemp)"
    kubectl port-forward -n "$NAMESPACE" --address 127.0.0.1 \
      "service/$CANARY_SERVICE" "${port}:${CANARY_SERVICE_PORT}" >"$PORT_FORWARD_LOG" 2>&1 &
    PORT_FORWARD_PID=$!
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
      kill -0 "$PORT_FORWARD_PID" 2>/dev/null || break
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&-; LOCAL_PORT=$port; return 0; }
      sleep 1
    done
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    rm -f "$PORT_FORWARD_LOG"
    attempt=$((attempt+1))
    port=$((LOCAL_PORT + attempt))
  done
  fail "Port-forward failed after 10 attempts"
}

# --- Main deployment flows ---------------------------------------------------
deploy_stable() {
  IMAGE="$IMAGE_REPO:${1:-$STABLE_TAG}"
  log "Deploying stable backend $IMAGE"
  ensure_namespace
  ensure_configmap
  ensure_services
  ensure_httproute
  ensure_rollout        # does not wait; okay
  patch_replicas
  patch_steps '[{"setWeight":100}]'
  set_image "$IMAGE"
  promote_to_full 2>/dev/null || true   # ignore if already full
  wait_for_healthy
  success "Stable backend deployed"
}

deploy_canary() {
  IMAGE="${IMAGE:-$IMAGE_REPO:$CANARY_TAG}"
  log "Deploying canary backend $IMAGE"
  ensure_namespace
  ensure_configmap
  ensure_services
  ensure_httproute
  ensure_rollout
  detect_strategy
  validate_rollout_healthy
  PREVIOUS_IMAGE="$(jq -r --arg c "$CONTAINER" '.spec.template.spec.containers[]|select(.name==$c)|.image' <<<"$(rollout_json)")"
  [[ "$PREVIOUS_IMAGE" == "$IMAGE" ]] && { success "Already on $IMAGE"; return 0; }
  patch_replicas
  patch_steps '[
    {"setWeight":0},
    {"pause":{}},
    {"setWeight":10},
    {"pause":{}},
    {"setWeight":100}
  ]'
  set_image "$IMAGE"
  ROLL_OUT_UPDATED=true
  wait_for_canary_pause       # wait at first pause (0%)
  resolve_canary_port
  start_port_forward
  run_k6
  stop_port_forward
  success "Validations passed"
  if [[ "$SKIP_PROMOTE" == true ]]; then
    warn "Skip promote requested; leaving at current step"
    return 0
  fi
  promote_once                # promote to 10%
  wait_for_canary_pause       # wait at second pause (10%)
  log "Observing at 10% for $OBSERVATION_DURATION"
  sleep "$OBSERVATION_DURATION"
  promote_once                # promote to 100%
  wait_for_healthy
  ROLL_OUT_UPDATED=false
  success "Backend canary completed"
}

# --- Argument parsing --------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) NAMESPACE="$2"; shift 2 ;;
      --replicas) REPLICAS="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --image-repo) IMAGE_REPO="$2"; shift 2 ;;
      --stable-tag) STABLE_TAG="$2"; shift 2 ;;
      --canary-tag) CANARY_TAG="$2"; shift 2 ;;
      --k6-script) K6_SCRIPT="$2"; shift 2 ;;
      --qps) QPS="$2"; shift 2 ;;
      --p95-threshold) P95_THRESHOLD="$2"; shift 2 ;;
      --error-threshold) ERROR_THRESHOLD="$2"; shift 2 ;;
      --duration) DURATION="$2"; shift 2 ;;
      --observation-duration) OBSERVATION_DURATION="$2"; shift 2 ;;
      --local-port) LOCAL_PORT="$2"; shift 2 ;;
      --skip-k6) SKIP_K6=true; shift ;;
      --skip-promote) SKIP_PROMOTE=true; shift ;;
      --stable) MODE=stable; shift ;;
      --canary) MODE=canary; shift ;;
      --image) IMAGE="$2"; shift 2 ;;
      --help) usage ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done
  # If canary mode and no image provided, default to repo:canary-tag
  if [[ "$MODE" == "canary" && -z "$IMAGE" && -n "$CANARY_TAG" ]]; then
    IMAGE="$IMAGE_REPO:$CANARY_TAG"
  fi
}

preflight() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
  command -v jq >/dev/null 2>&1 || fail "jq not found"
  kubectl argo rollouts version >/dev/null 2>&1 || fail "kubectl-argo-rollouts plugin missing"
  if [[ "$MODE" == "canary" ]]; then
    [[ "$SKIP_K6" == false ]] && command -v "$K6_BIN" >/dev/null 2>&1 || fail "k6 not found"
  fi
}

main() {
  parse_args "$@"
  preflight
  case "$MODE" in
    stable) deploy_stable "$STABLE_TAG" ;;
    canary) deploy_canary ;;
    *) fail "Invalid mode: $MODE" ;;
  esac
  success "Backend deployment completed"
}

main "$@"
