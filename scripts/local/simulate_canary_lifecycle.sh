# prerequesites in kind cluster
# bash scripts/local/cluster_bootstrap.sh
# bash scripts/local/setup_charts.sh

kubectl delete ns task-api --force || true

bash scripts/local/setup_apps.sh


bash scripts/local/deploy-postgres.sh

bash azure-pipelines/scripts/backend-deploy.sh --stable --stable-tag v1
bash azure-pipelines/scripts/frontend-deploy.sh --stable --stable-tag v1

bash azure-pipelines/scripts/backend-deploy.sh \
  --canary \
  --image ghcr.io/athithya-sakthivel/task-api-backend:v2 \
  --qps 2 \
  --p95-threshold 5000 \
  --error-threshold 0.05 \
  --duration 15s \
  --observation-duration 15s
