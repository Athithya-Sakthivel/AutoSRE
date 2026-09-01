#!/usr/bin/env bash
# ==============================================================================
# canary-deploy.sh – Bulletproof Argo Rollouts canary orchestrator
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

NAMESPACE="${NAMESPACE:-task-api}"
SERVICE="${SERVICE:-all}"
IMAGE=""
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/athithya-sakthivel/task-api-backend:v2}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/athithya-sakthivel/task-api-frontend:v2}"
BACKEND_STABLE_IMAGE="${BACKEND_STABLE_IMAGE:-ghcr.io/athithya-sakthivel/task-api-backend:v1}"
FRONTEND_STABLE_IMAGE="${FRONTEND_STABLE_IMAGE:-ghcr.io/athithya-sakthivel/task-api-frontend:v1}"
CONTAINER=""
K6_SCRIPT=""
PLAYWRIGHT_DIR=""
K6_BIN="${K6_BIN:-k6}"

QPS=50
ERROR_THRESHOLD="0.01"
P95_THRESHOLD="200"
DURATION="2m"
GRACEFUL_STOP="10s"
PREALLOCATED_VUS=25
OBSERVATION_DURATION="2m"
WAIT_TIMEOUT=600
LOCAL_PORT=18080

SKIP_PLAYWRIGHT=false
SKIP_K6=false
SKIP_PROMOTE=false
DRY_RUN=false
CLEANUP_MODE=false

ROLLOUT_NAME=""
CANARY_SERVICE=""
STABLE_SERVICE=""
CANARY_SERVICE_PORT=""
PREVIOUS_IMAGE=""
ROLL_OUT_UPDATED=false
ROLLING_BACK=false
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

log()   { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn()  { printf '[%s] WARN: %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
fail()  { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  $0 --service <backend|frontend|all> --image <image> [options]
  $0 --cleanup [options]

Modes:
  --cleanup         Reset backend/frontend Rollouts to stable v1 images.

Required for canary:
  --service <backend|frontend|all>   Service to deploy (default: all)
  --image <image>                    New container image

Options:
  --namespace <ns>                  Kubernetes namespace (default: $NAMESPACE)
  --container <name>                Container name (auto-detect if single)
  --k6-script <path>                k6 script (default based on service)
  --playwright-dir <path>           Playwright directory (frontend only)
  --qps <n>                         Target QPS (default: $QPS)
  --error-threshold <rate>          Error rate threshold (default: $ERROR_THRESHOLD)
  --p95-threshold <ms>              P95 latency threshold (default: $P95_THRESHOLD)
  --duration <dur>                  Load test duration (default: $DURATION)
  --observation-duration <dur>      Observation at 10% (default: $OBSERVATION_DURATION)
  --local-port <port>               Local port for port-forward (default: $LOCAL_PORT)
  --skip-playwright                 Skip Playwright validation
  --skip-k6                         Skip k6 validation
  --skip-promote                    Do not promote after validation
  --k6-bin <path>                   Path to k6 binary (default: k6)
  --backend-image <image>           Backend image for 'all'
  --frontend-image <image>          Frontend image for 'all'
  --dry-run                         Print actions without executing
  --help                            Show this help
USAGE
  exit 2
}

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
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
  if [[ -n "${PORT_FORWARD_LOG:-}" && -f "$PORT_FORWARD_LOG" ]]; then
    rm -f "$PORT_FORWARD_LOG"
    PORT_FORWARD_LOG=""
  fi
}

rollout_json() {
  kubectl get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o json 2>/dev/null
}

detect_strategy() {
  local data kind
  data="$(rollout_json)" || fail "Rollout '$ROLLOUT_NAME' not found"
  kind="$(jq -r 'if .spec.strategy.canary != null then "canary" elif .spec.strategy.blueGreen != null then "bluegreen" else "unknown" end' <<<"$data")"
  if [[ "$kind" != "canary" ]]; then
    fail "Rollout '$ROLLOUT_NAME' does not use canary strategy (detected: $kind)"
  fi
}

resolve_container() {
  local containers count
  containers="$(rollout_json | jq -r '.spec.template.spec.containers[].name' | tr '\n' ' ' | sed 's/ $//')"
  [[ -n "$containers" ]] || fail "No containers found in Rollout"

  if [[ -n "$CONTAINER" ]]; then
    echo "$containers" | grep -Fqx "$CONTAINER" || fail "Container '$CONTAINER' not found. Available: $containers"
  else
    count="$(echo "$containers" | wc -w)"
    [[ "$count" -eq 1 ]] || fail "Multiple containers found ($containers). Pass --container."
    CONTAINER="$containers"
  fi

  PREVIOUS_IMAGE="$(rollout_json | jq -r --arg name "$CONTAINER" '.spec.template.spec.containers[] | select(.name==$name) | .image')"
  [[ -n "$PREVIOUS_IMAGE" ]] || fail "Could not read current image for $CONTAINER"
}

validate_rollout_healthy() {
  local data phase
  data="$(rollout_json)" || fail "Rollout '$ROLLOUT_NAME' not found"
  phase="$(jq -r '.status.phase // "Unknown"' <<<"$data")"
  if [[ "$phase" != "Healthy" ]]; then
    fail "Rollout must be Healthy before starting canary; current phase: $phase. Use --cleanup or reset first."
  fi
}

resolve_canary_port() {
  local port
  port="$(kubectl get service "$CANARY_SERVICE" -n "$NAMESPACE" -o json | jq -r '.spec.ports[0].port // empty')"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "Invalid canary service port: $port"
  CANARY_SERVICE_PORT="$port"
}

wait_for_canary_pause() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  log "Waiting for CanaryPauseStep..."

  while (( SECONDS < deadline )); do
    local data phase reason idx step_pause
    data="$(rollout_json)" || fail "Rollout disappeared"
    phase="$(jq -r '.status.phase // "Unknown"' <<<"$data")"

    if [[ "$phase" == "Degraded" || "$phase" == "Error" ]]; then
      fail "Rollout entered terminal phase: $phase"
    fi

    reason="$(jq -r '(.status.pauseConditions // []) | map(select(.reason == "CanaryPauseStep")) | if length > 0 then .[0].reason else "" end' <<<"$data")"

    if [[ "$reason" == "CanaryPauseStep" ]]; then
      idx="$(jq -r '.status.currentStepIndex // -1' <<<"$data")"
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      step_pause="$(jq -r --argjson idx "$idx" '.spec.strategy.canary.steps[$idx].pause // null' <<<"$data")"
      if [[ "$step_pause" != "null" ]]; then
        log "Canary pause confirmed at step index $idx"
        return 0
      fi
    fi

    sleep 2
  done

  fail "Timed out waiting for CanaryPauseStep"
}

