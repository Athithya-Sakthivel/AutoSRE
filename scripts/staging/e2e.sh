#!/usr/bin/env bash
set -Eeuo pipefail

export LLM_PROVIDER="${LLM_PROVIDER:-groq}"
export LLM_BASE_URL="${LLM_BASE_URL:-https://api.groq.com/openai/v1}"
export LLM_API_KEY="${LLM_API_KEY:?LLM_API_KEY is required but empty}"
export LLM_MODEL_COORDINATOR="${LLM_MODEL_COORDINATOR:-openai/gpt-oss-120b}"
export LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-openai/gpt-oss-20b}"
export LLM_MODEL_SYNTHESIZER="${LLM_MODEL_SYNTHESIZER:-openai/gpt-oss-120b}"
export LLM_MODEL_SELF_CHECK="${LLM_MODEL_SELF_CHECK:-openai/gpt-oss-20b}"


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



# Verify
kubectl get clustersecretstore -A
kubectl get externalsecret -A

kubectl get pods -n openobserve
kubectl get daemonset -n openobserve
kubectl get secrets -n openobserve

bash tests/infra/observability.sh

# Verify policies are applied
kubectl get ciliumnetworkpolicy -A
