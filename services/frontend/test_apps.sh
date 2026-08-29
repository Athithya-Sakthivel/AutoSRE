#!/usr/bin/env bash

# =============================================================================
# Local full-stack runner: PostgreSQL + Backend + Frontend
#
# Uses a dedicated Spring profile "local" that disables Azure Key Vault.
# Secrets are passed directly via environment variables.
# =============================================================================

NETWORK="task-api-network"
DB_CONTAINER="taskdb"
BACKEND_CONTAINER="task-api-backend"
FRONTEND_CONTAINER="task-api-frontend"

DB_PASSWORD='bulZpXGOiFOORRLRs6V+24gv/egWbQQVzdDT1wcwghU='
JWT_SECRET='K43DB0QpZzitfSFr9zGoQSfDglm8ahRmerCDzwBbzIT26tB9xCYP7sVhCmV/PBWNLKq2aAks57AbDWEcjNju1w=='
POSTGRES_IMAGE='docker.io/library/postgres:18.6-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'

BACKEND_IMAGE="task-api-backend:local"
FRONTEND_IMAGE="task-api-frontend:local"

BACKEND_PORT=8080
FRONTEND_PORT=8081

KV="az-temp-kv-101"
RG="temp-az-1930"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# 1. Ensure Docker network
log "Ensuring Docker network '$NETWORK'..."
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

# 2. Cleanup old containers
log "Cleaning up old containers..."
docker rm -f "$DB_CONTAINER" "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1 || true

# 3. Start PostgreSQL
log "Starting PostgreSQL..."
docker run -d \
  --name "$DB_CONTAINER" \
  --network "$NETWORK" \
  -e POSTGRES_DB=taskdb \
  -e POSTGRES_USER=taskuser \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  "$POSTGRES_IMAGE" >/dev/null

# 4. Get Application Insights connection string from Key Vault (optional, only for telemetry)
log "Fetching Application Insights connection string from Key Vault..."
APPINSIGHTS_CONN_STR="$(az keyvault secret show --vault-name "$KV" --name ApplicationInsightsConnectionString --query value -o tsv 2>/dev/null || echo '')"

# 5. Build images
log "Building backend image..."
docker build -t "$BACKEND_IMAGE" -f services/backend/Dockerfile services/backend/

log "Building frontend image..."
docker build -t "$FRONTEND_IMAGE" -f services/frontend/Dockerfile.local services/frontend/

# 6. Run backend with local profile
log "Starting backend container..."
docker run -d \
  --name "$BACKEND_CONTAINER" \
  --network "$NETWORK" \
  -p "$BACKEND_PORT:8080" \
  -e SPRING_PROFILES_ACTIVE=local \
  -e DATABASEURL="jdbc:postgresql://${DB_CONTAINER}:5432/taskdb" \
  -e DATABASEUSERNAME="taskuser" \
  -e DATABASEPASSWORD="$DB_PASSWORD" \
  -e JWTSECRET="$JWT_SECRET" \
  -e APPLICATIONINSIGHTS_CONNECTION_STRING="$APPINSIGHTS_CONN_STR" \
  -e OTEL_SERVICE_NAME='task-api' \
  -e OTEL_RESOURCE_ATTRIBUTES='deployment.environment.name=local' \
  -e APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE=100 \
  "$BACKEND_IMAGE" >/dev/null

# 7. Run frontend
log "Starting frontend container..."
docker run -d \
  --name "$FRONTEND_CONTAINER" \
  --network "$NETWORK" \
  -p "$FRONTEND_PORT:8080" \
  "$FRONTEND_IMAGE" >/dev/null

# 8. Wait for backend health
log "Waiting for backend health..."
for i in {1..30}; do
  if curl -fsS "http://localhost:$BACKEND_PORT/actuator/health" >/dev/null 2>&1; then
    log "  Backend is healthy."
    break
  fi
  sleep 3
  if [[ $i == 30 ]]; then
    docker logs "$BACKEND_CONTAINER" | tail -50
    fail "Backend did not become healthy"
  fi
done

# 9. Wait for frontend
log "Waiting for frontend..."
for i in {1..15}; do
  if curl -fsS "http://localhost:$FRONTEND_PORT/health" >/dev/null 2>&1; then
    log "  Frontend is healthy."
    break
  fi
  sleep 2
  if [[ $i == 15 ]]; then
    docker logs "$FRONTEND_CONTAINER" | tail -20
    fail "Frontend did not become healthy"
  fi
done

# 10. Print URLs
echo ""
log "Application running:"
echo "  Frontend: http://localhost:$FRONTEND_PORT"
echo "  Backend:  http://localhost:$BACKEND_PORT/actuator/health"
echo ""
echo "Stop with:"
echo "  docker rm -f $BACKEND_CONTAINER $FRONTEND_CONTAINER $DB_CONTAINER"