promote_once() {
  log "Promoting to next step..."
  kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE"
}

wait_for_healthy() {
  log "Waiting for Healthy..."
  kubectl argo rollouts status "$ROLLOUT_NAME" -n "$NAMESPACE" --timeout "${WAIT_TIMEOUT}s"
}

promote_to_full() {
  log "Promoting to full..."
  kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE" --full
}

rollback() {
  local failed_rc="${1:-1}"
  set +e
  stop_port_forward

  log "Aborting Rollout '$ROLLOUT_NAME'..."
  kubectl argo rollouts abort "$ROLLOUT_NAME" -n "$NAMESPACE" 2>/dev/null || true

  if [[ -n "$PREVIOUS_IMAGE" && -n "$CONTAINER" ]]; then
    log "Restoring previous image '$PREVIOUS_IMAGE'..."
    kubectl argo rollouts set image "$ROLLOUT_NAME" "$CONTAINER=$PREVIOUS_IMAGE" -n "$NAMESPACE"

    # Force full promotion to skip any remaining canary steps and return to stable.
    log "Promoting to full to complete rollback..."
    kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE" --full 2>/dev/null || true

    kubectl argo rollouts status "$ROLLOUT_NAME" -n "$NAMESPACE" --timeout "${WAIT_TIMEOUT}s" 2>/dev/null || true
  fi

  log "Rollback completed. Original failure exit code: $failed_rc"
  exit "$failed_rc"
}

ensure_httproute() {
  local route="$1"
  local stable_svc="$2"
  local canary_svc="$3"
  if ! kubectl get httproute "$route" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "HTTPRoute '$route' missing; creating..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $route
  namespace: $NAMESPACE
spec:
  parentRefs:
    - name: gateway
      namespace: gateway
  rules:
    - backendRefs:
        - name: $stable_svc
          port: 8080
          weight: 100
        - name: $canary_svc
          port: 8080
          weight: 0
EOF
  fi
}

start_port_forward() {
  local port=$LOCAL_PORT
  local max_attempts=10
  local attempt=0

  while (( attempt < max_attempts )); do
    PORT_FORWARD_LOG="$(mktemp)"
    kubectl port-forward -n "$NAMESPACE" --address 127.0.0.1 \
      "service/$CANARY_SERVICE" "${port}:${CANARY_SERVICE_PORT}" \
      >"$PORT_FORWARD_LOG" 2>&1 &
    PORT_FORWARD_PID=$!
    log "Forwarding $CANARY_SERVICE ${port}->${CANARY_SERVICE_PORT} (pid=$PORT_FORWARD_PID)"

    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
      if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        cat "$PORT_FORWARD_LOG" >&2 || true
        break
      fi
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        exec 3>&-
        LOCAL_PORT=$port
        return 0
      fi
      sleep 1
    done

    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    rm -f "$PORT_FORWARD_LOG"
    attempt=$((attempt + 1))
    port=$((LOCAL_PORT + attempt))
    log "Port $port busy, trying next..."
  done

  fail "Could not establish port-forward after $max_attempts attempts"
}

