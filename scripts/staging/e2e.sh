#!/usr/bin/env bash
set -Eeuo pipefail

# AutoSRE staging environment — flat variables

# LLM provider
export AUTOSRE_LLM_PROVIDER="${AUTOSRE_LLM_PROVIDER:-groq}"
export AUTOSRE_LLM_BASE_URL="${AUTOSRE_LLM_BASE_URL:-https://api.groq.com/openai/v1}"
export AUTOSRE_LLM_MODEL_COORDINATOR="${AUTOSRE_LLM_MODEL_COORDINATOR:-qwen/qwen3.8-27b}"
export AUTOSRE_LLM_MODEL_WORKER="${AUTOSRE_LLM_MODEL_WORKER:-openai/gpt-oss-20b}"
# Require LLM API key
: "${AUTOSRE_LLM__API_KEY:?Set AUTOSRE_LLM__API_KEY before running e2e.sh}"

export AUTOSRE_LLM_INPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM_INPUT_COST_PER_1K_COORDINATOR:-0.0008}"
export AUTOSRE_LLM_OUTPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM_OUTPUT_COST_PER_1K_COORDINATOR:-0.004}"
export AUTOSRE_LLM_INPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM_INPUT_COST_PER_1K_WORKER:-0.000075}"
export AUTOSRE_LLM_OUTPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM_OUTPUT_COST_PER_1K_WORKER:-0.0003}"

# Eval judge
export AUTOSRE_EVAL_JUDGE_MODEL="${AUTOSRE_EVAL_JUDGE_MODEL:-openai/gpt-oss-120b}"
export AUTOSRE_EVAL_JUDGE_BASE_URL="${AUTOSRE_EVAL_JUDGE_BASE_URL:-$AUTOSRE_LLM_BASE_URL}"
export AUTOSRE_EVAL_JUDGE_API_KEY="${AUTOSRE_EVAL_JUDGE_API_KEY:-$AUTOSRE_LLM__API_KEY}"
: "${AUTOSRE_EVAL_JUDGE_MODEL:?Judge model must be set}"
: "${AUTOSRE_EVAL_JUDGE_API_KEY:?Judge API key must be set}"

# Postgres
export AUTOSRE_POSTGRES_HOST="${AUTOSRE_POSTGRES_HOST:-localhost}"
export AUTOSRE_POSTGRES_PORT="${AUTOSRE_POSTGRES_PORT:-15432}"
export AUTOSRE_POSTGRES_DB="${AUTOSRE_POSTGRES_DB:-app}"
export AUTOSRE_POSTGRES_USER="${AUTOSRE_POSTGRES_USER:-app}"
export AUTOSRE_POSTGRES_PASSWORD="${AUTOSRE_POSTGRES_PASSWORD:-}"

# Valkey
export AUTOSRE_VALKEY_HOST="${AUTOSRE_VALKEY_HOST:-localhost}"
export AUTOSRE_VALKEY_PORT="${AUTOSRE_VALKEY_PORT:-16379}"
export AUTOSRE_VALKEY_PASSWORD="${AUTOSRE_VALKEY_PASSWORD:-}"
export AUTOSRE_VALKEY_TLS="${AUTOSRE_VALKEY_TLS:-false}"

# OpenObserve
export AUTOSRE_OPENOBSERVE_URL="${AUTOSRE_OPENOBSERVE_URL:-http://localhost:15080}"
export AUTOSRE_OPENOBSERVE_EMAIL="${AUTOSRE_OPENOBSERVE_EMAIL:-admin@autosre.local}"
export AUTOSRE_OPENOBSERVE_PASSWORD="${AUTOSRE_OPENOBSERVE_PASSWORD:-}"
export AUTOSRE_ALERT_WEBHOOK_SECRET="${AUTOSRE_ALERT_WEBHOOK_SECRET:-test-secret}"

# OpenTelemetry
export AUTOSRE_OTEL_EXPORTER_OTLP_ENDPOINT="${AUTOSRE_OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:14318}"
export AUTOSRE_OTEL_SERVICE_NAME="${AUTOSRE_OTEL_SERVICE_NAME:-autosre-agent}"
export AUTOSRE_OTEL_DEPLOYMENT_ENVIRONMENT="${AUTOSRE_OTEL_DEPLOYMENT_ENVIRONMENT:-evaluation}"
export AUTOSRE_DEPLOYMENT_ENVIRONMENT="${AUTOSRE_DEPLOYMENT_ENVIRONMENT:-evaluation}"

