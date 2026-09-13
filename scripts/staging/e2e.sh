export LLM_API_KEY=$LLM_API_KEY

# Create the kind cluster (if not already running)
bash scripts/local/kind_cluster.sh

# Azure bootstrap
bash infra/terraform/staging/run.sh --apply

export KEYVAULT_NAME="$(cd infra/terraform/staging && tofu output -raw key_vault_name)"

az keyvault secret set --vault-name "$KEYVAULT_NAME" --name LlmApiKey --value $LLM_API_KEY

bash scripts/common/eso-azure.sh

# Verify
kubectl get clustersecretstore azure-keyvault
kubectl get externalsecret -A
kubectl get secret llm-credentials -n sre -o jsonpath='{.data}' | jq 'keys'
kubectl get secret postgres-app -n apps -o jsonpath='{.data}' | jq 'keys'
kubectl get secret otel-gateway-token -n apps -o jsonpath='{.data}' | jq 'keys'
kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data}' | jq 'keys'


#  Deploy OpenObserve
bash scripts/common/open-observe/deploy.sh

# Deploy the OTel gateway (application traces, metrics, logs)
bash scripts/common/otel-gateway-deploy.sh

# Deploy the OTel DaemonSet (node/pod/container metrics)
bash scripts/common/otel-daemonset-deploy.sh

kubectl get pods -n openobserve
kubectl get daemonset -n openobserve
kubectl get secrets -n openobserve

bash tests/infra/observability.sh
