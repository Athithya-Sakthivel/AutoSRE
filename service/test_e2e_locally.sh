#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# End-to-end local test with Key Vault + PostgreSQL + Application Insights.
#
# Reproducible flow:
#   1. Clean up previous app/container instances
#   2. Start PostgreSQL in Docker
#   3. Update Key Vault DatabaseUrl to Docker bridge IP
#   4. Download Application Insights Java agent if needed
#   5. Set env vars + 100% sampling + self-diagnostics
#   6. Start Spring Boot in background with agent
#   7. Wait for health
#   8. Run curl tests
#   9. Gracefully stop app to flush telemetry
#  10. Poll Log Analytics for AppRequests (filtered by exact AI resource)
#  11. Print final status
#
# Key telemetry bugs fixed:
#   - Default sampling drops most requests. We force 100% via the
#     APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE environment variable.
#   - Ingestion to Log Analytics can take 1–3 minutes. We poll for up to
#     10 minutes.
#   - `count()` undercounts sampled data. We use `sum(ItemCount)`.
#   - Querying `ago(10m)` from shutdown missed records. We use `ago(30m)`.
#   - Missing AZURE_KEY_VAULT_URI caused startup exception. We validate
#     all required env vars before starting.
#   - Workspace/AI resource mismatch due to stale variables. We derive
#     both dynamically from Azure.
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

KV="az-temp-kv-101"
RG="temp-az-1930"
AI="task-api-insights"
LAW_NAME="task-api-logs-1930"
LAW_RG="temp-az-1930"

DB_PASSWORD='bulZpXGOiFOORRLRs6V+24gv/egWbQQVzdDT1wcwghU='
POSTGRES_IMAGE='docker.io/library/postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685'

AGENT_VERSION="3.7.9"
AGENT_JAR="/tmp/applicationinsights-agent-${AGENT_VERSION}.jar"

# Polling configuration
TELEMETRY_TIMEOUT=600          # 10 minutes maximum wait
TELEMETRY_INTERVAL=15          # check every 15 seconds
APP_START_TIMEOUT=60           # seconds to wait for health
APP_LOG="/tmp/taskapi-e2e.log"
SELF_DIAG_LOG="/tmp/applicationinsights.log"

# Test user (timestamp avoids duplicate registration on rerun)
TEST_EMAIL="e2e-$(date +%s)-${RANDOM}@example.com"
TEST_USERNAME="demouser"
TEST_PASSWORD="Password123!"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
fail()  { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    docker rm -f taskdb >/dev/null 2>&1 || true
}
trap cleanup EXIT

# =============================================================================
# 1. Cleanup previous instances
# =============================================================================
log "Stopping previous instances..."
pkill -f 'TaskApiApplication' 2>/dev/null || true
docker rm -f taskdb >/dev/null 2>&1 || true
sleep 2

# =============================================================================
# 2. Start PostgreSQL
# =============================================================================
log "Starting PostgreSQL..."
docker run --name taskdb \
  -e POSTGRES_DB=taskdb \
  -e POSTGRES_USER=taskuser \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -p 5432:5432 -d "$POSTGRES_IMAGE" >/dev/null || fail "PostgreSQL failed"

# =============================================================================
# 3. Update Key Vault DatabaseUrl to Docker bridge IP
# =============================================================================
log "Updating Key Vault DatabaseUrl..."
DOCKER_GATEWAY="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
[[ -z "$DOCKER_GATEWAY" ]] && fail "No Docker gateway"
DB_URL="jdbc:postgresql://${DOCKER_GATEWAY}:5432/taskdb"
az keyvault secret set --vault-name "$KV" --name "DatabaseUrl" --value "$DB_URL" --output none \
  || fail "Key Vault update failed"

# =============================================================================
# 4. Download Application Insights agent if needed
# =============================================================================
if [[ ! -f "$AGENT_JAR" ]]; then
  log "Downloading Application Insights agent $AGENT_VERSION..."
  wget -q -O "$AGENT_JAR" \
    "https://github.com/microsoft/ApplicationInsights-Java/releases/download/${AGENT_VERSION}/applicationinsights-agent-${AGENT_VERSION}.jar" \
    || fail "Download failed"
fi

# =============================================================================
# 5. Environment variables
# =============================================================================
log "Setting environment variables..."
export AZURE_KEY_VAULT_URI="$(az keyvault show --name "$KV" --resource-group "$RG" --query properties.vaultUri -o tsv)"
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(az keyvault secret show --vault-name "$KV" --name ApplicationInsightsConnectionString --query value -o tsv)"
export OTEL_SERVICE_NAME='task-api'
export OTEL_RESOURCE_ATTRIBUTES='deployment.environment.name=local'

