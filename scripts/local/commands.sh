bash scripts/local/cluster_bootstrap.sh
bash scripts/local/setup_charts.sh
bash scripts/local/setup_apps.sh



helm upgrade --install task-api infra/k8s/task-api \
  --namespace task-api \
  --set postgres.enabled=true \
  --set postgres.env.POSTGRES_PASSWORD="local-dev-password" \
  --set backend.image.repository="ghcr.io/athithya-sakthivel/task-api-backend" \
  --set backend.image.tag="v1" \
  --set frontend.image.repository="ghcr.io/athithya-sakthivel/task-api-frontend" \
  --set frontend.image.tag="v1" \
  --set backend.canary.enabled=true \
  --set frontend.canary.enabled=true
