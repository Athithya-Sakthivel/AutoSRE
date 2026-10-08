#!/usr/bin/env bash
set -Eeuo pipefail

# export AUTOSRE_SLACK_*
export AUTOSRE_LLM__API_KEY="${AUTOSRE_LLM__API_KEY:?AUTOSRE_LLM__API_KEY is required}}"

# --- Cluster primitives ----------------------------------------------------
bash scripts/staging/kind_cluster.sh       # Bootstrap Kind + Cilium (kube-proxy replacement)
bash scripts/staging/eso_setup.sh          # Install ESO + in-cluster secret store

helm upgrade --install autosre-cilium infra/k8s/cilium/ -n kube-system --wait --timeout 120s # Apply zero-trust network policies

# --- Datastores + rivulet + observability (owned by scripts) ------------------
bash scripts/staging/postgres-deploy.sh    # Deploy Postgres StatefulSet
bash scripts/staging/valkey-deploy.sh      # Deploy Valkey with ACL auth

# rivulet - System Under Test (SUT) for the AutoSRE AI evaluation harness
bash scripts/common/rivulet-api-gateway-deploy.sh deploy      # Java API + Flyway migration
bash scripts/common/rivulet-frontend-deploy.sh deploy         # React SPA
bash scripts/common/rivulet-ingestion-worker-deploy.sh deploy # Go stream consumer

bash scripts/staging/openobserve.sh deploy # Deploy OpenObserve minimal
bash scripts/common/otel-gateway-deploy.sh # Deploy OTel Collector gateway
bash scripts/common/otel-daemonset-deploy.sh # Deploy OTel node agents

# --- O2 alerting (owned by Terraform) --------------------------------------
kubectl -n openobserve wait --for=condition=available deploy/openobserve --timeout=60s || { kubectl -n openobserve logs deploy/openobserve --tail=100; exit 1; }

# Establish reliable port-forward for Terraform provisioning
pkill -f '[k]ubectl.*port-forward.*5080:5080' 2>/dev/null || true
fuser -k 5080/tcp 2>/dev/null || true; rm -f /tmp/openobserve-portforward.log
nohup kubectl -n openobserve port-forward svc/openobserve 5080:5080 >/tmp/openobserve-portforward.log 2>&1 </dev/null & PF=$!
for i in {1..30}; do curl -fsS http://localhost:5080 >/dev/null 2>&1 && break; kill -0 "$PF" 2>/dev/null || break; sleep 1; done
curl -fsS http://localhost:5080 >/dev/null 2>&1 && echo "OpenObserve ready" || { echo "Port-forward failed"; cat /tmp/openobserve-portforward.log; kubectl -n openobserve logs deploy/openobserve --tail=100; exit 1; }

bash infra/terraform/run.sh --apply        # Provision O2 streams, alerts, and roles

bash scripts/common/autosre-agent-deploy.sh deploy

# --- Verify ----------------------------------------------------------------
kubectl get pods -A                        # Check all workload status
kubectl get daemonset -A                   # Verify infrastructure agents
kubectl get secrets -A                     # Confirm ESO sync
bash scripts/common/test-o2.sh             # Run end-to-end telemetry smoke test