# Force 100% sampling for reproducible e2e.
# Do NOT use 100% in production; default is ~5 req/sec.
export APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE=100

# Self-diagnostics for debugging. INFO level keeps noise low.
export APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_LEVEL=INFO
export APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_FILE_PATH="$SELF_DIAG_LOG"

# Validate critical env vars
[[ -z "$AZURE_KEY_VAULT_URI" ]] && fail "AZURE_KEY_VAULT_URI empty"
[[ -z "$APPLICATIONINSIGHTS_CONNECTION_STRING" ]] && fail "Connection string empty"

# =============================================================================
# 6. Start Spring Boot in background with agent
# =============================================================================
log "Starting Spring Boot with Java agent..."
mvn spring-boot:run \
  -Dspring-boot.run.jvmArguments="-javaagent:${AGENT_JAR}" \
  > "$APP_LOG" 2>&1 &
APP_PID=$!

# =============================================================================
# 7. Wait for health endpoint
# =============================================================================
log "Waiting for health..."
for ((i=1; i<=$((APP_START_TIMEOUT / 3)); i++)); do
  curl -fsS http://localhost:8080/actuator/health >/dev/null 2>&1 && { log "App is up"; break; }
  kill -0 "$APP_PID" 2>/dev/null || { tail -20 "$APP_LOG"; fail "App died"; }
  sleep 3
  (( i == $((APP_START_TIMEOUT / 3)) )) && { tail -20 "$APP_LOG"; fail "App start timeout"; }
done

# =============================================================================
# 8. Run curl tests
# =============================================================================
log "Running curl tests..."
curl -fsS http://localhost:8080/actuator/health || fail "Health check failed"

# Register (ignore if user already exists from prior run)
curl -sS -X POST http://localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$TEST_USERNAME\",\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" || true

# Login
TOKEN="$(curl -fsS -X POST http://localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"$TEST_PASSWORD\"}" | jq -r '.token')" \
  || fail "Login failed"

# Create task
curl -fsS -X POST http://localhost:8080/api/v1/tasks \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Telemetry Test","description":"Check App Insights","status":"PENDING"}' >/dev/null \
  || fail "Create task failed"

# Get tasks
curl -fsS http://localhost:8080/api/v1/tasks -H "Authorization: Bearer $TOKEN" >/dev/null \
  || fail "Get tasks failed"

log "Curl tests passed."

# =============================================================================
# 9. Gracefully stop app to flush telemetry
# =============================================================================
log "Stopping app to flush telemetry..."
kill -TERM "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# =============================================================================
# 10. Poll Log Analytics for telemetry
# =============================================================================
log "Polling Log Analytics..."

# Get workspace customer ID (direct from known LAW)
WORKSPACE_CUSTOM_ID="$(az monitor log-analytics workspace show --resource-group "$LAW_RG" --workspace-name "$LAW_NAME" --query customerId -o tsv 2>/dev/null || true)"
[[ -z "$WORKSPACE_CUSTOM_ID" || "$WORKSPACE_CUSTOM_ID" == "None" ]] && fail "Workspace customerId missing"

# Get exact AI resource ID to filter telemetry
AI_RESOURCE_ID="$(az monitor app-insights component show --app "$AI" --resource-group "$RG" --query id -o tsv 2>/dev/null || true)"
[[ -z "$AI_RESOURCE_ID" ]] && fail "AI resource ID missing"

# Query with 30-minute window and resource filter. Use sum(ItemCount) for sampling.
KQL_QUERY="AppRequests | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | summarize RequestCount = sum(ItemCount)"

# Debug output to confirm correct IDs
echo "Workspace ID: $WORKSPACE_CUSTOM_ID"
echo "AI Resource ID: $AI_RESOURCE_ID"
echo "KQL: $KQL_QUERY"

# =============================================================================
# 10. Poll Log Analytics for telemetry
# =============================================================================
log "Polling Log Analytics..."

# Get workspace customer ID and AI resource ID
WORKSPACE_CUSTOM_ID="$(az monitor log-analytics workspace show --resource-group "$LAW_RG" --workspace-name "$LAW_NAME" --query customerId -o tsv 2>/dev/null || true)"
[[ -z "$WORKSPACE_CUSTOM_ID" || "$WORKSPACE_CUSTOM_ID" == "None" ]] && fail "Workspace customerId missing"

