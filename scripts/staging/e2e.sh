#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# LLM provider
# ---------------------------------------------------------------------------
# The router prefixes every model ID with AUTOSRE_LLM__PROVIDER unless it
# already carries that prefix. Model IDs that contain a slash of their
# own (openai/gpt-oss-20b, qwen/qwen3.8-27b) are NOT considered prefixed.
# This is why groq + openai/gpt-oss-20b → groq/openai/gpt-oss-20b.

export AUTOSRE_LLM__PROVIDER="groq"                             # groq | openai | anthropic | ollama
export AUTOSRE_LLM__BASE_URL="https://api.groq.com/openai/v1"
export AUTOSRE_LLM__MODEL_COORDINATOR="qwen/qwen3.8-27b"
export AUTOSRE_LLM__MODEL_WORKER="openai/gpt-oss-20b"
export AUTOSRE_LLM__API_KEY=""

# Optional. When the primary provider fails after retries, LiteLLM
# transparently retries on the first model in this list.
# export AUTOSRE_LLM__FALLBACK_MODELS='["openai/gpt-4o-mini"]'

# Token pricing (USD / 1K tokens)
export AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR="0.0008"
export AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR="0.004"
export AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER="0.000075"
export AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER="0.0003"

# ---------------------------------------------------------------------------
# Eval judge
# ---------------------------------------------------------------------------
# The judge bypasses TokenVelocityRouter and is passed directly to
# LiteLLM, so its model ID MUST be fully qualified.

export AUTOSRE_EVAL__JUDGE_MODEL="groq/openai/gpt-oss-20b"
export AUTOSRE_EVAL__JUDGE_BASE_URL="${AUTOSRE_LLM__BASE_URL}"
export AUTOSRE_EVAL__JUDGE_API_KEY="${AUTOSRE_LLM__API_KEY}"

# Terraform (O2 alerts)
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
