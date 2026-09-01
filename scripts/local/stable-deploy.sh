#!/usr/bin/env bash
# ==============================================================================
# stable-deploy.sh – Simple Helm-based stable deployment (no canary)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

NAMESPACE="${NAMESPACE:-task-api}"
SERVICE="${1:-all}"
IMAGE_TAG="${2:-v1}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

[[ "$SERVICE" == "backend" || "$SERVICE" == "frontend" || "$SERVICE" == "all" ]] || fail "Usage: $0 <backend|frontend|all> <image-tag>"

helm upgrade --install task-api infra/k8s/task-api \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set postgres.enabled=true \
  --set postgres.env.POSTGRES_PASSWORD="local-dev-password" \
  --set backend.image.repository="ghcr.io/athithya-sakthivel/task-api-backend" \
  --set backend.image.tag="$IMAGE_TAG" \
  --set frontend.image.repository="ghcr.io/athithya-sakthivel/task-api-frontend" \
  --set frontend.image.tag="$IMAGE_TAG" \
  --set backend.canary.enabled=false \
  --set frontend.canary.enabled=false

kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=120s
kubectl argo rollouts status backend -n "$NAMESPACE" --timeout=300s
kubectl argo rollouts status frontend -n "$NAMESPACE" --timeout=300s

log "Stable deployment of $SERVICE with tag $IMAGE_TAG completed."
