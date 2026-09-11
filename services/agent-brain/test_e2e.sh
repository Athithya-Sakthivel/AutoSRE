#!/usr/bin/env bash
# =============================================================================
# test_e2e.sh – Fast, idempotent end‑to‑end system test
# =============================================================================
# Starts target‑system, mcp‑tools, and agent‑brain, then exercises the full
# incident‑response pipeline.  All Azure resources are reused if they already
# exist.  A dummy Cosmos DB key is stored in Key Vault so the agent can start
# without a real Cosmos DB account (in‑memory checkpointer is used).
#
# Prerequisites:
#   az login
#
# Usage:
#   bash src/services/agent-brain/test_e2e.sh
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
TARGET_SYSTEM_DIR="$PROJECT_ROOT/services/target-system"
MCP_TOOLS_DIR="$PROJECT_ROOT/services/mcp-tools"
AGENT_BRAIN_DIR="$PROJECT_ROOT/services/agent-brain"

# Azure resource names (hardcoded for your environment)
RG='rg-target-system-12'
LOCATION='eastus'
LAW='law-target-system'
APPINSIGHTS='appi-target-system'
KEYVAULT='kv-target-system-xfmyt'

# Service ports
TARGET_PORT=8000
MCP_PORT=8001
AGENT_PORT=8002

TARGET_URL="http://127.0.0.1:${TARGET_PORT}"
MCP_URL="http://127.0.0.1:${MCP_PORT}"
AGENT_URL="http://127.0.0.1:${AGENT_PORT}"

# Log files
TARGET_LOG='/tmp/target_system.log'
MCP_LOG='/tmp/mcp_tools.log'
AGENT_LOG='/tmp/agent_brain.log'

# -------------------------------------------------------------------
# 2. Helpers
# -------------------------------------------------------------------
kill_port() { kill $(lsof -t -i:"$1") 2>/dev/null || true; }

wait_for_health() {
    local url="$1" label="$2" log_file="$3"
    for i in $(seq 1 30); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            log "$label is healthy ($url)"
            return 0
        fi
        sleep 1
    done
    echo "=== $label failed to start. Last 30 lines of $log_file ==="
    tail -n 30 "$log_file"
    exit 1
}

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

# Quick smoke test for critical imports
smoke_test_imports() {
    local venv="$1" dir="$2"
    source "$venv/bin/activate"
    python -c "import fastapi, uvicorn, httpx, azure.identity, azure.keyvault.secrets, azure.monitor.opentelemetry" || {
        error "Python dependencies missing in $dir – run pip install -r $dir/requirements.txt"
    }
    deactivate
}

# -------------------------------------------------------------------
# 3. Azure login & resource provisioning (fast‑skip if already exist)
# -------------------------------------------------------------------
log 'Checking Azure login...'
az account show >/dev/null 2>&1 || error "Run 'az login' first."

# Resource group
az group show --name "$RG" >/dev/null 2>&1 || {
    log "Creating resource group $RG..."
    az group create --name "$RG" --location "$LOCATION" --output none
}

# Log Analytics workspace
if ! az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" >/dev/null 2>&1; then
    log "Creating Log Analytics workspace $LAW..."
    az monitor log-analytics workspace create --resource-group "$RG" --workspace-name "$LAW" --location "$LOCATION" --output none
fi
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" --query id -o tsv)

# Application Insights
if ! az extension show --name application-insights >/dev/null 2>&1; then
    az extension add --name application-insights --only-show-errors
fi
if ! az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" >/dev/null 2>&1; then
    log "Creating Application Insights $APPINSIGHTS..."
    az monitor app-insights component create --app "$APPINSIGHTS" --resource-group "$RG" --location "$LOCATION" --kind web --application-type web --workspace "$WORKSPACE_ID" --output none
fi
APPINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" --query connectionString -o tsv)

# Key Vault
az keyvault show --name "$KEYVAULT" --resource-group "$RG" >/dev/null 2>&1 || {
    log "Creating Key Vault $KEYVAULT..."
    az keyvault create --name "$KEYVAULT" --resource-group "$RG" --location "$LOCATION" --enable-rbac-authorization true --output none
}

