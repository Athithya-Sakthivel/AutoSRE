#!/usr/bin/env bash
set -uo pipefail

# -----------------------------------------------------------------------------
# End-to-end local test with Key Vault + PostgreSQL + Application Insights.
#
# This script:
#   1. Stops any previous taskdb PostgreSQL container and Spring Boot app.
#   2. Starts a clean PostgreSQL container.
#   3. Dynamically updates the Key Vault DatabaseUrl to use Docker bridge IP.
#   4. Downloads the Application Insights Java agent if missing.
#   5. Exports required environment variables.
#   6. Starts Spring Boot in the background with the agent.
#   7. Waits for the health endpoint.
#   8. Runs curl tests (register, login, create task, get tasks).
#   9. Waits a configurable amount of time for telemetry export.
#  10. Queries the linked Log Analytics workspace for telemetry counts.
#  11. Stops the application and removes the container on exit.
# -----------------------------------------------------------------------------

# Configuration
KV="az-temp-kv-101"
RG="temp-az-1930"
AI="task-api-insights"
DB_PASSWORD='bulZpXGOiFOORRLRs6V+24gv/egWbQQVzdDT1wcwghU='
POSTGRES_IMAGE='docker.io/library/postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685'
AGENT_VERSION="3.7.8"
AGENT_JAR="/tmp/applicationinsights-agent-${AGENT_VERSION}.jar"
TELEMETRY_WAIT_SECONDS=${TELEMETRY_WAIT_SECONDS:-120}   # default 2 minutes
APP_LOG="/tmp/taskapi-e2e.log"

