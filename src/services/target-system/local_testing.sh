#!/usr/bin/env bash
# =============================================================================
# target-system – End‑to‑End Chaos Battle Test Suite (Idempotent)
# =============================================================================
# Provisions Azure resources, runs pytest, starts the service with a real
# Application Insights connection string, exercises all chaos endpoints,
# and tears down. Telemetry is mandatory – the script exports the connection
# string directly so data always reaches Azure.
#
# Usage:
#   bash src/services/target-system/local_testing.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

export TZ='Asia/Kolkata'

# Helpers
log()   { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
warn()  { printf '[%(%H:%M:%S)T] WARNING: %s\n' -1 "$*" >&2; }
error() { printf '[%(%H:%M:%S)T] ERROR: %s\n' -1 "$*" >&2; exit 1; }

# -------------------------------------------------------------------
# 1. Configuration
# -------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_DIR="$PROJECT_ROOT/services/target-system"
VENV_DIR="$SERVICE_DIR/.venv_target_system"
REQUIREMENTS="$SERVICE_DIR/requirements.txt"

RG='rg-target-system-12'          # adjust as needed
LOCATION='eastus'
LAW='law-target-system'
APPINSIGHTS='appi-target-system'
KEYVAULT='kv-target-system-xfmyt'
SECRET_NAME='appinsights-connection-string'

UVICORN_LOG='/tmp/uvicorn_target_system.log'
CURL_LOG='/tmp/curl_tests_target_system.log'

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

for pkg in pytest httpx; do
  if ! pip show "$pkg" >/dev/null 2>&1; then
    log "Installing $pkg..."
    pip install "$pkg" --quiet
  fi
done

find "$SERVICE_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$SERVICE_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true

# Kill anything already on the port
kill $(lsof -t -i:8000) 2>/dev/null || true

# -------------------------------------------------------------------
# 3. Azure provisioning (idempotent)
# -------------------------------------------------------------------
log 'Checking Azure login...'
az account show >/dev/null 2>&1 || error "Run 'az login' first."

# Resource Group
if az group show --name "$RG" >/dev/null 2>&1; then
  log "Resource group '$RG' already exists."
else
  log "Creating resource group '$RG'..."
  az group create --name "$RG" --location "$LOCATION" --output none
fi

# Log Analytics workspace
if az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" >/dev/null 2>&1; then
  log "Log Analytics workspace '$LAW' already exists."
else
  log "Creating Log Analytics workspace '$LAW'..."
  az monitor log-analytics workspace create \
    --resource-group "$RG" --workspace-name "$LAW" --location "$LOCATION" --output none
fi
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LAW" --query id -o tsv)

# Application Insights
if ! az extension show --name application-insights >/dev/null 2>&1; then
  az extension add --name application-insights --only-show-errors
fi
if az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" >/dev/null 2>&1; then
  log "Application Insights '$APPINSIGHTS' already exists."
else
  log "Creating Application Insights '$APPINSIGHTS'..."
  az monitor app-insights component create \
    --app "$APPINSIGHTS" --resource-group "$RG" --location "$LOCATION" \
    --kind web --application-type web --workspace "$WORKSPACE_ID" --output none
fi
APPINSIGHTS_CONNECTION_STRING=$(
  az monitor app-insights component show --app "$APPINSIGHTS" --resource-group "$RG" --query connectionString -o tsv
)

# Key Vault
if az keyvault show --name "$KEYVAULT" --resource-group "$RG" >/dev/null 2>&1; then
  log "Key Vault '$KEYVAULT' already exists."
else
  log "Creating Key Vault '$KEYVAULT'..."
  az keyvault create --name "$KEYVAULT" --resource-group "$RG" --location "$LOCATION" \
    --enable-rbac-authorization true --output none
fi

# RBAC for current user
KV_SCOPE=$(az keyvault show --name "$KEYVAULT" --resource-group "$RG" --query id -o tsv)
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
ROLE='Key Vault Secrets Officer'

EXISTING_ASSIGNMENT=$(az role assignment list \
  --assignee "$USER_OBJECT_ID" \
  --scope "$KV_SCOPE" \
  --role "$ROLE" \
  --query "[0].id" -o tsv 2>/dev/null || echo '')

if [ -n "$EXISTING_ASSIGNMENT" ]; then
  log "Role '$ROLE' already assigned – skipping."
else
  log "Assigning '$ROLE' role to current user on Key Vault..."
  if az role assignment create \
       --assignee-object-id "$USER_OBJECT_ID" \
       --assignee-principal-type User \
       --role "$ROLE" \
       --scope "$KV_SCOPE" \
       --output none 2>/tmp/az_role_error.log; then
    log 'Role assigned. Waiting 15 s for propagation...'
    sleep 15
  else
    warn 'Failed to assign Key Vault role. Continuing without it.'
  fi
fi

# Store secret in Key Vault (best effort)
MAX_RETRIES=5
for (( i=1; i<=MAX_RETRIES; i++ )); do
  CURRENT_SECRET=$(az keyvault secret show --vault-name "$KEYVAULT" --name "$SECRET_NAME" --query value -o tsv 2>/dev/null || echo '')
  if [ "$CURRENT_SECRET" = "$APPINSIGHTS_CONNECTION_STRING" ]; then
    log "Key Vault secret '$SECRET_NAME' already up‑to‑date."
    break
  fi
  log "Setting Key Vault secret (attempt $i/$MAX_RETRIES)..."
  if az keyvault secret set \
       --vault-name "$KEYVAULT" \
       --name "$SECRET_NAME" \
       --value "$APPINSIGHTS_CONNECTION_STRING" \
       --output none 2>/tmp/az_secret_error.log; then
    log 'Secret set successfully.'
    break
  fi
  if [ "$i" -lt "$MAX_RETRIES" ]; then
    sleep 10
  else
    warn "Failed to set secret after $MAX_RETRIES attempts."
  fi
done

# -------------------------------------------------------------------
# 6. Export environment – THIS IS THE CRITICAL PART
# -------------------------------------------------------------------
# Bypass Key Vault for the local test: give the connection string directly.
export APPLICATIONINSIGHTS_CONNECTION_STRING="$APPINSIGHTS_CONNECTION_STRING"
export ENVIRONMENT='production'   # force fail-fast if something goes wrong
export OTEL_SAMPLING_MODE='rate'
export OTEL_TRACES_PER_SECOND='5'
export OTEL_ENABLE_LIVE_METRICS='true'

# -------------------------------------------------------------------
# 7. Run pytest
# -------------------------------------------------------------------
log 'Running pytest...'
cd "$SERVICE_DIR"
python -m pytest tests/ -v

# -------------------------------------------------------------------
# 8. Start uvicorn in background
# -------------------------------------------------------------------
log "Starting uvicorn (background, logs → $UVICORN_LOG)..."
> "$UVICORN_LOG"
uvicorn app.main:app --host 0.0.0.0 --port 8000 > "$UVICORN_LOG" 2>&1 &
UVICORN_PID=$!
echo $UVICORN_PID > /tmp/uvicorn_target_system.pid

log 'Waiting for server to become healthy...'
for i in {1..30}; do
  if curl -s http://localhost:8000/health >/dev/null 2>&1; then
    log "Server is up (PID $UVICORN_PID)."
    break
  fi
  sleep 1
done

# -------------------------------------------------------------------
# 9. Curl battle tests
# -------------------------------------------------------------------
log "Running curl tests (output → $CURL_LOG)..."
{
  echo "===== $(date) ====="
  echo '--- /health ---'
  curl -s http://localhost:8000/health | python -m json.tool

  echo '--- /api/process (normal) ---'
  curl -s -X POST http://localhost:8000/api/process | python -m json.tool

  echo '--- /chaos/latency?ms=100 ---'
  curl -s -X POST 'http://localhost:8000/chaos/latency?ms=100' | python -m json.tool

  echo '--- /api/process (with latency) ---'
  curl -s -X POST http://localhost:8000/api/process | python -m json.tool

  echo '--- /chaos/error-rate?rate=0.5 ---'
  curl -s -X POST 'http://localhost:8000/chaos/error-rate?rate=0.5' | python -m json.tool

  echo '--- /api/process (random error) ---'
  curl -s -X POST http://localhost:8000/api/process || echo '(expected 500)'

  echo '--- /chaos/oom ---'
  curl -s -X POST http://localhost:8000/chaos/oom | python -m json.tool

  echo '--- /api/process (OOM) ---'
  curl -s -X POST http://localhost:8000/api/process || echo '(expected 500)'

  echo '--- /chaos/db-deadlock ---'
  curl -s -X POST http://localhost:8000/chaos/db-deadlock | python -m json.tool

  echo '--- /api/process (deadlock) ---'
  curl -s -X POST http://localhost:8000/api/process || echo '(expected 500)'

  echo '--- /chaos/reset ---'
  curl -s -X POST http://localhost:8000/chaos/reset | python -m json.tool

  echo '--- /api/process (after reset) ---'
  curl -s -X POST http://localhost:8000/api/process | python -m json.tool

  echo '--- /chaos/state ---'
  curl -s http://localhost:8000/chaos/state | python -m json.tool
} > "$CURL_LOG" 2>&1

# -------------------------------------------------------------------
# 10. Display logs & cleanup
# -------------------------------------------------------------------
log 'Uvicorn log tail (last 20 lines):'
tail -n 20 "$UVICORN_LOG"

log 'Curl test log tail (last 50 lines):'
tail -n 50 "$CURL_LOG"

log "Stopping uvicorn (PID $UVICORN_PID)..."
kill "$UVICORN_PID" 2>/dev/null || true
rm -f /tmp/uvicorn_target_system.pid

log 'All done.'
log "Full logs: $UVICORN_LOG and $CURL_LOG"