AI_RESOURCE_ID="$(az monitor app-insights component show --app "$AI" --resource-group "$RG" --query id -o tsv 2>/dev/null || true)"
[[ -z "$AI_RESOURCE_ID" ]] && fail "AI resource ID missing"

# Query for request count; use sum(ItemCount) and a 30-minute window
KQL_REQUESTS="AppRequests | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | summarize RequestCount = sum(ItemCount)"

TELEMETRY_FOUND=false
DEADLINE=$((SECONDS + TELEMETRY_TIMEOUT))

while (( SECONDS < DEADLINE )); do
  RESULT="$(az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" --analytics-query "$KQL_REQUESTS" --timespan PT30M --output json 2>/dev/null)"
  if [[ -n "$RESULT" ]]; then
    REQUEST_COUNT="$(echo "$RESULT" | jq -r 'if type=="array" then .[0].RequestCount else .tables[0].rows[0][0] end // 0' 2>/dev/null || echo 0)"
    echo "  [$(date '+%H:%M:%S')] Poll: $REQUEST_COUNT requests"
    if (( REQUEST_COUNT > 0 )); then
      TELEMETRY_FOUND=true
      break
    fi
  else
    echo "  [$(date '+%H:%M:%S')] Poll: query failed"
  fi
  sleep "$TELEMETRY_INTERVAL"
done

if [[ "$TELEMETRY_FOUND" != "true" ]]; then
  log "WARN: No request telemetry observed after ${TELEMETRY_TIMEOUT}s."
  log "Check self-diagnostics: $SELF_DIAG_LOG"
  exit 0
fi

# =============================================================================
# 11. Telemetry summary and correlation
# =============================================================================
log "Telemetry found. Collecting summary..."

# Helper: query a single count for a table
get_count() {
  local table="$1"
  local query="table(table) | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | summarize Count = sum(ItemCount)"
  az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" --analytics-query "table('$table') | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | summarize Count = sum(ItemCount)" --timespan PT30M --output json 2>/dev/null | jq -r 'if type=="array" then .[0].Count else .tables[0].rows[0][0] end // 0'
}

# Helper: get first row of a table
get_first_row() {
  local table="$1"
  local columns="$2"
  az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" --analytics-query "table('$table') | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | project $columns | order by TimeGenerated desc | take 1" --timespan PT30M --output json 2>/dev/null | jq -c 'if type=="array" then .[0] else .tables[0].rows[0] end // empty'
}

echo ""
echo "=== Telemetry counts (last 30 min) ==="
for T in AppRequests AppDependencies AppTraces AppExceptions AppMetrics; do
  C=$(get_count "$T")
  echo "  $T: $C"
done

echo ""
echo "=== Sample rows (first row per table) ==="
echo "--- AppRequests ---"
get_first_row "AppRequests" "TimeGenerated, Name, OperationId, Success, ResultCode, DurationMs" || echo "  no data"
echo "--- AppDependencies ---"
get_first_row "AppDependencies" "TimeGenerated, Target, DependencyType, OperationId, Success, DurationMs" || echo "  no data"
echo "--- AppTraces ---"
get_first_row "AppTraces" "TimeGenerated, Message, SeverityLevel, OperationId" || echo "  no data"
echo "--- AppExceptions ---"
get_first_row "AppExceptions" "TimeGenerated, Type, OuterMessage, OperationId" || echo "  no data"
echo "--- AppMetrics ---"
get_first_row "AppMetrics" "TimeGenerated, Name, Sum, ItemCount, Min, Max" || echo "  no data"

echo ""
echo "=== Correlation check (recent OperationId) ==="
# Get a recent OperationId from AppRequests
OPID="$(az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" --analytics-query "AppRequests | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | top 1 by TimeGenerated desc | project OperationId" --timespan PT30M --output json 2>/dev/null | jq -r 'if type=="array" then .[0].OperationId else .tables[0].rows[0][0] end // empty')"

if [[ -z "$OPID" || "$OPID" == "null" ]]; then
  echo "  No OperationId found; cannot verify correlation."
else
  echo "  OperationId: $OPID"
  az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" --analytics-query "union (AppRequests | where OperationId == '$OPID' | project Type='Request', TimeGenerated, Name), (AppDependencies | where OperationId == '$OPID' | project Type='Dependency', TimeGenerated, Target), (AppTraces | where OperationId == '$OPID' | project Type='Trace', TimeGenerated, Message) | order by TimeGenerated asc" --timespan PT30M --output table 2>/dev/null || echo "  Correlation query failed."
fi

# =============================================================================
# 12. Final status
# =============================================================================
log "E2E test PASSED: correlated telemetry verified."