run_k6() {
  [[ "$SKIP_K6" == false ]] || return 0
  log "Running k6 (QPS=$QPS, duration=$DURATION)..."
  timeout 10m "$K6_BIN" run \
    --env "BASE_URL=http://127.0.0.1:${LOCAL_PORT}" \
    --env "QPS=$QPS" \
    --env "P95_THRESHOLD=$P95_THRESHOLD" \
    --env "ERROR_RATE_THRESHOLD=$ERROR_THRESHOLD" \
    --env "PREALLOCATED_VUS=$PREALLOCATED_VUS" \
    --env "DURATION=$DURATION" \
    --env "GRACEFUL_STOP=$GRACEFUL_STOP" \
    "$K6_SCRIPT"
}

run_playwright() {
  [[ "$SKIP_PLAYWRIGHT" == false ]] || return 0
  log "Running Playwright..."
  (
    cd "$PLAYWRIGHT_DIR"
    [[ -d node_modules ]] || npm ci
    if [[ "${PLAYWRIGHT_INSTALL:-1}" == "1" ]]; then
      npx playwright install --with-deps chromium
    fi
    CI=true \
    PLAYWRIGHT_TEST_BASE_URL="http://127.0.0.1:${LOCAL_PORT}" \
      timeout 10m npx playwright test
  )
}

deploy_one() {
  local svc="$1"
  local img="$2"

  case "$svc" in
    backend)
      ROLLOUT_NAME="backend"
      STABLE_SERVICE="backend-stable"
      CANARY_SERVICE="backend-canary"
      K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/../tests/k6/backend-load.ts}"
      ;;
    frontend)
      ROLLOUT_NAME="frontend"
      STABLE_SERVICE="frontend-stable"
      CANARY_SERVICE="frontend-canary"
      K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/../tests/k6/frontend-load.ts}"
      ;;
  esac

  log "Deploying $svc with image $img"

  detect_strategy
  validate_rollout_healthy
  resolve_container
  resolve_canary_port

  # Idempotency: skip if target image already current.
  if [[ "$PREVIOUS_IMAGE" == "$img" ]]; then
    log "Rollout already using image $img. Skipping update."
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: kubectl argo rollouts set image $ROLLOUT_NAME $CONTAINER=$img -n $NAMESPACE"
    log "DRY-RUN: would wait for canary pause, run validations, promote, etc."
    return 0
  fi

  # Ensure HTTPRoute exists for Argo Gateway plugin.
  ensure_httproute "$ROLLOUT_NAME-route" "$STABLE_SERVICE" "$CANARY_SERVICE"

  log "Setting image on Rollout..."
  kubectl argo rollouts set image "$ROLLOUT_NAME" "$CONTAINER=$img" -n "$NAMESPACE"
  ROLL_OUT_UPDATED=true

  wait_for_canary_pause

  if [[ "$SKIP_PLAYWRIGHT" == false || "$SKIP_K6" == false ]]; then
    start_port_forward
    run_playwright
    run_k6
    stop_port_forward
  fi

  log "All validations passed."

  if [[ "$SKIP_PROMOTE" == true ]]; then
    log "--skip-promote set; leaving Rollout paused at current step."
    return 0
  fi

  promote_once
  wait_for_canary_pause
  log "Observing at 10% for $OBSERVATION_DURATION..."
  sleep "$OBSERVATION_DURATION"

  promote_once
  wait_for_healthy

  ROLL_OUT_UPDATED=false
  log "$svc canary deployment completed successfully."
}