# Derived paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
fail()  { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    log "Cleaning up..."
    if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        sleep 2
    fi
    docker rm -f taskdb >/dev/null 2>&1 || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. Stop previous instances
# -----------------------------------------------------------------------------
log "Stopping previous instances..."
pkill -f 'TaskApiApplication' 2>/dev/null || true
docker rm -f taskdb >/dev/null 2>&1 || true
sleep 2

# -----------------------------------------------------------------------------
# 2. Start PostgreSQL
# -----------------------------------------------------------------------------
log "Starting clean PostgreSQL container..."
docker run \
    --name taskdb \
    -e POSTGRES_DB=taskdb \
    -e POSTGRES_USER=taskuser \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -p 5432:5432 \
    -d "$POSTGRES_IMAGE" >/dev/null || fail "Failed to start PostgreSQL container"

# -----------------------------------------------------------------------------
# 3. Resolve Docker bridge gateway and update Key Vault
# -----------------------------------------------------------------------------
log "Resolving Docker bridge gateway..."
DOCKER_GATEWAY="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
[[ -z "$DOCKER_GATEWAY" ]] && fail "Could not determine Docker gateway IP"

DB_URL="jdbc:postgresql://${DOCKER_GATEWAY}:5432/taskdb"
log "Database URL: $DB_URL"
az keyvault secret set \
    --vault-name "$KV" \
    --name "DatabaseUrl" \
    --value "$DB_URL" \
    --output none || fail "Failed to update Key Vault DatabaseUrl"

# -----------------------------------------------------------------------------
# 4. Download Application Insights agent if needed
# -----------------------------------------------------------------------------
if [[ ! -f "$AGENT_JAR" ]]; then
    log "Downloading Application Insights agent $AGENT_VERSION..."
    wget -q -O "$AGENT_JAR" \
        "https://github.com/microsoft/ApplicationInsights-Java/releases/download/${AGENT_VERSION}/applicationinsights-agent-${AGENT_VERSION}.jar" \
        || fail "Failed to download Application Insights agent"
fi

# -----------------------------------------------------------------------------
# 5. Export environment variables
# -----------------------------------------------------------------------------
log "Setting environment variables..."
export AZURE_KEY_VAULT_URI="$(az keyvault show --name "$KV" --resource-group "$RG" --query properties.vaultUri -o tsv)"
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(az keyvault secret show --vault-name "$KV" --name ApplicationInsightsConnectionString --query value -o tsv)"
export OTEL_SERVICE_NAME='task-api'
export OTEL_RESOURCE_ATTRIBUTES='deployment.environment.name=local'

[[ -z "$AZURE_KEY_VAULT_URI" ]] && fail "AZURE_KEY_VAULT_URI is empty"
[[ -z "$APPLICATIONINSIGHTS_CONNECTION_STRING" ]] && fail "APPLICATIONINSIGHTS_CONNECTION_STRING is empty"

log "AZURE_KEY_VAULT_URI: $AZURE_KEY_VAULT_URI"
log "APPLICATIONINSIGHTS_CONNECTION_STRING: ${APPLICATIONINSIGHTS_CONNECTION_STRING:0:50}..."

# -----------------------------------------------------------------------------
# 6. Start Spring Boot in background
# -----------------------------------------------------------------------------
log "Starting Spring Boot application with Java agent..."
mvn spring-boot:run \
    -Dspring-boot.run.jvmArguments="-javaagent:${AGENT_JAR}" \
    > "$APP_LOG" 2>&1 &
APP_PID=$!
log "Application PID: $APP_PID"

# -----------------------------------------------------------------------------
# 7. Wait for health endpoint
# -----------------------------------------------------------------------------
log "Waiting for application health endpoint..."
MAX_RETRIES=30
RETRY_INTERVAL=3
for ((i=1; i<=MAX_RETRIES; i++)); do
    if curl -fsS http://localhost:8080/actuator/health >/dev/null 2>&1; then
        log "Application is up."
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "Application process exited unexpectedly."
        tail -50 "$APP_LOG"
        fail "Application failed to start"
    fi
    if (( i == MAX_RETRIES )); then
        tail -50 "$APP_LOG"
        fail "Timed out waiting for application"
    fi
    sleep "$RETRY_INTERVAL"
done

# -----------------------------------------------------------------------------
# 8. Run curl tests
# -----------------------------------------------------------------------------
log "Running curl tests..."

# Health
HEALTH_OUTPUT=$(curl -fsS http://localhost:8080/actuator/health) || fail "Health check failed"
log "Health: $HEALTH_OUTPUT"

# Register (ignore 400 if already exists)
log "Registering user..."
REGISTER_OUTPUT=$(curl -sS -X POST http://localhost:8080/api/v1/auth/register \
    -H 'Content-Type: application/json' \
    -d '{"username":"demouser","email":"demo@example.com","password":"Password123!"}')
REGISTER_STATUS=$?
if [[ $REGISTER_STATUS -eq 0 ]]; then
    echo "$REGISTER_OUTPUT"
else
    echo "Register returned error (may already exist): $REGISTER_OUTPUT"
fi

# Login
log "Logging in..."
TOKEN="$(curl -fsS -X POST http://localhost:8080/api/v1/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"demouser","password":"Password123!"}' | jq -r '.token')" \
    || fail "Login failed"
log "Token acquired: ${TOKEN:0:20}..."

# Create task
log "Creating task..."
CREATE_TASK=$(curl -fsS -X POST http://localhost:8080/api/v1/tasks \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"title":"Telemetry Test","description":"Check App Insights","status":"PENDING"}') \
    || fail "Create task failed"
echo "$CREATE_TASK"

# Get tasks
log "Fetching tasks..."
GET_TASKS=$(curl -fsS http://localhost:8080/api/v1/tasks \
    -H "Authorization: Bearer $TOKEN") \
    || fail "Get tasks failed"
echo "$GET_TASKS"

# -----------------------------------------------------------------------------
# 9. Wait for telemetry export
# -----------------------------------------------------------------------------
log "Waiting ${TELEMETRY_WAIT_SECONDS} seconds for telemetry to export..."
sleep "$TELEMETRY_WAIT_SECONDS"

# -----------------------------------------------------------------------------
# 10. Query Log Analytics workspace
# -----------------------------------------------------------------------------
log "Querying Application Insights telemetry..."

WORKSPACE_RESOURCE_ID="$(az monitor app-insights component show \
    --app "$AI" \
    --resource-group "$RG" \
    --query 'properties.WorkspaceResourceId' \
    --output tsv 2>/dev/null)"

if [[ -z "$WORKSPACE_RESOURCE_ID" ]]; then
    echo "WARN: No workspace resource ID found; skipping telemetry query."
else
    WORKSPACE_ID="$(az resource show \
        --ids "$WORKSPACE_RESOURCE_ID" \
        --query 'properties.customerId' \
        --output tsv 2>/dev/null)"

    if [[ -n "$WORKSPACE_ID" ]]; then
        echo "Workspace ID: $WORKSPACE_ID"
        az monitor log-analytics query \
            --workspace "$WORKSPACE_ID" \
            --analytics-query '
union
    (AppRequests | summarize Count=count()),
    (AppDependencies | summarize Count=count()),
    (AppTraces | summarize Count=count()),
    (AppExceptions | summarize Count=count()),
    (AppMetrics | summarize Count=count())
' \
            --timespan PT1H \
            --output table 2>&1 || echo "WARN: Telemetry query failed."
    else
        echo "WARN: Could not resolve workspace customer ID."
    fi
fi

log "E2E test completed."