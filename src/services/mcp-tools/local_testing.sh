#!/usr/bin/env bash
# =============================================================================
# mcp-tools – Production-mode battle test (secrets via Azure Key Vault only)
# =============================================================================
# Prerequisites: az login, TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT exported.
# Usage:
#   export TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT="your_pat"
#   bash services/mcp-tools/local_testing.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

export TZ='Asia/Kolkata'

log()   { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
warn()  { printf '[%(%H:%M:%S)T] WARNING: %s\n' -1 "$*" >&2; }
error() { printf '[%(%H:%M:%S)T] ERROR: %s\n' -1 "$*" >&2; exit 1; }

# -------------------------------------------------------------------
# 1. Configuration
# -------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_DIR="$PROJECT_ROOT/services/mcp-tools"
VENV_DIR="$SERVICE_DIR/.venv_mcp_tools"
REQUIREMENTS="$SERVICE_DIR/requirements.txt"

RG='rg-target-system-12'
LOCATION='eastus'
LAW='law-target-system'
APPINSIGHTS='appi-target-system'
KEYVAULT='kv-target-system-xfmyt'

MCP_PORT="${MCP_PORT:-8000}"
MCP_URL="http://127.0.0.1:${MCP_PORT}"
MCP_ENDPOINT="${MCP_URL}/mcp"
SERVER_LOG='/tmp/mcp_tools_server.log'
CURL_LOG='/tmp/mcp_tools_curl.log'

# -------------------------------------------------------------------
# 2. Virtualenv & dependencies
# -------------------------------------------------------------------
log 'Setting up virtualenv...'
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

log 'Installing/updating dependencies...'
pip install -r "$REQUIREMENTS" --quiet

for pkg in pytest httpx fastmcp; do
  if ! pip show "$pkg" >/dev/null 2>&1; then
    pip install "$pkg" --quiet
  fi
done

find "$SERVICE_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$SERVICE_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true
kill $(lsof -t -i:8000) 2>/dev/null || true

# -------------------------------------------------------------------
# 3. Azure provisioning (idempotent)
# -------------------------------------------------------------------
log 'Checking Azure login...'
az account show >/dev/null 2>&1 || error "Run 'az login' first."

az group show --name "$RG" >/dev/null 2>&1 || az group create --name "$RG" --location "$LOCATION" --output none
az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" >/dev/null 2>&1 || \
  az monitor log-analytics workspace create --resource-group "$RG" --workspace-name "$LAW" --location "$LOCATION" --output none
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" --query id -o tsv)

if ! az extension show --name application-insights >/dev/null 2>&1; then
  az extension add --name application-insights --only-show-errors
fi
az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" >/dev/null 2>&1 || \
  az monitor app-insights component create --app "$APPINSIGHTS" --resource-group "$RG" --location "$LOCATION" --kind web --application-type web --workspace "$WORKSPACE_ID" --output none
APPINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" --query connectionString -o tsv)

az keyvault show --name "$KEYVAULT" --resource-group "$RG" >/dev/null 2>&1 || \
  az keyvault create --name "$KEYVAULT" --resource-group "$RG" --location "$LOCATION" --enable-rbac-authorization true --output none

KV_SCOPE=$(az keyvault show --name "$KEYVAULT" --resource-group "$RG" --query id -o tsv)
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
ROLE='Key Vault Secrets Officer'
ASSIGNMENT=$(az role assignment list --assignee "$USER_OBJECT_ID" --scope "$KV_SCOPE" --role "$ROLE" --query "[0].id" -o tsv 2>/dev/null || echo '')
if [ -z "$ASSIGNMENT" ]; then
  az role assignment create --assignee-object-id "$USER_OBJECT_ID" --assignee-principal-type User --role "$ROLE" --scope "$KV_SCOPE" --output none || warn 'Role assignment failed.'
  sleep 15
fi

# -------------------------------------------------------------------
# 4. Store ALL secrets in Key Vault (idempotent)
# -------------------------------------------------------------------
store_secret() {
  local secret_name="$1" secret_value="$2"
  local current
  current=$(az keyvault secret show --vault-name "$KEYVAULT" --name "$secret_name" --query value -o tsv 2>/dev/null || echo '')
  if [ "$current" = "$secret_value" ]; then
    log "Secret '$secret_name' already up‑to‑date."
  else
    log "Storing secret '$secret_name'..."
    az keyvault secret set --vault-name "$KEYVAULT" --name "$secret_name" --value "$secret_value" --output none
  fi
}

store_secret "appinsights-connection-string" "$APPINSIGHTS_CONNECTION_STRING"

# mcp-api-key (use existing or create a throw‑away test key)
MCP_API_KEY=$(az keyvault secret show --vault-name "$KEYVAULT" --name "mcp-api-key" --query value -o tsv 2>/dev/null || echo '')
if [ -z "$MCP_API_KEY" ]; then
  MCP_API_KEY="local-testing-key-$(date +%s)"
  log "Generating new mcp-api-key: ${MCP_API_KEY:0:4}..."
fi
store_secret "mcp-api-key" "$MCP_API_KEY"

# github token (must be provided via TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT)
if [ -n "${TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT:-}" ]; then
  store_secret "github-token" "$TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT"
else
  error "TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT is not set. Export it before running."
fi

# azure subscription id (not a real secret, but let's be consistent)
AZURE_SUB_ID=$(az account show --query id -o tsv)
store_secret "azure-subscription-id" "$AZURE_SUB_ID"

# -------------------------------------------------------------------
# 5. Export non‑secret environment variables
# -------------------------------------------------------------------
export MCP_TOOLS_MODE=production
export MCP_TOOLS_BATTLE_TEST=false

# KEY_VAULT_NAME is the ONLY trigger for secret loading
export KEY_VAULT_NAME="$KEYVAULT"
# (no APPLICATIONINSIGHTS_CONNECTION_STRING, MCP_API_KEY, GITHUB_TOKEN, AZURE_SUBSCRIPTION_ID here)

export LOG_ANALYTICS_WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" --query customerId -o tsv)
export AZURE_RESOURCE_GROUP="$RG"
export AZURE_CONTAINER_APP_NAME="dummy"
export GIT_REPO_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  REMOTE_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || echo "")
  if echo "$REMOTE_URL" | grep -q "github.com"; then
    GITHUB_REPOSITORY=$(echo "$REMOTE_URL" | sed -E 's|.*github.com[/:](.*)|\1|' | sed 's/\.git$//')
  fi