cleanup() {
  log "Cleanup mode: resetting Rollouts to stable v1 images."
  local rollouts=("backend:backend:$BACKEND_STABLE_IMAGE" "frontend:frontend:$FRONTEND_STABLE_IMAGE")

  for entry in "${rollouts[@]}"; do
    IFS=':' read -r rollout container image <<< "$entry"
    ROLLOUT_NAME="$rollout"
    CONTAINER="$container"

    log "Resetting $rollout to $image..."
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY-RUN: kubectl argo rollouts abort $rollout -n $NAMESPACE"
      log "DRY-RUN: kubectl argo rollouts set image $rollout $container=$image -n $NAMESPACE"
      log "DRY-RUN: kubectl argo rollouts promote $rollout --full -n $NAMESPACE"
      log "DRY-RUN: kubectl argo rollouts status $rollout -n $NAMESPACE"
      continue
    fi

    kubectl argo rollouts abort "$rollout" -n "$NAMESPACE" 2>/dev/null || true
    kubectl argo rollouts set image "$rollout" "$container=$image" -n "$NAMESPACE"
    promote_to_full
    kubectl argo rollouts status "$rollout" -n "$NAMESPACE" --timeout "${WAIT_TIMEOUT}s"
  done
  log "Cleanup complete."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) NAMESPACE="${2:-}"; shift 2 ;;
      --service) SERVICE="${2:-}"; shift 2 ;;
      --image) IMAGE="${2:-}"; shift 2 ;;
      --backend-image) BACKEND_IMAGE="${2:-}"; shift 2 ;;
      --frontend-image) FRONTEND_IMAGE="${2:-}"; shift 2 ;;
      --container) CONTAINER="${2:-}"; shift 2 ;;
      --k6-script) K6_SCRIPT="${2:-}"; shift 2 ;;
      --playwright-dir) PLAYWRIGHT_DIR="${2:-}"; shift 2 ;;
      --qps) QPS="${2:-}"; shift 2 ;;
      --error-threshold) ERROR_THRESHOLD="${2:-}"; shift 2 ;;
      --p95-threshold) P95_THRESHOLD="${2:-}"; shift 2 ;;
      --duration) DURATION="${2:-}"; shift 2 ;;
      --graceful-stop) GRACEFUL_STOP="${2:-}"; shift 2 ;;
      --preallocated-vus) PREALLOCATED_VUS="${2:-}"; shift 2 ;;
      --observation-duration) OBSERVATION_DURATION="${2:-}"; shift 2 ;;
      --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
      --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
      --k6-bin) K6_BIN="${2:-}"; shift 2 ;;
      --skip-playwright) SKIP_PLAYWRIGHT=true; shift ;;
      --skip-k6) SKIP_K6=true; shift ;;
      --skip-promote) SKIP_PROMOTE=true; shift ;;
      --cleanup) CLEANUP_MODE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done

  if [[ "$CLEANUP_MODE" == true ]]; then
    return 0
  fi

  [[ -n "$SERVICE" ]] || usage
  [[ "$SERVICE" == "backend" || "$SERVICE" == "frontend" || "$SERVICE" == "all" ]] || fail "service must be backend, frontend, or all"
  [[ -n "$IMAGE" || -n "$BACKEND_IMAGE" || -n "$FRONTEND_IMAGE" ]] || usage
}

preflight() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
  command -v jq >/dev/null 2>&1 || fail "jq not found"
  kubectl argo rollouts version >/dev/null 2>&1 || fail "kubectl-argo-rollouts plugin required"

  if [[ "$DRY_RUN" == false && "$CLEANUP_MODE" == false ]]; then
    if [[ "$SKIP_K6" == false ]]; then
      [[ -x "$K6_BIN" || $(command -v "$K6_BIN" 2>/dev/null) ]] || fail "k6 not found: $K6_BIN"
      [[ -f "$K6_SCRIPT" ]] || fail "k6 script not found: $K6_SCRIPT"
    fi
    if [[ "$SKIP_PLAYWRIGHT" == false ]]; then
      [[ -n "$PLAYWRIGHT_DIR" && -d "$PLAYWRIGHT_DIR" ]] || fail "Playwright dir required: $PLAYWRIGHT_DIR"
      command -v node >/dev/null 2>&1 || fail "node not found"
      command -v npm >/dev/null 2>&1 || fail "npm not found"
    fi
  fi
}

main() {
  parse_args "$@"
  preflight

  if [[ "$CLEANUP_MODE" == true ]]; then
    cleanup
    return 0
  fi

  local services=()
  if [[ "$SERVICE" == "all" ]]; then
    services=(backend frontend)
  else
    services=("$SERVICE")
  fi

  for svc in "${services[@]}"; do
    local img
    if [[ "$svc" == "backend" ]]; then
      img="${IMAGE:-$BACKEND_IMAGE}"
    else
      img="${IMAGE:-$FRONTEND_IMAGE}"
    fi

    SERVICE="$svc"
    case "$svc" in
      backend)
        ROLLOUT_NAME="backend"
        STABLE_SERVICE="backend-stable"
        CANARY_SERVICE="backend-canary"
        K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/../tests/k6/backend-load.ts}"
        ;;
      frontend)
        ROLLOUT_NAME="frontend"
        STABLE_SERVICE="frontend-stable"
        CANARY_SERVICE="frontend-canary"
        K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/../tests/k6/frontend-load.ts}"
        ;;
    esac

    deploy_one "$svc" "$img"
  done

  log "All requested deployments completed."
}

main "$@"
