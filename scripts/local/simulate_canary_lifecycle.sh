
# prerequesites
# bash scripts/local/cluster_bootstrap.sh
# bash scripts/local/setup_charts.sh
# bash scripts/local/setup_apps.sh


# patch those steps to [{"setWeight":100}] again and abort/restore v1, making it fully idempotent.
bash azure-pipelines/scripts/canary-deploy.sh --cleanup


# simulate rollback
bash azure-pipelines/scripts/canary-deploy.sh \
  --service frontend \
  --image ghcr.io/athithya-sakthivel/task-api-frontend:v2 \
  --playwright-dir azure-pipelines/tests/playwright \
  --k6-script azure-pipelines/tests/k6/frontend-load.ts \
  --qps 30 \
  --error-threshold 0.02 \
  --p95-threshold 300 \
  --duration 15s \
  --observation-duration 15s
