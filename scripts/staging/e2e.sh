#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# LLM provider configuration — Google Gemini via LiteLLM
# -----------------------------------------------------------------------------
#
# Model IDs use the LiteLLM canonical form: gemini/<google-model-id>.
# LiteLLM infers the provider from the "gemini/" prefix and routes to
# the Google AI Studio endpoint. No base_url override is needed.
#
# Both coordinator and worker default to the same model because Gemini
# 3.8 Flash has identical pricing and context window for both tiers.
# The router still functions correctly as a pass-through; split to a
# cheaper model later when paid-tier pricing diverges.
#
# API key: a single Google AI Studio key (AIza...) serves both the
# agent and the DeepEval judge. No separate GROQ_API_KEY is needed.

# Model selection. Override to test alternative Gemini models:
#   gemini/gemini-3.5-flash-lite   (higher RPD on free tier)
#   gemini/gemini-3.7-flash        (same pricing as 3.8)
export AUTOSRE_LLM__MODEL_COORDINATOR="${AUTOSRE_LLM__MODEL_COORDINATOR:-gemini/gemini-3.8-flash}"
export AUTOSRE_LLM__MODEL_WORKER="${AUTOSRE_LLM__MODEL_WORKER:-gemini/gemini-3.5-flash-lite}"

# API key. Accepts either LLM_API_KEY (legacy) or AUTOSRE_LLM__API_KEY.
export AUTOSRE_LLM__API_KEY="${AUTOSRE_LLM__API_KEY:-${LLM_API_KEY:?LLM_API_KEY is required}}"

# Token pricing (USD / 1K tokens) — Gemini 3.x Standard tier.
# Free tier bills $0.00, but the eval harness uses these rates to
# project production costs and validate cost-efficiency constraints.

export AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR:-0.00075}"
export AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR:-0.00375}"
export AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER:-0.00075}"
export AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER:-0.00375}"

export AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS="1"
export AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT="10"
export AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS="600"

# -----------------------------------------------------------------------------
# Eval judge configuration
# -----------------------------------------------------------------------------
# The judge uses the same Gemini model as the agent. DeepEval's
# LiteLLMModel constructor accepts the canonical LiteLLM model ID
# and passes it through to litellm.completion(). No base_url override
# is needed for standard Google AI Studio access.
#
# The judge does NOT set temperature=0. Google's Gemini 3 documentation
# warns that lowering temperature below the default (1.0) can degrade
# reasoning quality and cause infinite generation loops. Instead, we
# use generation_kwargs.reasoning_effort to control depth.

export AUTOSRE_EVAL__JUDGE_MODEL="${AUTOSRE_EVAL__JUDGE_MODEL:-gemini/gemini-3.5-flash-lite}"
export AUTOSRE_EVAL__JUDGE_API_KEY="${AUTOSRE_EVAL__JUDGE_API_KEY:-$AUTOSRE_LLM__API_KEY}"


# --- Cluster primitives ----------------------------------------------------
bash scripts/staging/kind_cluster.sh
bash scripts/staging/eso_local.sh

# --- Datastores + observability + apps (owned by scripts) ------------------
bash scripts/staging/postgres-deploy.sh
bash scripts/staging/valkey-deploy.sh


export O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"
export O2_ORG="${O2_ORG:-${TF_VAR_o2_organization:-default}}"

bash scripts/staging/openobserve.sh deploy
bash scripts/common/otel-gateway-deploy.sh
bash scripts/common/otel-daemonset-deploy.sh


bash scripts/common/rivulet-api-gateway-deploy.sh deploy
bash scripts/common/rivulet-frontend-deploy.sh deploy
bash scripts/common/rivulet-ingestion-worker-deploy.sh deploy

# --- O2 alerting (owned by Terraform) --------------------------------------

export TF_VAR_o2_email=admin@autosre.local
export TF_VAR_o2_password='StagingO2RootPass123!'
export TF_VAR_o2_endpoint=http://localhost:5080
export TF_VAR_o2_organization=default

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
bash scripts/common/test-o2.sh


# Cilium setup is for v2 only
# helm upgrade --install autosre-cilium infra/k8s/cilium/ -n kube-system --wait --timeout 120s
# kubectl get ciliumnetworkpolicy -A