# Assign RBAC role for current user
KV_SCOPE=$(az keyvault show --name "$KEYVAULT" --resource-group "$RG" --query id -o tsv)
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
ROLE='Key Vault Secrets Officer'
ASSIGNMENT=$(az role assignment list --assignee "$USER_OBJECT_ID" --scope "$KV_SCOPE" --role "$ROLE" --query "[0].id" -o tsv 2>/dev/null || echo '')
if [ -z "$ASSIGNMENT" ]; then
    log "Assigning Key Vault Secrets Officer role..."
    az role assignment create --assignee-object-id "$USER_OBJECT_ID" --assignee-principal-type User --role "$ROLE" --scope "$KV_SCOPE" --output none || warn 'Role assignment failed.'
    sleep 15
fi

# Store required secrets (idempotent)
store_secret "appinsights-connection-string" "$APPINSIGHTS_CONNECTION_STRING"

MCP_API_KEY=$(az keyvault secret show --vault-name "$KEYVAULT" --name "mcp-api-key" --query value -o tsv 2>/dev/null || echo '')
if [ -z "$MCP_API_KEY" ]; then
    MCP_API_KEY="local-testing-key-$(date +%s)"
    log "Generating new mcp-api-key: ${MCP_API_KEY:0:4}..."
fi
store_secret "mcp-api-key" "$MCP_API_KEY"

# Dummy cosmos key – only needed to satisfy agent's preflight when using memory checkpointer
COSMOS_KEY_DUMMY='dummy-cosmos-key-for-e2e'
store_secret "cosmos-key" "$COSMOS_KEY_DUMMY"

LOG_ANALYTICS_WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" --query customerId -o tsv)

# -------------------------------------------------------------------
# 4. Stop anything already on our ports
# -------------------------------------------------------------------
kill_port $TARGET_PORT
kill_port $MCP_PORT
kill_port $AGENT_PORT

# -------------------------------------------------------------------
# 5. Prepare virtualenvs and install dependencies (skip if unchanged)
# -------------------------------------------------------------------
for svc_dir in "$TARGET_SYSTEM_DIR" "$MCP_TOOLS_DIR" "$AGENT_BRAIN_DIR"; do
    venv="$svc_dir/.venv"
    req_hash="$venv/requirements.hash"
    current_hash=$(md5sum "$svc_dir/requirements.txt" | awk '{print $1}')
    if [ ! -d "$venv" ] || [ ! -f "$req_hash" ] || [ "$(cat "$req_hash")" != "$current_hash" ]; then
        log "Setting up venv and installing dependencies for $(basename "$svc_dir")..."
        python3 -m venv "$venv"
        source "$venv/bin/activate"
        pip install -r "$svc_dir/requirements.txt" --quiet
        echo "$current_hash" > "$req_hash"
        deactivate
    else
        log "Skipping venv setup for $(basename "$svc_dir") – already up‑to‑date."
    fi
    # Smoke test
    smoke_test_imports "$venv" "$svc_dir"
done

# -------------------------------------------------------------------
# 6. Start target‑system
# -------------------------------------------------------------------
log "Starting target‑system on port $TARGET_PORT..."
> "$TARGET_LOG"
(
    source "$TARGET_SYSTEM_DIR/.venv/bin/activate"
    export APPLICATIONINSIGHTS_CONNECTION_STRING="$APPINSIGHTS_CONNECTION_STRING"
    export ENVIRONMENT='production'
    cd "$TARGET_SYSTEM_DIR"
    uvicorn app.main:app --host 0.0.0.0 --port $TARGET_PORT >> "$TARGET_LOG" 2>&1 &
    TARGET_PID=$!
    echo $TARGET_PID > /tmp/target_system.pid
    wait_for_health "$TARGET_URL/health" "target‑system" "$TARGET_LOG"
)

