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


bash scripts/staging/kind_cluster.sh

bash scripts/staging/eso_local.sh

bash scripts/staging/postgres-deploy.sh
bash scripts/staging/valkey-deploy.sh

#  Deploy OpenObserve
bash scripts/staging/openobserve.sh deploy

# Deploy the OTel gateway (application traces, metrics, logs)
bash scripts/common/otel-gateway-deploy.sh

# Deploy the OTel DaemonSet (node/pod/container metrics)
bash scripts/common/otel-daemonset-deploy.sh


# Install the chart
helm upgrade --install autosre-cilium infra/k8s/cilium/ \
  --namespace kube-system \
  --wait \
  --timeout 120s

bash scripts/common/rivulet-api-gateway-deploy.sh deploy
bash scripts/common/rivulet-frontend-deploy.sh deploy
bash scripts/common/rivulet-ingestion-worker-deploy.sh deploy

# Verify
kubectl get clustersecretstore -A
kubectl get externalsecret -A

kubectl get pods -A
kubectl get daemonset -A
kubectl get secrets -A

bash scripts/common/test-o2.sh

# Verify policies are applied
kubectl get ciliumnetworkpolicy -A