fi
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY}"
export GITHUB_HEAD_BRANCH="main"

export OTEL_SAMPLING_MODE='rate'
export OTEL_TRACES_PER_SECOND='5'
export OTEL_ENABLE_LIVE_METRICS='true'

# -------------------------------------------------------------------
# 6. Run pytest (mock tools – no Azure needed)
# -------------------------------------------------------------------
log 'Running pytest...'
cd "$SERVICE_DIR"
python -m pytest tests/ -v

# -------------------------------------------------------------------
# 7. Start FastMCP server (secrets will be fetched from Key Vault)
# -------------------------------------------------------------------

log "Starting mcp-tools server (production, logs → $SERVER_LOG)..."

> "$SERVER_LOG"

# Run from the service root so "_mcp" is importable.
cd "$SERVICE_DIR"
export PYTHONPATH="$SERVICE_DIR"

python -m _mcp.main >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >/tmp/mcp_tools_server.pid

log 'Waiting for server to become healthy...'

HEALTHY=false

for i in {1..30}; do

    # If startup crashed, fail immediately and print the traceback.
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo
        echo "========================================================"
        echo "FastMCP server exited during startup."
        echo "========================================================"
        cat "$SERVER_LOG"
        exit 1
    fi

    if curl -fsS "${MCP_URL}/health" >/dev/null 2>&1; then
        HEALTHY=true
        log "Server is healthy (PID $SERVER_PID)."
        break
    fi

    sleep 1
done

if [ "$HEALTHY" != "true" ]; then
    echo
    echo "========================================================"
    echo "Server never became healthy."
    echo "========================================================"
    cat "$SERVER_LOG"
    kill "$SERVER_PID" 2>/dev/null || true
    exit 1
fi
# -------------------------------------------------------------------
# 8. Battle test ALL six tools
# -------------------------------------------------------------------
log "Running MCP tool tests (output → $CURL_LOG)..."
{
  echo "===== $(date) ====="
  echo ''

  echo "--- GET /health ---"
  curl -s "${MCP_URL}/health" | python -m json.tool
  echo ''

  echo "--- GET /ready ---"
  curl -s "${MCP_URL}/ready"
  echo ''

  echo "--- Registered tools ---"
  fastmcp list "${MCP_ENDPOINT}" --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || true
  echo ''

  echo "--- tool: query_traces ---"
  fastmcp call "${MCP_ENDPOINT}" query_traces service_name=target-system time_range_minutes=30 limit=2 --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(no data or error)"
  echo ''

  echo "--- tool: query_logs ---"
  fastmcp call "${MCP_ENDPOINT}" query_logs service_name=target-system time_range_minutes=30 limit=2 --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(no data or error)"
  echo ''

  echo "--- tool: git_blame ---"
  fastmcp call "${MCP_ENDPOINT}" git_blame repo="" file_path=README.md line_number=1 --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(error)"
  echo ''

  echo "--- tool: get_code_snippet ---"
  fastmcp call "${MCP_ENDPOINT}" get_code_snippet repo="" file_path=README.md line_start=1 line_end=5 --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(error)"
  echo ''

  echo "--- tool: create_pr ---"
  fastmcp call "${MCP_ENDPOINT}" create_pr repo="${GITHUB_REPOSITORY}" title="[Battle Test] Automated PR" description="Expected to fail with 422." diff="--- a/README.md\n+++ b/README.md\n@@ -1,3 +1,3 @@\n-# Title\n+# New Title" --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(expected error: GitHub 422)"
  echo ''

  echo "--- tool: restart_aca_revision ---"
  fastmcp call "${MCP_ENDPOINT}" restart_aca_revision service_name=dummy --auth "$MCP_API_KEY" 2>&1 | grep -v "UserWarning\|oauth.py\|site-packages\|/fastmcp/client/auth/\|self._bind" || echo "(expected error: Azure 404)"
  echo ''
} > "$CURL_LOG" 2>&1

# -------------------------------------------------------------------
# 9. Display logs & cleanup
# -------------------------------------------------------------------
log 'Server log tail (last 20 lines):'
tail -n 20 "$SERVER_LOG"

log 'MCP tool test log tail (last 50 lines):'
tail -n 50 "$CURL_LOG"

log "Stopping server (PID $SERVER_PID)..."
kill "$SERVER_PID" 2>/dev/null || true
rm -f /tmp/mcp_tools_server.pid

log 'All done.'