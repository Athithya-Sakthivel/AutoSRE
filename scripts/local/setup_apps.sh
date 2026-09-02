#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace cloudflared 2>/dev/null || true
kubectl create namespace task-api 2>/dev/null || true

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
SUFFIX="${SUBSCRIPTION_ID: -6}"
KV_NAME="kv-azdo-bootstrap-${SUFFIX}"
KV_URL="https://${KV_NAME}.vault.azure.net"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SP_NAME="kind-eso-sp-${SUFFIX}"

EXISTING_SP="$(az ad sp list --display-name "${SP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)"

if [[ -n "${EXISTING_SP}" ]]; then
  APP_ID="${EXISTING_SP}"
  PASSWORD="$(az ad sp credential reset --id "${APP_ID}" --query password -o tsv)"
else
  SP_OUTPUT="$(az ad sp create-for-rbac --name "${SP_NAME}")"
  APP_ID="$(echo "$SP_OUTPUT" | jq -r '.appId')"
  PASSWORD="$(echo "$SP_OUTPUT" | jq -r '.password')"
fi

KV_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/rg-sm-state-${SUFFIX}/providers/Microsoft.KeyVault/vaults/${KV_NAME}"

az role assignment create \
  --assignee "${APP_ID}" \
  --role "Key Vault Secrets User" \
  --scope "${KV_ID}" \
  --output none 2>/dev/null || true

kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

# for kind cluster
kubectl create secret generic azure-sp-creds \
  --namespace external-secrets \
  --from-literal=clientId="${APP_ID}" \
  --from-literal=clientSecret="${PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install eso-config ./infra/k8s/externalsecrets \
  --namespace external-secrets \
  --set keyVault.url="${KV_URL}" \
  --set keyVault.tenantId="${TENANT_ID}" \
  --set auth.mode=ServicePrincipal

helm upgrade --install cloudflared infra/k8s/cloudflared   --namespace cloudflared   --create-namespace

helm upgrade --install cilium infra/k8s/cilium \
  --namespace gateway \
  --create-namespace

# deploy stable version without canary
helm upgrade --install task-api infra/k8s/task-api \
  --namespace task-api \
  --create-namespace \
  --set postgres.enabled=true \
  --set postgres.env.POSTGRES_PASSWORD="local-dev-password" \
  --set backend.image.repository="ghcr.io/athithya-sakthivel/task-api-backend" \
  --set backend.image.tag="v1" \
  --set frontend.image.repository="ghcr.io/athithya-sakthivel/task-api-frontend" \
  --set frontend.image.tag="v1" \
  --set backend.enabled=true \
  --set frontend.enabled=true \
  --set backend.canary.enabled=false \
  --set frontend.canary.enabled=false