# Reset any leftover chaos state
curl -s -X POST "$TARGET_URL/chaos/reset" >/dev/null || true
log "Chaos state reset to safe defaults."

# -------------------------------------------------------------------
# 7. Start mcp‑tools
# -------------------------------------------------------------------
log "Starting mcp‑tools on port $MCP_PORT..."
> "$MCP_LOG"
(
    source "$MCP_TOOLS_DIR/.venv/bin/activate"
    export KEY_VAULT_NAME="$KEYVAULT"
    export MCP_TOOLS_MODE=production
    export MCP_TOOLS_BATTLE_TEST=true
    export LOG_ANALYTICS_WORKSPACE_ID="$LOG_ANALYTICS_WORKSPACE_ID"
    export OTEL_SAMPLING_MODE=off
    export PORT=$MCP_PORT
    cd "$MCP_TOOLS_DIR"
    python -m _mcp.main >> "$MCP_LOG" 2>&1 &
    MCP_PID=$!
    echo $MCP_PID > /tmp/mcp_tools.pid
    wait_for_health "http://127.0.0.1:${MCP_PORT}/health" "mcp‑tools" "$MCP_LOG"
)

# -------------------------------------------------------------------
# 8. Start agent‑brain (in‑memory checkpointer, dummy Cosmos key)
# -------------------------------------------------------------------
log "Starting agent‑brain on port $AGENT_PORT..."
> "$AGENT_LOG"
(
    source "$AGENT_BRAIN_DIR/.venv/bin/activate"
    export KEY_VAULT_NAME="$KEYVAULT"
    export MCP_TOOLS_URL="http://127.0.0.1:${MCP_PORT}/mcp"
    export USE_MEMORY_CHECKPOINTER=true
    export PORT=$AGENT_PORT
    export ENVIRONMENT='production'
    cd "$AGENT_BRAIN_DIR"
    python -m main >> "$AGENT_LOG" 2>&1 &
    AGENT_PID=$!
    echo $AGENT_PID > /tmp/agent_brain.pid
    wait_for_health "$AGENT_URL/health" "agent‑brain" "$AGENT_LOG"
)

# -------------------------------------------------------------------
# 9. End‑to‑end workflow test
# -------------------------------------------------------------------
log "Running end‑to‑end workflow test (LLM endpoints missing – expect errors)"

echo "--- 1. Create alert ---"
ALERT_RESPONSE=$(curl -s -X POST "${AGENT_URL}/alert" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MCP_API_KEY}" \
    -d '{"name":"e2e-test","severity":"critical","description":"safe e2e test"}')
echo "$ALERT_RESPONSE"
THREAD_ID=$(echo "$ALERT_RESPONSE" | python -c "import sys,json; print(json.load(sys.stdin)['thread_id'])")
log "Workflow started with thread_id=$THREAD_ID"

sleep 5

echo "--- 2. Get workflow state ---"
curl -s "${AGENT_URL}/state/${THREAD_ID}" \
    -H "Authorization: Bearer ${MCP_API_KEY}" | python -m json.tool

echo "--- 3. Send human decision (if awaiting) ---"
curl -s -X POST "${AGENT_URL}/decision/${THREAD_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MCP_API_KEY}" \
    -d '{"decision":"approved"}' || echo "(workflow not waiting for human – expected)"

sleep 10

echo "--- 4. Final state ---"
curl -s "${AGENT_URL}/state/${THREAD_ID}" \
    -H "Authorization: Bearer ${MCP_API_KEY}" | python -m json.tool

# -------------------------------------------------------------------
# 10. Cleanup
# -------------------------------------------------------------------
log "Cleaning up..."
kill $(cat /tmp/target_system.pid) 2>/dev/null || true
kill $(cat /tmp/mcp_tools.pid) 2>/dev/null || true
kill $(cat /tmp/agent_brain.pid) 2>/dev/null || true
rm -f /tmp/target_system.pid /tmp/mcp_tools.pid /tmp/agent_brain.pid
log "All services stopped. Logs in /tmp/*.log"