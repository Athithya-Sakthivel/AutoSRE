#!/usr/bin/env bash
# ==============================================================================
# local/deploy-postgres.sh – Deploy local PostgreSQL for kind and ensure
# backend-secrets are set to local values.
#
# This script:
#   1. Deletes any existing ExternalSecret `backend-secrets` to prevent ESO
#      from overwriting our local secret.
#   2. Creates/patches the Kubernetes Secret `backend-secrets` with local
#      DatabaseUrl, username, password, JWT secret, and a dummy App Insights
#      connection string.
#   3. Deploys a local PostgreSQL Deployment + Service + PVC using the same
#      credentials.
#
# Idempotent – safe to run multiple times.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

NAMESPACE="${NAMESPACE:-task-api}"
POSTGRES_USER="${POSTGRES_USER:-taskuser}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-local-dev-password}"
POSTGRES_DB="${POSTGRES_DB:-taskdb}"
STORAGE_SIZE="${STORAGE_SIZE:-1Gi}"

log()   { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail()  { log "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 1. Ensure namespace exists
# ------------------------------------------------------------------------------
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------------------------
# 2. Remove any existing ExternalSecret that would overwrite our local secret
# ------------------------------------------------------------------------------
log "Removing external secret (if any) to prevent Azure sync..."
kubectl delete externalsecret backend-secrets -n "$NAMESPACE" --ignore-not-found=true

# ------------------------------------------------------------------------------
# 3. Create/update the backend-secrets Secret with local values
# ------------------------------------------------------------------------------
# Generate a random JWT secret if not provided
JWT_SECRET="${JWT_SECRET:-$(openssl rand -base64 64)}"

# Dummy App Insights connection string (non-empty, but will not be reachable)
APPINSIGHTS_CS="InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://localhost;LiveEndpoint=https://localhost"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backend-secrets
  namespace: $NAMESPACE
type: Opaque
stringData:
  DATABASEURL: "jdbc:postgresql://postgres:5432/$POSTGRES_DB"
  DATABASEUSERNAME: "$POSTGRES_USER"
  DATABASEPASSWORD: "$POSTGRES_PASSWORD"
  JWTSECRET: "$JWT_SECRET"
  APPLICATIONINSIGHTS_CONNECTION_STRING: "$APPINSIGHTS_CS"
EOF

# ------------------------------------------------------------------------------
# 4. Deploy local PostgreSQL
# ------------------------------------------------------------------------------
log "Deploying local PostgreSQL..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $STORAGE_SIZE
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18.6-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "$POSTGRES_DB"
            - name: POSTGRES_USER
              value: "$POSTGRES_USER"
            - name: POSTGRES_PASSWORD
              value: "$POSTGRES_PASSWORD"
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 15
            periodSeconds: 15
            failureThreshold: 3
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
EOF

log "Waiting for PostgreSQL to be ready..."
kubectl rollout status deployment/postgres -n "$NAMESPACE" --timeout=180s

log "Local PostgreSQL deployed successfully."
log "Backend-secrets now contain local DatabaseUrl: jdbc:postgresql://postgres:5432/$POSTGRES_DB"