# Safety limits
export AUTOSRE_SAFETY_MAX_RISK_TIER_AUTONOMOUS="${AUTOSRE_SAFETY_MAX_RISK_TIER_AUTONOMOUS:-1}"
export AUTOSRE_SAFETY_MAX_ACTIONS_PER_INCIDENT="${AUTOSRE_SAFETY_MAX_ACTIONS_PER_INCIDENT:-10}"
export AUTOSRE_SAFETY_MAX_WALL_CLOCK_SECONDS="${AUTOSRE_SAFETY_MAX_WALL_CLOCK_SECONDS:-600}"

# Slack
if [[ -n "${AUTOSRE_SLACK_BOT_TOKEN:-}" ]]; then
    export AUTOSRE_SLACK_MODE="${AUTOSRE_SLACK_MODE:-socket}"
    export AUTOSRE_SLACK_APPROVAL_CHANNEL="${AUTOSRE_SLACK_APPROVAL_CHANNEL:-}"
    export AUTOSRE_SLACK_APPROVER_USER_IDS="${AUTOSRE_SLACK_APPROVER_USER_IDS:-[]}"
    if [[ "$AUTOSRE_SLACK_MODE" == "socket" ]]; then
        : "${AUTOSRE_SLACK_APP_TOKEN:?Slack socket mode requires AUTOSRE_SLACK_APP_TOKEN}"
    else
        : "${AUTOSRE_SLACK_SIGNING_SECRET:?Slack http mode requires AUTOSRE_SLACK_SIGNING_SECRET}"
    fi
fi

# Terraform / OpenObserve
export TF_VAR_o2_email=admin@autosre.local
export TF_VAR_o2_password='StagingO2RootPass123!'
export TF_VAR_o2_endpoint=http://localhost:5080
export TF_VAR_o2_organization=default


# --- Preflight -------------------------------------------------------------
if [[ -z "${AUTOSRE_LLM__API_KEY}" ]]; then
  echo "FATAL: LLM_API_KEY is not set and AUTOSRE_LLM__API_KEY is empty." >&2
  echo "       export LLM_API_KEY='gsk_...' and re-run." >&2
  exit 1
fi

# --- Cluster primitives ----------------------------------------------------
bash scripts/staging/kind_cluster.sh
helm upgrade --install autosre-cilium infra/k8s/cilium/ \
  -n kube-system --wait --timeout 120s

# --- Datastores + observability + apps (owned by scripts) ------------------
bash scripts/staging/postgres-deploy.sh
bash scripts/staging/valkey-deploy.sh
bash scripts/staging/openobserve.sh deploy
bash scripts/common/otel-gateway-deploy.sh
bash scripts/common/otel-daemonset-deploy.sh
bash scripts/common/rivulet-api-gateway-deploy.sh deploy
bash scripts/common/rivulet-frontend-deploy.sh deploy
bash scripts/common/rivulet-ingestion-worker-deploy.sh deploy

# --- O2 alerting (owned by Terraform) --------------------------------------

kubectl -n openobserve wait --for=condition=available deploy/openobserve --timeout=60s || { kubectl -n openobserve logs deploy/openobserve --tail=100; exit 1; }
pkill -f '[k]ubectl.*port-forward.*5080:5080' 2>/dev/null || true
fuser -k 5080/tcp 2>/dev/null || true; rm -f /tmp/openobserve-portforward.log
nohup kubectl -n openobserve port-forward svc/openobserve 5080:5080 >/tmp/openobserve-portforward.log 2>&1 </dev/null & PF=$!
for i in {1..30}; do curl -fsS http://localhost:5080 >/dev/null 2>&1 && break; kill -0 "$PF" 2>/dev/null || break; sleep 1; done
curl -fsS http://localhost:5080 >/dev/null 2>&1 && echo "OpenObserve ready" || { echo "Port-forward failed"; cat /tmp/openobserve-portforward.log; kubectl -n openobserve logs deploy/openobserve --tail=100; exit 1; }


bash infra/terraform/run.sh --apply

# --- Verify ----------------------------------------------------------------
kubectl get pods -A
kubectl get daemonset -A
kubectl get secrets -A
kubectl get ciliumnetworkpolicy -A
bash scripts/common/test-o2.sh
