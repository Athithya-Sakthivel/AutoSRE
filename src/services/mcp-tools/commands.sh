python3 -m venv .venv_mcp_tools
source .venv_mcp_tools/bin/activate
pip install -r src/services/mcp-tools/requirements.txt


az keyvault secret set --vault-name kv-target-system-xfmgz --name mcp-api-key --value "local-temp-pass"

docker build -t mcp-tools src/services/mcp-tools

docker stop mcp-tools-prod 2>/dev/null || true
docker rm mcp-tools-prod 2>/dev/null || true

TOKEN=$(az account get-access-token \
  --resource https://api.loganalytics.io \
  --query accessToken -o tsv)

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g rg-target-system-12 \
  -n law-target-system \
  --query customerId -o tsv)

curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.loganalytics.io/v1/workspaces/${WORKSPACE_ID}/query" \
  -d '{
    "query":"AppTraces | where TimeGenerated > ago(1h) | where AppRoleName in (\"target-system\", \"mcp-tools\") | take 10"
  }' | jq


docker run -d \
  --name mcp-tools-prod \
  -p 8000:8000 \
  -e MCP_TOOLS_MODE=production \
  -e MCP_TOOLS_BATTLE_TEST=true \
  -e APPLICATIONINSIGHTS_CONNECTION_STRING="$APPINSIGHTS_CS" \
  -e LOG_ANALYTICS_WORKSPACE_ID="$LAW_ID" \
  -e AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)" \
  -e AZURE_RESOURCE_GROUP="rg-target-system-12" \
  -e AZURE_CONTAINER_APP_NAME="dummy" \
  -e GIT_REPO_ROOT="/app" \
  -e GITHUB_TOKEN="${TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT:-}" \
  -e GITHUB_REPOSITORY="Athithya-Sakthivel/incident-commander-ai" \
  -e GITHUB_HEAD_BRANCH="main" \
  mcp-tools

sleep 5
docker logs mcp-tools-prod --tail 10
fastmcp call http://127.0.0.1:8000/mcp query_traces service_name=target-system time_range_minutes=60 limit=5